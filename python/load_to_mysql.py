"""
NHS Waiting List Analytics - MySQL Loader
=========================================
Loads processed CSV files into the nhs_waiting_list_db star schema.

Pipeline:
    1. Insert any new trusts into dim_trust (auto-discovered from data)
    2. Insert any new treatment functions into dim_treatment_function
    3. Truncate staging tables
    4. LOAD DATA into staging tables from processed CSVs
    5. Call stored procedures: sp_load_fact_incomplete,
                               sp_load_fact_completed,
                               sp_load_fact_new_periods
    6. Validate row counts

Usage:
    python load_to_mysql.py --file-type all
    python load_to_mysql.py --file-type incomplete
    python load_to_mysql.py --file-type new_periods

Environment variables (or .env file):
    DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME

Author: Teslim Uthman Adeyanju
Date:   April 2026
"""

import os
import uuid
import logging
import argparse
from pathlib import Path
from datetime import datetime

import pandas as pd
import mysql.connector
from mysql.connector import Error
from dotenv import load_dotenv

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

load_dotenv()

ROOT_DIR      = Path(__file__).parent.parent
PROCESSED_DIR = ROOT_DIR / "data" / "processed"

DB_CONFIG = {
    "host":     os.getenv("DB_HOST",     "localhost"),
    "port":     int(os.getenv("DB_PORT", "3306")),
    "user":     os.getenv("DB_USER",     "root"),
    "password": os.getenv("DB_PASSWORD", ""),
    "database": os.getenv("DB_NAME",     "nhs_waiting_list_db"),
    "charset":  "utf8mb4",
}

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Database utilities
# ---------------------------------------------------------------------------

def get_connection():
    """Return a MySQL connection. Raises on failure."""
    try:
        conn = mysql.connector.connect(**DB_CONFIG)
        log.info("Connected to MySQL: %s@%s/%s", DB_CONFIG["user"], DB_CONFIG["host"], DB_CONFIG["database"])
        return conn
    except Error as exc:
        log.critical("Could not connect to MySQL: %s", exc)
        raise


def execute(conn, sql: str, params=None, fetch: bool = False):
    """Execute a single SQL statement."""
    cursor = conn.cursor(dictionary=True)
    cursor.execute(sql, params or ())
    if fetch:
        result = cursor.fetchall()
        cursor.close()
        return result
    conn.commit()
    cursor.close()


def executemany(conn, sql: str, data: list[tuple]) -> int:
    """Bulk insert using executemany. Returns rows affected."""
    cursor = conn.cursor()
    cursor.executemany(sql, data)
    conn.commit()
    rows = cursor.rowcount
    cursor.close()
    return rows


# ---------------------------------------------------------------------------
# Dimension upserts
# ---------------------------------------------------------------------------

def upsert_trusts(conn, df: pd.DataFrame) -> None:
    """Insert trusts from data into dim_trust, resolving region_code → region_key via dim_region."""
    if "provider_org_code" not in df.columns:
        return

    has_region = "region_code" in df.columns

    select_cols = ["provider_org_code", "provider_org_name"]
    if has_region:
        select_cols.append("region_code")

    pairs_df = (
        df[select_cols]
        .dropna(subset=["provider_org_code"])
        .drop_duplicates("provider_org_code")
    )

    if has_region:
        region_rows = execute(conn, "SELECT region_code, region_key FROM dim_region", fetch=True)
        region_map  = {r["region_code"]: r["region_key"] for r in (region_rows or [])}

        pairs = [
            (
                str(row["provider_org_code"]).strip(),
                str(row["provider_org_name"]).strip(),
                region_map.get(str(row.get("region_code", "")).strip(), 1),
            )
            for _, row in pairs_df.iterrows()
        ]
        sql = """
            INSERT INTO dim_trust (trust_code, trust_name, region_key)
            VALUES (%s, %s, %s)
            ON DUPLICATE KEY UPDATE trust_name = VALUES(trust_name), region_key = VALUES(region_key)
        """
    else:
        pairs = [
            (str(row["provider_org_code"]).strip(), str(row["provider_org_name"]).strip(), 1)
            for _, row in pairs_df.iterrows()
        ]
        sql = """
            INSERT INTO dim_trust (trust_code, trust_name, region_key)
            VALUES (%s, %s, 1)
            ON DUPLICATE KEY UPDATE trust_name = VALUES(trust_name)
        """

    inserted = executemany(conn, sql, pairs)
    log.info("dim_trust upserted: %d rows", inserted)


def upsert_treatment_functions(conn, df: pd.DataFrame) -> None:
    """Insert any treatment functions not already in dim_treatment_function."""
    if "treatment_function_code" not in df.columns:
        return

    pairs = (
        df[["treatment_function_code", "treatment_function_name"]]
        .dropna(subset=["treatment_function_code"])
        .drop_duplicates("treatment_function_code")
        .values.tolist()
    )

    sql = """
        INSERT INTO dim_treatment_function (treatment_function_code, treatment_function_name)
        VALUES (%s, %s)
        ON DUPLICATE KEY UPDATE treatment_function_name = VALUES(treatment_function_name)
    """
    inserted = executemany(conn, sql, pairs)
    log.info("dim_treatment_function upserted: %d rows", inserted)


# ---------------------------------------------------------------------------
# Staging loaders
# ---------------------------------------------------------------------------

def load_staging_incomplete(conn, df: pd.DataFrame, batch_id: str) -> int:
    """Bulk-insert processed incomplete RTT data into stg_rtt_incomplete."""

    band_cols = [c for c in df.columns if c.startswith("band_")]

    rows = []
    for _, row in df.iterrows():
        base = (
            row.get("period_date", ""),
            str(row.get("provider_org_code", "")).strip(),
            str(row.get("provider_org_name", "")).strip(),
            str(row.get("treatment_function_code", "")).strip(),
            str(row.get("treatment_function_name", "")).strip(),
        )
        band_values = tuple(int(row.get(c, 0) or 0) for c in [
            "band_0_5_weeks", "band_6_10_weeks", "band_11_15_weeks",
            "band_16_18_weeks", "band_19_23_weeks", "band_24_28_weeks",
            "band_29_33_weeks", "band_34_38_weeks", "band_39_43_weeks",
            "band_44_48_weeks", "band_49_52_weeks", "band_52_plus",
        ])
        total = sum(band_values)
        rows.append(base + band_values + (total, batch_id))

    # Build INSERT matching the staging table structure (simplified 12-band)
    sql = """
        INSERT INTO stg_rtt_incomplete (
            period_date, provider_org_code, provider_org_name,
            treatment_function_code, treatment_function_name,
            band_0_to_1_weeks, band_gt1_to_2, band_gt2_to_3,
            band_gt3_to_4, band_gt4_to_5, band_gt5_to_6,
            band_gt6_to_7, band_gt7_to_8, band_gt8_to_9,
            band_gt9_to_10, band_gt10_to_11, band_gt11_to_12,
            band_gt52_plus, total_waiting, load_batch_id
        ) VALUES (
            %s, %s, %s, %s, %s,
            %s, %s, %s, %s, %s, %s, %s, %s, %s,
            %s, %s, %s, %s, %s, %s
        )
    """
    n = executemany(conn, sql, rows)
    log.info("stg_rtt_incomplete loaded: %d rows (batch: %s)", n, batch_id)
    return n


def load_staging_completed(conn, df: pd.DataFrame, batch_id: str, pathway_type: str) -> int:
    """Bulk-insert processed completed RTT data into stg_rtt_completed."""

    rows = []
    for _, row in df.iterrows():
        rows.append((
            row.get("period_date", ""),
            str(row.get("provider_org_code", "")).strip(),
            str(row.get("provider_org_name", "")).strip(),
            str(row.get("treatment_function_code", "")).strip(),
            str(row.get("treatment_function_name", "")).strip(),
            pathway_type,
            int(row.get("total_periods", 0) or 0),
            float(row.get("median_wait_weeks", 0) or 0) if pd.notna(row.get("median_wait_weeks")) else None,
            float(row.get("percentile_92_wait_weeks", 0) or 0) if pd.notna(row.get("percentile_92_wait_weeks")) else None,
            batch_id,
        ))

    sql = """
        INSERT INTO stg_rtt_completed (
            period_date, provider_org_code, provider_org_name,
            treatment_function_code, treatment_function_name,
            pathway_type, total_completed,
            median_wait_weeks, percentile_92_wait_weeks, load_batch_id
        ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
    """
    n = executemany(conn, sql, rows)
    log.info("stg_rtt_completed loaded: %d rows (batch: %s)", n, batch_id)
    return n


def load_staging_new_periods(conn, df: pd.DataFrame, batch_id: str) -> int:
    """Bulk-insert new RTT periods (referrals) into stg_rtt_new_periods."""

    rows = []
    for _, row in df.iterrows():
        rows.append((
            row.get("period_date", ""),
            str(row.get("provider_org_code", "")).strip(),
            str(row.get("provider_org_name", "")).strip(),
            str(row.get("treatment_function_code", "")).strip(),
            str(row.get("treatment_function_name", "")).strip(),
            int(row.get("total_periods", 0) or 0),
            batch_id,
        ))

    sql = """
        INSERT INTO stg_rtt_new_periods (
            period_date, provider_org_code, provider_org_name,
            treatment_function_code, treatment_function_name,
            new_rtt_periods, load_batch_id
        ) VALUES (%s, %s, %s, %s, %s, %s, %s)
    """
    n = executemany(conn, sql, rows)
    log.info("stg_rtt_new_periods loaded: %d rows (batch: %s)", n, batch_id)
    return n


# ---------------------------------------------------------------------------
# Load orchestrators
# ---------------------------------------------------------------------------

def load_incomplete(conn) -> None:
    csv_path = PROCESSED_DIR / "incomplete" / "combined.csv"
    if not csv_path.exists():
        log.warning("Processed file not found: %s — run data_processing.py first", csv_path)
        return

    df = pd.read_csv(csv_path, dtype=str, low_memory=False)
    log.info("Loaded %d rows from %s", len(df), csv_path.name)

    batch_id = f"incomplete_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    execute(conn, "TRUNCATE TABLE stg_rtt_incomplete")
    upsert_trusts(conn, df)
    upsert_treatment_functions(conn, df)
    load_staging_incomplete(conn, df, batch_id)

    execute(conn, "CALL sp_load_fact_incomplete(%s)", (batch_id,))
    log.info("sp_load_fact_incomplete completed for batch: %s", batch_id)


def load_completed(conn) -> None:
    for subtype, pathway_type in [("completed_admitted", "Admitted"), ("completed_non_admitted", "Non-Admitted")]:
        csv_path = PROCESSED_DIR / subtype / "combined.csv"
        if not csv_path.exists():
            log.warning("Processed file not found: %s", csv_path)
            continue

        df = pd.read_csv(csv_path, dtype=str, low_memory=False)
        log.info("Loaded %d rows from %s", len(df), csv_path.name)

        batch_id = f"{subtype}_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

        execute(conn, "TRUNCATE TABLE stg_rtt_completed")
        upsert_trusts(conn, df)
        upsert_treatment_functions(conn, df)
        load_staging_completed(conn, df, batch_id, pathway_type)

        execute(conn, "CALL sp_load_fact_completed(%s)", (batch_id,))
        log.info("sp_load_fact_completed completed for batch: %s", batch_id)


def load_new_periods(conn) -> None:
    csv_path = PROCESSED_DIR / "new_periods" / "combined.csv"
    if not csv_path.exists():
        log.warning("Processed file not found: %s", csv_path)
        return

    df = pd.read_csv(csv_path, dtype=str, low_memory=False)
    log.info("Loaded %d rows from %s", len(df), csv_path.name)

    batch_id = f"new_periods_{datetime.now().strftime('%Y%m%d_%H%M%S')}"

    execute(conn, "TRUNCATE TABLE stg_rtt_new_periods")
    upsert_trusts(conn, df)
    upsert_treatment_functions(conn, df)
    load_staging_new_periods(conn, df, batch_id)

    execute(conn, "CALL sp_load_fact_new_periods(%s)", (batch_id,))
    log.info("sp_load_fact_new_periods completed for batch: %s", batch_id)


def validate_load(conn) -> None:
    """Print row counts for all fact tables as a post-load sanity check."""
    log.info("=" * 60)
    log.info("POST-LOAD VALIDATION")

    for table in ["fact_rtt_incomplete", "fact_rtt_completed", "fact_rtt_new_periods"]:
        rows = execute(conn, f"SELECT COUNT(*) AS cnt FROM {table}", fetch=True)
        log.info("  %-35s  %10d rows", table, rows[0]["cnt"])

    # Check period coverage
    periods = execute(
        conn,
        "SELECT MIN(d.full_date) AS min_date, MAX(d.full_date) AS max_date "
        "FROM fact_rtt_incomplete fi JOIN dim_date d ON d.date_key = fi.date_key",
        fetch=True
    )
    if periods and periods[0]["min_date"]:
        log.info("  Period coverage: %s → %s", periods[0]["min_date"], periods[0]["max_date"])

    log.info("=" * 60)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

LOAD_MAP = {
    "incomplete":   load_incomplete,
    "completed":    load_completed,
    "new_periods":  load_new_periods,
}


def parse_args():
    parser = argparse.ArgumentParser(
        description="Load processed NHS RTT CSVs into MySQL star schema."
    )
    parser.add_argument(
        "--file-type",
        choices=list(LOAD_MAP.keys()) + ["all"],
        default="all",
        help="Which data type to load (default: all)"
    )
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    conn = get_connection()

    try:
        if args.file_type == "all":
            for loader in LOAD_MAP.values():
                loader(conn)
        else:
            LOAD_MAP[args.file_type](conn)

        validate_load(conn)

    finally:
        conn.close()
        log.info("MySQL connection closed.")
