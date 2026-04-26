# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Setup

```bash
# Create schema and seed reference data (regions, wait bands, treatment functions)
mysql -u root -p < sql/schema.sql

# Create staging tables, stored procedures, and mart views
mysql -u root -p < sql/etl.sql

# Configure database credentials
cp .env.example .env

# Install Python dependencies
pip install -r requirements.txt
```

### Running the ETL pipeline (in order)

```bash
# 1. Download NHS England RTT Excel files (defaults: FY 2019/20 → 2024/25)
python python/data_download.py --start-year 2019 --end-year 2025

# 2. Process all raw Excel files → cleaned CSVs in data/processed/
python python/data_processing.py --all

# 3. Load all CSVs → MySQL staging → fact tables
python python/load_to_mysql.py --file-type all
```

### Selective processing

```bash
# Process only one file type
python python/data_processing.py --file-type Incomplete-Provider
# Options: Incomplete-Provider | Admitted-Provider | NonAdmitted-Provider | New-Periods-Provider

# Load only one data type
python python/load_to_mysql.py --file-type incomplete
# Options: incomplete | completed | new_periods
```

## Architecture

### ETL Pipeline

Three sequential Python scripts form the pipeline:

1. **`data_download.py`** — Scrapes NHS England RTT statistics pages by financial year slug (e.g. `rtt-data-2024-25`), finds all Provider-level `.xls`/`.xlsx` download links, and saves them to `data/raw/<FY-slug>/`. Order of `PROVIDER_FILE_TYPES` matters: `NonAdmitted` must come before `Admitted` to avoid false-positive substring matches.

2. **`data_processing.py`** — Reads raw Excel files (`.xls` via `xlrd`, `.xlsx` via `openpyxl`), extracts the period date from row 4 col C, reads data from header row 13, renames columns to canonical names, filters to valid ODS trust codes (`^[A-Z0-9]{3,6}$`), and collapses 52 individual weekly band columns into 12 aggregated bands via `BAND_MAP`. Outputs four `combined.csv` files under `data/processed/{incomplete,completed_admitted,completed_non_admitted,new_periods}/`.

3. **`load_to_mysql.py`** — Reads the processed CSVs, upserts trusts and treatment functions into their dimension tables, truncates the relevant staging table, bulk-inserts via `executemany`, then calls the appropriate stored procedure (`sp_load_fact_incomplete`, `sp_load_fact_completed`, `sp_load_fact_new_periods`). Runs `validate_load()` at the end to print row counts.

### Star Schema

Three fact tables, five dimension tables:

- **`fact_rtt_incomplete`** — monthly snapshot of patients still waiting, one row per `(date, trust, treatment_function, wait_band)`. This is the headline "waiting list" figure.
- **`fact_rtt_completed`** — monthly treatments; admitted and non-admitted pathways stored in separate columns on the same row (not separate rows). `wait_band_key` defaults to 1 since completed files don't publish a band breakdown.
- **`fact_rtt_new_periods`** — monthly new RTT clock starts; used as the **referral demand proxy** central to the referral suppression hypothesis.

`dim_date.date_key` is an `INT` formatted `YYYYMM`. Financial year follows UK convention (Apr–Mar).

`dim_trust.region_key` is seeded as `1` (North East & Yorkshire placeholder) by `upsert_trusts()` — a known gap that requires a manual ODS mapping update to be accurate.

### SQL Band Unpivoting

The staging table `stg_rtt_incomplete` stores all 52 individual weekly band columns as raw integers. `sp_load_fact_incomplete` unpivots them inline using 12× `UNION ALL SELECT` blocks, mapping groups of weekly columns to the 12-band labels in `dim_wait_band`. Only non-zero band values are inserted into the fact table.

### Power BI Layer

Power BI connects to two mart views, not the fact tables directly:
- **`v_monthly_summary`** — trust/specialty/month grain; used for trust-level and specialty analysis
- **`v_national_monthly`** — England-level aggregate; includes derived columns `net_list_change` and `treatment_per_referral_ratio`

All DAX measures and the 5-page dashboard layout are specified in `powerbi/measures.md`. The key analytical measure is `[Referral to Treatment Ratio]`: when this drops below 1.0 while the waiting list also shrinks, it signals referral suppression rather than genuine throughput improvement.

### Key Data Quirks

- Excel files 2019–22 are `.xls` (xlrd engine); 2022/23+ are `.xlsx` (openpyxl engine). `read_data()` selects engine by file extension.
- Period date lives at `iloc[4, 2]` (row index 4, column index 2 = column C) in the raw Excel file.
- Data header is always at row 13 (`header=13` in `pd.read_excel`).
- `new_rtt_periods` (new clock starts) is the closest available proxy for referral demand; it is not a direct count of GP referrals.
