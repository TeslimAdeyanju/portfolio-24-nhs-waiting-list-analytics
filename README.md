# NHS Waiting List Analytics

> **The NHS waiting list grew from 4.4 million in March 2020 to 7.7 million by September 2023 — even as referrals collapsed 40% during COVID.**
> This project builds an end-to-end analytics pipeline to separate what is actually driving that number.

---

## What this project is

An end-to-end analytics pipeline using **real NHS England RTT (Referral to Treatment) statistics**, covering **all NHS England provider trusts** across **April 2019 – December 2025** (monthly).

It models the work of an NHS performance analytics function: ingesting monthly waiting time publications, computing demand and supply KPIs, and surfacing the referral suppression hypothesis in Power BI.

The core analytical question is whether apparent improvements to the NHS waiting list reflect genuine throughput gains — or a reduction in the number of patients being referred into the system in the first place.

For a complete guide covering the NHS context, RTT framework, data model, pipeline, KPIs, findings, and glossary, see **[PROJECT_DOCUMENTATION.md](PROJECT_DOCUMENTATION.md)**.

---

## Data Architecture

This project implements a full four-stage analytics pipeline — from raw source files through to interactive dashboards — and runs two parallel deployment tracks: a **local MySQL data warehouse** and a **Databricks cloud lakehouse**.

### Stage 1 — Data Extraction (ETL)

Operational data is pulled from NHS England's public RTT statistics pages and transformed into clean, structured files ready for loading.

**Extract** — `python/data_download.py` scrapes the NHS England RTT statistics website by financial year (2019/20 → 2024/25), finds all Provider-level `.xls` / `.xlsx` download links using BeautifulSoup, and saves ~600 monthly Excel files to `data/raw/`. This directory is the **data lake** — raw files in their original NHS England format, untouched.

**Transform** — `python/data_processing.py` reads each Excel file, extracts the reporting period from row 4, reads data from header row 13, renames columns to canonical names, filters to valid ODS trust codes, and collapses 52 individual weekly band columns into 12 aggregated reporting bands via `BAND_MAP`. Output: four `combined.csv` files in `data/processed/`.

**Load** — `python/load_to_mysql.py` reads the processed CSVs, upserts NHS trusts and treatment functions into their dimension tables, truncates the relevant staging table, bulk-inserts via `executemany`, and calls the appropriate stored procedure to populate the fact tables.

> **ETL not ELT:** Data is fully transformed before it reaches the database — the staging tables receive clean, structured rows and the stored procedures perform the final dimensional join. This is a textbook ETL pattern, as opposed to ELT where raw data lands first and is transformed inside the target system.

---

### Stage 2 — Load into Structured Table Schema

Processed data is loaded into a structured schema of tables optimised for analytical queries. This project implements **both** a relational data warehouse and a cloud lakehouse in parallel.

#### Option B — Relational Data Warehouse (MySQL)

The primary analytical layer is a **star schema** in MySQL (`nhs_waiting_list_db`):

- **Fact tables** store quantitative, measurable events — one row per `(date, trust, treatment_function, wait_band)` — with numeric measures (`patients_waiting`, `total_completed`, `new_rtt_periods`) and foreign keys linking to dimension tables.
- **Dimension tables** surround the fact tables and provide descriptive context: `dim_date` (financial year, COVID period flag), `dim_trust` (ODS code, region), `dim_region` (7 NHS England regions), `dim_treatment_function` (clinical specialty), `dim_wait_band` (18-week breach flag, long-waiter flag).
- **Denormalisation** happens at this stage — raw 52-column NHSE pivot files are flattened and collapsed into 12 reporting bands, eliminating the need for complex joins at query time.

The staging tables (`stg_rtt_incomplete`, `stg_rtt_completed`, `stg_rtt_new_periods`) act as a landing zone. Stored procedures then unpivot the band columns using 12× `UNION ALL SELECT` blocks and resolve organisation codes to surrogate keys before inserting into the fact tables.

#### Option A — Spark-based Data Lakehouse (Databricks)

The cloud layer uses **Databricks Community Edition with Delta Lake** (`databricks/02_create_delta_tables.sql`). The same processed CSVs from `data/processed/` are uploaded to Databricks FileStore and converted to Delta tables — a tabular abstraction layer placed on top of the files. The data looks and behaves like database tables but is physically stored as columnar Delta files, giving faster queries and ACID transaction support without a separate relational engine.

---

### Stage 3 — Aggregation into an OLAP Model

Raw fact data is aggregated into pre-computed analytical views and an OLAP reporting layer, so analysts and dashboards can query KPIs instantly without scanning millions of rows.

#### Mart views (pre-aggregated measures)

- `v_monthly_summary` — trust / specialty / month grain. Pre-computes `total_waiting`, `waiting_over_18wks`, `waiting_over_52wks`, `total_completed`, `new_rtt_periods`, and wait percentiles by joining all three fact tables. Used directly by Power BI.
- `v_national_monthly` — England-level aggregate. Adds derived measures: `net_list_change` (referrals minus treatments) and `treatment_per_referral_ratio`. This is the view that surfaces the referral suppression signal. Equivalent gold views exist in Databricks (`databricks/03_create_gold_views.sql`).

#### Power BI DAX measures (OLAP query layer)

The DAX measures in `powerbi/measures.md` form the OLAP model consumed by the dashboard:

- **Measures** — `[Total Waiting]`, `[Breach Rate %]`, `[Referral to Treatment Ratio]`, `[Long Waiters 52+]`
- **Dimensions** — Time (`dim_date`), Geography (`dim_region`), Specialty (`dim_treatment_function`), Organisation (`dim_trust`)
- **Slicing** — Power BI slicers filter by Financial Year, NHS Region, Specialty Group, COVID Period, Trust
- **Dicing** — multiple slicers applied simultaneously, e.g. South East region + Trauma & Orthopaedics + FY 2023/24
- **Drill down** — `dim_date` hierarchy: Financial Year → Financial Quarter → Month
- **Time intelligence** — `[Waiting List YoY Change]` uses `SAMEPERIODLASTYEAR`; `[FY-TD Treated]` uses `DATESYTD` with a 31 March UK financial year end; rolling averages use `DATESINPERIOD`

The key analytical measure is `[Referral to Treatment Ratio]`: when this drops below 1.0 while the waiting list also shrinks, it indicates referral suppression rather than genuine throughput improvement.

---

### Stage 4 — Reports, Dashboards, and Visualisations

The final consumption layer surfaces the analysis to different audiences through three tools.

#### Power BI (business users and stakeholders)

A 5-page interactive dashboard connecting to `v_monthly_summary` and `v_national_monthly` via DirectQuery or import mode. See [Power BI dashboard](#power-bi-dashboard-5-pages) for the full page breakdown.

#### DbVisualizer (data analysts)

DbVisualizer connects to the **Databricks SQL Warehouse via JDBC**, allowing external SQL querying of the Delta tables without opening the Databricks UI. `databricks/04_dbvisualizer_queries.sql` contains 7 pre-built analytical queries — from the national waiting list trend through to the trust performance league table — ready to run directly in DbVisualizer.

#### Python notebooks (exploratory analysis)

`notebooks/01_referral_suppression_analysis.ipynb` contains exploratory analysis with matplotlib and seaborn charts, examining the referral suppression signal directly from the processed CSVs using Python.

---

## Key findings

| Metric | Pre-COVID (FY 2019/20) | COVID peak (Apr–Jun 2020) | Latest (FY 2024/25) |
| --- | --- | --- | --- |
| Total patients waiting | ~4.4m | ~3.2m | ~7.5m |
| New referrals per month | ~1.3m | ~0.8m | ~1.4m |
| 52+ week waiters | <2,000 | ~21,000 | ~300,000+ |
| Referral-to-Treatment Ratio | ~1.0 | ~0.6 | ~1.0 |
| Breach rate (>18 weeks) | ~16% | ~40% | ~38% |

**The headline:** The waiting list grew despite referrals collapsing. As suppressed demand returned post-COVID, the ratio exceeded 1.0 and the list expanded sharply. Where the list appeared to improve, the referral index — not treatment throughput — was the dominant mechanism.

---

## NHS domain coverage

| Convention | Implementation |
| --- | --- |
| RTT 18-week standard | `dim_wait_band.is_breach = 1` for bands >18 weeks; breach rate computed in mart views |
| Long waiter (52+) tracking | `dim_wait_band.is_long_waiter = 1`; political KPI tracked separately in all analytical queries |
| NHS financial year (Apr–Mar) | `dim_date.financial_year` and `financial_quarter` built via stored procedure across Jan 2015 – Dec 2025 |
| ODS organisation codes | 3–6 character trust codes (`trust_code`) as the join key across all dimension and fact tables |
| NHS England regions | 7 NHSE regions seeded into `dim_region` (region codes Y56–Y63) |
| RTT pathway types | Incomplete, admitted, non-admitted and new periods modelled as separate fact tables |
| COVID period flagging | `dim_date.is_covid_period = 1` for Mar 2020 – Mar 2022; used in pre/post benchmarking queries |

---

## Technical skills demonstrated

| Skill | Implementation |
| --- | --- |
| Data engineering | Python ETL pipeline scraping ~600 monthly Excel files from NHS England and loading into MySQL via staging tables |
| Dimensional modelling | Star schema: 3 fact tables · 5 dimension tables; staging → fact transformation via stored procedures |
| SQL analytics | 7 analytical queries and 2 mart views using window functions (`LAG`, `RANK`, `OVER`), CTEs, and `UNION ALL` unpivoting |
| Python web scraping | BeautifulSoup scraping of NHS England RTT pages; automatic `.xls` (xlrd) / `.xlsx` (openpyxl) engine selection by year |
| Data normalisation | 52 individual weekly band columns collapsed to 12 reporting bands via `BAND_MAP` in processing layer |
| Databricks & Delta Lake | Cloud lakehouse track: Delta tables from processed CSVs, gold views, SQL Warehouse queried via DbVisualizer JDBC |
| Power BI & DAX | Time intelligence, rolling averages, referral index measures, dual-axis charts, filled UK map |
| NHS domain knowledge | RTT framework, 18-week standard, incomplete/completed/new pathway distinctions, referral suppression analysis |

---

## Database schema

**`nhs_waiting_list_db`** (MySQL — local track)

| Table / View | Description |
| --- | --- |
| `dim_date` | Calendar dimension Jan 2015 – Dec 2025; financial year, quarter, COVID period flag |
| `dim_trust` | NHS Trust reference — ODS code, name, region key |
| `dim_region` | 7 NHS England regions (Y56–Y63) |
| `dim_treatment_function` | Clinical specialty — code, name, specialty group (Surgical / Medical / Mental Health) |
| `dim_wait_band` | 12 wait bands; `is_breach` (>18 wks) and `is_long_waiter` (52+ wks) flags |
| `fact_rtt_incomplete` | Monthly waiting list snapshot — one row per trust / specialty / wait band |
| `fact_rtt_completed` | Monthly treatments — admitted and non-admitted pathway counts, median wait, P92 |
| `fact_rtt_new_periods` | Monthly new RTT clock starts — referral demand proxy |
| `stg_rtt_incomplete` | Staging: raw 52-column NHSE format, one row per trust/specialty/period |
| `stg_rtt_completed` | Staging: completed pathway data before stored-procedure transformation |
| `stg_rtt_new_periods` | Staging: new period data before stored-procedure transformation |
| `v_monthly_summary` | Mart view: trust/specialty/month grain — used directly by Power BI |
| `v_national_monthly` | Mart view: England-level aggregates + derived `net_list_change`, `treatment_per_referral_ratio` |

**`nhs_waiting_list`** (Databricks — cloud track)

| Table / View | Description |
| --- | --- |
| `fact_rtt_incomplete` | Delta table from `fact_rtt_incomplete.csv` |
| `fact_rtt_completed` | Delta table — admitted and non-admitted CSVs unioned |
| `fact_rtt_new_periods` | Delta table from `fact_rtt_new_periods.csv` |
| `v_monthly_summary` | Gold view: trust/specialty/month grain, joining all three Delta tables |
| `v_national_monthly` | Gold view: England-level aggregate with `net_list_change` and `treatment_per_referral_ratio` |

---

## Project structure

```text
├── sql/
│   ├── schema.sql              Star schema DDL — dimensions, fact tables, reference seed data
│   ├── etl.sql                 Staging tables, stored procedures, mart views
│   └── analysis.sql            7 analytical queries (KPIs, benchmarking, COVID recovery)
│
├── python/
│   ├── data_download.py        Scrapes and downloads RTT Excel files from NHS England (2019–2025)
│   ├── data_processing.py      Cleans and normalises Excel → CSV; aggregates 52 bands → 12
│   ├── load_to_mysql.py        Upserts dimensions, bulk-loads staging, calls stored procedures
│   └── export_dimensions.py    Generates all 5 dimension CSVs for Databricks upload
│
├── databricks/
│   ├── 01_upload_processed_csvs.md     Step-by-step upload guide + DbVisualizer / Power BI connection
│   ├── 02_create_delta_tables.sql      Creates Delta tables from uploaded CSVs
│   ├── 03_create_gold_views.sql        v_monthly_summary and v_national_monthly gold views
│   ├── 04_dbvisualizer_queries.sql     7 analytical queries for DbVisualizer
│   ├── 05_create_star_schema.sql       Star schema layer — surrogate key resolution + wait band unpivot
│   └── 06_star_schema_relationships.md ERD, relationship table, join patterns, design decisions
│
├── powerbi/
│   └── measures.md             All DAX measures + 5-page dashboard layout specification
│
├── notebooks/
│   └── 01_referral_suppression_analysis.ipynb   Exploratory analysis with charts
│
├── data/
│   ├── raw/                    Downloaded NHS England .xls / .xlsx files (gitignored)
│   ├── processed/              Cleaned CSVs ready for MySQL import (gitignored)
│   └── databricks_upload/      Renamed CSVs ready for Databricks FileStore upload (gitignored)
│
├── .env.example                Database credentials template
└── requirements.txt            Python dependencies
```

---

## Power BI dashboard (5 pages)

| Page | Visuals |
| --- | --- |
| National Overview | KPI cards · trend line (waiting + referrals + treatments) · COVID shading |
| Core Insight | Dual-axis: referrals vs waiting list · Referral-to-Treatment Ratio · scatter by trust |
| Long Waiter Deep Dive | 52-week trend by specialty · waterfall MoM change · peak annotation |
| Regional Scorecard | Filled UK map (breach rate %) · region × financial year matrix |
| Trust League Table | Sortable table · conditional formatting · breach rank within region |

Full DAX measures and layout specification: [powerbi/measures.md](powerbi/measures.md)

---

## Reproduce from scratch

**Prerequisites:** Python 3.11+ · MySQL 8.0+ · Power BI Desktop (for dashboard only)

```bash
# 1. Configure database credentials
cp .env.example .env

# 2. Install Python dependencies
pip install -r requirements.txt

# 3. Create the schema and seed reference data
mysql -u root -p < sql/schema.sql

# 4. Build staging tables, stored procedures, and mart views
mysql -u root -p < sql/etl.sql

# 5. Download NHS England RTT files (~600 Excel files, FY 2019/20 → 2024/25)
python python/data_download.py --start-year 2019 --end-year 2025

# 6. Process raw Excel files → cleaned CSVs
python python/data_processing.py --all

# 7. Load into MySQL (upserts dimensions + calls stored procedures)
python python/load_to_mysql.py --file-type all

# 8. Connect Power BI
#    Get Data → MySQL → Server: localhost, Database: nhs_waiting_list_db
#    Import: v_monthly_summary · v_national_monthly · all dim_* tables
#    Apply DAX measures from powerbi/measures.md
```

**To run the Databricks cloud track instead:**

```bash
# Generate dimension CSVs
python python/export_dimensions.py

# Upload all 9 files from data/databricks_upload/ to Databricks FileStore
# (see databricks/01_upload_processed_csvs.md for step-by-step)

# Then run in Databricks SQL Editor:
# 1. databricks/02_create_delta_tables.sql
# 2. databricks/03_create_gold_views.sql
# 3. Connect DbVisualizer via JDBC and run databricks/04_dbvisualizer_queries.sql
```

---

## Documentation

| File | Purpose |
| --- | --- |
| **[PROJECT_DOCUMENTATION.md](PROJECT_DOCUMENTATION.md)** | Complete 15-section guide: NHS context, RTT framework, data model, pipeline, KPIs, findings, Power BI, glossary |
| **[databricks/06_star_schema_relationships.md](databricks/06_star_schema_relationships.md)** | Star schema ERD, relationship table, all join patterns, design decisions |
| **[databricks/01_upload_processed_csvs.md](databricks/01_upload_processed_csvs.md)** | Step-by-step Databricks upload guide; DbVisualizer and Power BI JDBC connection |
| **[powerbi/measures.md](powerbi/measures.md)** | All DAX measures and 5-page dashboard layout specification |

---

## Data notes

- `new_rtt_periods` counts new RTT **clock starts**, not raw GP referrals. It includes self-referrals and internal re-referrals, making it a broader but consistent proxy for demand across all periods.
- NHS England RTT files before 2022/23 use `.xls` format (xlrd engine); from 2022/23 onwards they use `.xlsx` (openpyxl). The pipeline selects the engine automatically.
- NHS England published data with quality caveats throughout the COVID period (Mar 2020 – Mar 2022). `dim_date.is_covid_period` flags these rows so they can be excluded from or clearly labelled in trend analysis.
- The 18-week standard (92% of patients treated within 18 weeks) has not been met nationally since July 2015. `dim_wait_band.is_breach` reflects the standard, not current performance.
- Source: [NHS England RTT Waiting Times Statistics](https://www.england.nhs.uk/statistics/statistical-work-areas/rtt-waiting-times/) — published monthly, freely available under the [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
