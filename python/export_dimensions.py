"""
NHS Waiting List Analytics — Dimension CSV Exporter
====================================================
Generates all five dimension CSVs for Databricks upload.

dim_date                — Jan 2015 → Dec 2025 (one row per month)
dim_region              — 7 NHS England regions (from schema.sql seed)
dim_wait_band           — 12 RTT wait bands (from schema.sql seed)
dim_trust               — unique trusts extracted from processed CSVs
dim_treatment_function  — unique specialties extracted from processed CSVs

Output: data/databricks_upload/dim_*.csv

Usage:
    python python/export_dimensions.py
"""

from pathlib import Path
import pandas as pd

ROOT_DIR    = Path(__file__).parent.parent
PROCESSED   = ROOT_DIR / "data" / "processed"
OUT_DIR     = ROOT_DIR / "data" / "databricks_upload"
OUT_DIR.mkdir(parents=True, exist_ok=True)


# ── dim_date ─────────────────────────────────────────────────────────────────

def make_dim_date(start: str = "2015-01-01", end: str = "2025-12-01") -> pd.DataFrame:
    dates = pd.date_range(start, end, freq="MS")          # month-start frequency
    df = pd.DataFrame({"full_date": dates})
    df["date_key"]         = df["full_date"].dt.strftime("%Y%m").astype(int)
    df["year"]             = df["full_date"].dt.year
    df["quarter"]          = df["full_date"].dt.quarter
    df["month"]            = df["full_date"].dt.month
    df["month_name"]       = df["full_date"].dt.strftime("%B")
    df["financial_year"]   = df["full_date"].apply(
        lambda d: f"{d.year}/{str(d.year + 1)[-2:]}" if d.month >= 4
                  else f"{d.year - 1}/{str(d.year)[-2:]}"
    )
    df["financial_quarter"] = df["full_date"].apply(_fin_quarter)
    df["is_covid_period"]  = (
        (df["full_date"] >= "2020-03-01") & (df["full_date"] <= "2022-03-01")
    ).astype(int)
    return df[["date_key", "full_date", "year", "quarter", "month",
               "month_name", "financial_year", "financial_quarter", "is_covid_period"]]


def _fin_quarter(d: pd.Timestamp) -> str:
    fy_start = d.year if d.month >= 4 else d.year - 1
    fy_short = f"{str(fy_start)[-2:]}{str(fy_start + 1)[-2:]}"
    q = {4: "Q1", 5: "Q1", 6: "Q1",
         7: "Q2", 8: "Q2", 9: "Q2",
         10: "Q3", 11: "Q3", 12: "Q3",
         1: "Q4", 2: "Q4", 3: "Q4"}[d.month]
    return f"{q} {fy_short}"


# ── dim_region ────────────────────────────────────────────────────────────────

def make_dim_region() -> pd.DataFrame:
    rows = [
        (1, "Y56", "North East and Yorkshire", "NHSE-NEY"),
        (2, "Y58", "North West",               "NHSE-NW"),
        (3, "Y59", "Midlands",                 "NHSE-MID"),
        (4, "Y60", "East of England",          "NHSE-EOE"),
        (5, "Y61", "London",                   "NHSE-LON"),
        (6, "Y62", "South East",               "NHSE-SE"),
        (7, "Y63", "South West",               "NHSE-SW"),
    ]
    return pd.DataFrame(rows, columns=["region_key", "region_code", "region_name", "nhs_region_abbrev"])


# ── dim_wait_band ─────────────────────────────────────────────────────────────

def make_dim_wait_band() -> pd.DataFrame:
    rows = [
        (1,  "0-5 weeks",    0,   5,  0, 0),
        (2,  "6-10 weeks",   6,  10,  0, 0),
        (3,  "11-15 weeks", 11,  15,  0, 0),
        (4,  "16-18 weeks", 16,  18,  0, 0),
        (5,  "19-23 weeks", 19,  23,  1, 0),
        (6,  "24-28 weeks", 24,  28,  1, 0),
        (7,  "29-33 weeks", 29,  33,  1, 0),
        (8,  "34-38 weeks", 34,  38,  1, 0),
        (9,  "39-43 weeks", 39,  43,  1, 0),
        (10, "44-48 weeks", 44,  48,  1, 0),
        (11, "49-52 weeks", 49,  52,  1, 0),
        (12, "52+ weeks",   52, None, 1, 1),
    ]
    return pd.DataFrame(rows, columns=[
        "wait_band_key", "band_label", "lower_weeks",
        "upper_weeks", "is_breach", "is_long_waiter"
    ])


# ── dim_trust ─────────────────────────────────────────────────────────────────

def make_dim_trust() -> pd.DataFrame:
    frames = []
    for csv in PROCESSED.rglob("combined.csv"):
        df = pd.read_csv(csv, usecols=["provider_org_code", "provider_org_name"],
                         dtype=str, low_memory=False)
        frames.append(df)

    combined = pd.concat(frames, ignore_index=True)
    trusts = (
        combined
        .dropna(subset=["provider_org_code"])
        .drop_duplicates("provider_org_code")
        .sort_values("provider_org_code")
        .reset_index(drop=True)
    )
    trusts["trust_key"]   = trusts.index + 1
    trusts["region_key"]  = 1          # placeholder — ODS mapping not available in source data
    trusts["is_active"]   = 1
    trusts = trusts.rename(columns={
        "provider_org_code": "trust_code",
        "provider_org_name": "trust_name",
    })
    return trusts[["trust_key", "trust_code", "trust_name", "region_key", "is_active"]]


# ── dim_treatment_function ────────────────────────────────────────────────────

def make_dim_treatment_function() -> pd.DataFrame:
    frames = []
    for csv in PROCESSED.rglob("combined.csv"):
        df = pd.read_csv(
            csv,
            usecols=["treatment_function_code", "treatment_function_name"],
            dtype=str, low_memory=False,
        )
        frames.append(df)

    combined = pd.concat(frames, ignore_index=True)
    tfs = (
        combined
        .dropna(subset=["treatment_function_code"])
        .drop_duplicates("treatment_function_code")
        .sort_values("treatment_function_code")
        .reset_index(drop=True)
    )
    tfs["treatment_function_key"] = tfs.index + 1
    return tfs[["treatment_function_key", "treatment_function_code", "treatment_function_name"]]


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    dims = {
        "dim_date":                 make_dim_date(),
        "dim_region":               make_dim_region(),
        "dim_wait_band":            make_dim_wait_band(),
        "dim_trust":                make_dim_trust(),
        "dim_treatment_function":   make_dim_treatment_function(),
    }

    for name, df in dims.items():
        path = OUT_DIR / f"{name}.csv"
        df.to_csv(path, index=False)
        print(f"  {name:<30}  {len(df):>6} rows  →  {path.name}")

    print(f"\nAll dimension CSVs written to: {OUT_DIR}")


if __name__ == "__main__":
    main()
