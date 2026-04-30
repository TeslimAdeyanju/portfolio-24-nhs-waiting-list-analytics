# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Setup

```bash
# Configure database credentials first
cp .env.example .env

# Install Python dependencies
pip install -r requirements.txt

# Create schema and seed reference data (regions, wait bands, treatment functions)
mysql -u root -p < sql/schema.sql

# Create staging tables, stored procedures, mart views, and populate dim_date
# sp_populate_dim_date('2015-01-01', '2025-12-01') is called automatically at the end of this file
mysql -u root -p < sql/etl.sql
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

### Analytical queries

```bash
# Run the 7 core analytical queries against the star schema
mysql -u root -p nhs_waiting_list_db < sql/analysis.sql
```

## Architecture

### Two Deployment Tracks

The project has two separate analytical deployment paths that share the same Python ETL pipeline and processed CSVs:

1. **MySQL track** (primary): `sql/schema.sql` + `sql/etl.sql` → Power BI via `v_monthly_summary` and `v_national_monthly` mart views
2. **Databricks track** (alternative): `databricks/02_create_delta_tables.sql` + `databricks/03_create_gold_views.sql` → Databricks Community Edition + Delta Lake, queried via DB Visualizer

Both tracks consume the same `data/processed/*/combined.csv` output from `data_processing.py`.

### ETL Pipeline

Three sequential Python scripts form the pipeline:

1. **`python/data_download.py`** — Scrapes NHS England RTT statistics pages by financial year slug (e.g. `rtt-data-2024-25`), finds all Provider-level `.xls`/`.xlsx` download links, and saves them to `data/raw/<FY-slug>/`. Order of `PROVIDER_FILE_TYPES` matters: `NonAdmitted` must come before `Admitted` to avoid false-positive substring matches.

2. **`python/data_processing.py`** — Reads raw Excel files (`.xls` via `xlrd`, `.xlsx` via `openpyxl`), extracts the period date from row 4 col C, reads data from header row 13, renames columns to canonical names, filters to valid ODS trust codes (`^[A-Z0-9]{3,6}$`), and collapses 52 individual weekly band columns into 12 aggregated bands via `BAND_MAP`. Outputs four `combined.csv` files under `data/processed/{incomplete,completed_admitted,completed_non_admitted,new_periods}/`.

3. **`python/load_to_mysql.py`** — Reads the processed CSVs, upserts trusts and treatment functions into their dimension tables, truncates the relevant staging table, bulk-inserts via `executemany`, then calls the appropriate stored procedure (`sp_load_fact_incomplete`, `sp_load_fact_completed`, `sp_load_fact_new_periods`). Runs `validate_load()` at the end to print row counts.

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

### Databricks Track

The `databricks/` directory is a cloud analytics layer on top of the same processed CSVs:

- `01_upload_processed_csvs.md` — step-by-step guide: rename CSVs, upload to Databricks FileStore, verify, connect DbVisualizer and Power BI.
- `02_create_delta_tables.sql` — creates `fact_rtt_incomplete`, `fact_rtt_completed` (admitted + non-admitted unioned), and `fact_rtt_new_periods` as Delta tables from `/FileStore/tables/`.
- `03_create_gold_views.sql` — recreates `v_monthly_summary` (trust/specialty/month grain, joining all three Delta tables) and `v_national_monthly` (England aggregate with `net_list_change` and `treatment_per_referral_ratio`) using the flat Delta table columns rather than the MySQL star schema joins.
- `04_dbvisualizer_queries.sql` — the full 7-query analytical suite adapted for Databricks SQL, plus connection-check commands for DbVisualizer.

### Core Analytical Queries

`sql/analysis.sql` contains 7 pre-built queries against the MySQL star schema:

1. National waiting list trend (with 12-month rolling average and MoM/YoY change)
2. Referrals vs Treatments vs List Size — the core "referral suppression" killer query
3. Long waiter (52+ weeks) trend and breach rate
4. Specialty-level pressure (throughput ratio by treatment function)
5. Regional performance benchmarking (referral index vs national average)
6. Trust-level performance scorecard (league table ranked by breach rate)
7. Pre/Post COVID recovery trajectory (indexed to FY 2019/20 baseline)

### Key Data Quirks

- Excel files 2019–22 are `.xls` (xlrd engine); 2022/23+ are `.xlsx` (openpyxl engine). `read_data()` selects engine by file extension.
- Period date lives at `iloc[4, 2]` (row index 4, column index 2 = column C) in the raw Excel file.
- Data header is always at row 13 (`header=13` in `pd.read_excel`).
- `new_rtt_periods` (new clock starts) is the closest available proxy for referral demand; it is not a direct count of GP referrals.
- `load_to_mysql.py`'s `load_staging_incomplete()` maps 12 aggregated band columns to 12 of the 52 staging columns. The column names it reads from the CSV (`band_0_to_1_weeks`, `band_gt1_to_2`, etc.) differ from what `data_processing.py` produces (`band_0_5_wks`, `band_6_10_wks`, etc.) — any fix must align these names across both scripts.
