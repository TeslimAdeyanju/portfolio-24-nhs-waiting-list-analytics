"""
NHS Waiting List Analytics - Data Processing Script
====================================================
Reads raw NHS England RTT Excel files (xls + xlsx) and writes
clean, normalised CSVs ready for MySQL import.

File structure (confirmed from NHS England files 2019-2025):
    Row 0:  blank
    Row 1:  Title
    Row 2:  Summary
    Row 3:  blank
    Row 4:  Period:  'April 2019'    ← extract period from here
    ...
    Row 12: 'Provider Level Data'
    Row 13: Column headers           ← header=13
    Row 14+: Data rows

Columns (Incomplete / Admitted / NonAdmitted):
    Unnamed:0, Region Code, Provider Code, Provider Name,
    Treatment Function Code, Treatment Function,
    >0-1, >1-2, ..., >51-52, 52 plus,
    Total number of incomplete pathways,
    Total within 18 weeks, % within 18 weeks,
    Average (median) waiting time (in weeks),
    92nd percentile waiting time (in weeks)

Columns (New Periods):
    Unnamed:0, Region Code, Provider Code, Provider Name,
    Treatment Function Code, Treatment Function,
    Number of new RTT clock starts during the month

Usage:
    python data_processing.py --all
    python data_processing.py --file-type Incomplete-Provider

Author: Teslim Uthman Adeyanju
Date:   April 2026
"""

import logging
import argparse
from pathlib import Path

import pandas as pd

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

ROOT_DIR      = Path(__file__).parent.parent
RAW_DIR       = ROOT_DIR / "data" / "raw"
PROCESSED_DIR = ROOT_DIR / "data" / "processed"
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  %(levelname)-8s  %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FILE_TYPE_MAP = {
    "Incomplete-Provider":   "incomplete",
    "Admitted-Provider":     "completed_admitted",
    "NonAdmitted-Provider":  "completed_non_admitted",
    "New-Periods-Provider":  "new_periods",
}

# Weekly band columns exactly as they appear in NHSE files
WEEK_BANDS = [f">{i}-{i+1}" for i in range(52)]   # '>0-1' → '>51-52'

# Aggregated bands (our 12-band schema → maps week ranges)
BAND_MAP = {
    "band_0_5_wks":   list(range(0, 5)),    # >0-1 through >4-5
    "band_6_10_wks":  list(range(5, 10)),   # >5-6 through >9-10
    "band_11_15_wks": list(range(10, 15)),  # >10-11 through >14-15
    "band_16_18_wks": list(range(15, 18)),  # >15-16 through >17-18
    "band_19_23_wks": list(range(18, 23)),  # >18-19 through >22-23
    "band_24_28_wks": list(range(23, 28)),
    "band_29_33_wks": list(range(28, 33)),
    "band_34_38_wks": list(range(33, 38)),
    "band_39_43_wks": list(range(38, 43)),
    "band_44_48_wks": list(range(43, 48)),
    "band_49_52_wks": list(range(48, 52)),  # >48-49 through >51-52
    "band_52_plus":   None,                 # special: '52 plus' column
}


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def extract_period(filepath: Path) -> str:
    """
    Read the period date directly from cell B4 of the Excel file.
    Returns ISO string 'YYYY-MM-01' or the raw string on failure.
    """
    try:
        meta = pd.read_excel(filepath, sheet_name=0, header=None, nrows=6)
        raw = str(meta.iloc[4, 2]).strip()   # row 4, col C  (0-indexed: 4, 2)
        dt = pd.to_datetime(raw, format="%B %Y")
        return dt.strftime("%Y-%m-01")
    except Exception:
        return "Unknown"


def read_data(filepath: Path) -> pd.DataFrame:
    """
    Read the main data table from an NHSE RTT file.
    Header is always on row 13 (0-indexed).
    """
    engine = "xlrd" if filepath.suffix.lower() == ".xls" else "openpyxl"
    df = pd.read_excel(filepath, sheet_name=0, header=13, engine=engine)
    return df


def rename_core_cols(df: pd.DataFrame) -> pd.DataFrame:
    """Rename NHS England column names to our canonical names."""
    return df.rename(columns={
        "Region Code":           "region_code",
        "Provider Code":         "provider_org_code",
        "Provider Name":         "provider_org_name",
        "Treatment Function Code": "treatment_function_code",
        "Treatment Function":    "treatment_function_name",
        "Number of new RTT clock starts during the month": "new_rtt_periods",
        "Total number of incomplete pathways": "total_waiting",
        "Average (median) waiting time (in weeks)": "median_wait_weeks",
        "92nd percentile waiting time (in weeks)": "percentile_92_wait_weeks",
    })


def clean_rows(df: pd.DataFrame) -> pd.DataFrame:
    """Drop blank / aggregate / non-trust rows."""
    df = df.dropna(subset=["provider_org_code"])
    # Keep only real ODS codes (3-5 alphanumeric chars, not 'nan', 'Total' etc.)
    df = df[df["provider_org_code"].astype(str).str.match(r"^[A-Z0-9]{3,6}$", na=False)]
    return df.reset_index(drop=True)


def aggregate_bands(df: pd.DataFrame) -> pd.DataFrame:
    """
    Collapse 52 weekly columns + '52 plus' into 12 reporting bands.
    """
    for band_name, week_indices in BAND_MAP.items():
        if week_indices is None:
            # '52 plus' column
            df[band_name] = pd.to_numeric(df.get("52 plus", 0), errors="coerce").fillna(0).astype(int)
        else:
            cols = [WEEK_BANDS[i] for i in week_indices if WEEK_BANDS[i] in df.columns]
            if cols:
                df[band_name] = df[cols].apply(pd.to_numeric, errors="coerce").fillna(0).sum(axis=1).astype(int)
            else:
                df[band_name] = 0
    return df


# ---------------------------------------------------------------------------
# Per file-type processors
# ---------------------------------------------------------------------------

BASE_COLS = ["region_code", "provider_org_code", "provider_org_name",
             "treatment_function_code", "treatment_function_name"]

BAND_COLS = list(BAND_MAP.keys())


def process_incomplete(filepath: Path) -> pd.DataFrame:
    period = extract_period(filepath)
    df = rename_core_cols(read_data(filepath))
    df = clean_rows(df)
    df = aggregate_bands(df)

    out = df[BASE_COLS + BAND_COLS].copy()
    out["total_waiting"]           = pd.to_numeric(df.get("total_waiting"),           errors="coerce").fillna(0).astype(int)
    out["median_wait_weeks"]       = pd.to_numeric(df.get("median_wait_weeks"),       errors="coerce")
    out["percentile_92_wait_weeks"]= pd.to_numeric(df.get("percentile_92_wait_weeks"),errors="coerce")
    out["period_date"]  = period
    out["source_file"]  = filepath.name
    return out


def process_completed(filepath: Path, pathway_type: str) -> pd.DataFrame:
    period = extract_period(filepath)
    df = rename_core_cols(read_data(filepath))
    df = clean_rows(df)

    out = df[BASE_COLS].copy()
    total_col = next(
        (c for c in df.columns if "total number of completed" in str(c).lower()),
        None
    )
    out["total_completed"] = pd.to_numeric(
        df[total_col] if total_col else 0, errors="coerce"
    ).fillna(0).astype(int)
    out["median_wait_weeks"]        = pd.to_numeric(df.get("median_wait_weeks"),        errors="coerce")
    out["percentile_92_wait_weeks"] = pd.to_numeric(df.get("percentile_92_wait_weeks"), errors="coerce")
    out["pathway_type"] = pathway_type
    out["period_date"]  = period
    out["source_file"]  = filepath.name
    return out


def process_new_periods(filepath: Path) -> pd.DataFrame:
    period = extract_period(filepath)
    df = rename_core_cols(read_data(filepath))
    df = clean_rows(df)

    out = df[BASE_COLS].copy()
    out["new_rtt_periods"] = pd.to_numeric(df.get("new_rtt_periods", 0), errors="coerce").fillna(0).astype(int)
    out["period_date"]     = period
    out["source_file"]     = filepath.name
    return out


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

PROCESSORS = {
    "Incomplete-Provider":   (process_incomplete,   None),
    "Admitted-Provider":     (process_completed,    "Admitted"),
    "NonAdmitted-Provider":  (process_completed,    "Non-Admitted"),
    "New-Periods-Provider":  (process_new_periods,  None),
}


def process_file_type(file_type_key: str) -> None:
    fn, pathway_type = PROCESSORS[file_type_key]
    label     = FILE_TYPE_MAP[file_type_key]
    out_dir   = PROCESSED_DIR / label
    out_dir.mkdir(exist_ok=True)

    raw_files = sorted(RAW_DIR.rglob(f"*{file_type_key}*.xls*"))
    if not raw_files:
        log.warning("No files found matching: *%s*.xls*", file_type_key)
        return

    log.info("Processing %d files → %s", len(raw_files), label)
    frames = []

    for fp in raw_files:
        log.info("  %s", fp.name)
        try:
            if pathway_type is not None:
                df = fn(fp, pathway_type)
            else:
                df = fn(fp)

            if df.empty:
                log.warning("    empty result")
                continue

            frames.append(df)
            log.info("    %d rows  period=%s", len(df), df["period_date"].iloc[0])

        except Exception as exc:
            log.error("    FAILED: %s", exc, exc_info=False)

    if not frames:
        log.warning("No data extracted for: %s", file_type_key)
        return

    combined = pd.concat(frames, ignore_index=True)
    dedup_cols = ["period_date", "provider_org_code", "treatment_function_code"]
    if pathway_type:
        dedup_cols.append("pathway_type")
    combined = combined.drop_duplicates(subset=dedup_cols, keep="first")

    out_path = out_dir / "combined.csv"
    combined.to_csv(out_path, index=False)
    log.info(
        "Saved: %s — %d rows, %d periods, %d providers",
        out_path.name, len(combined),
        combined["period_date"].nunique(),
        combined["provider_org_code"].nunique()
    )


def process_all() -> None:
    for key in PROCESSORS:
        process_file_type(key)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    parser = argparse.ArgumentParser(
        description="Process NHS England RTT Excel files into clean CSVs."
    )
    grp = parser.add_mutually_exclusive_group(required=True)
    grp.add_argument("--file-type", choices=list(PROCESSORS.keys()))
    grp.add_argument("--all", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    if args.all:
        process_all()
    else:
        process_file_type(args.file_type)
