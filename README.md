# NHS Waiting List Analytics

> **The NHS waiting list grew from 4.4 million in March 2020 to 7.7 million by September 2023 — even as referrals collapsed 40% during COVID.**
> This project builds an end-to-end analytics pipeline to separate what is actually driving that number.

---

## What this project is

An end-to-end analytics pipeline using **real NHS England RTT (Referral to Treatment) statistics**, covering **all NHS England provider trusts** across **April 2019 – December 2025** (monthly).

It models the work of an NHS performance analytics function: ingesting monthly waiting time publications, computing demand and supply KPIs, and surfacing the referral suppression hypothesis in Power BI.

The core analytical question is whether apparent improvements to the NHS waiting list reflect genuine throughput gains — or a reduction in the number of patients being referred into the system in the first place.

---

## Key findings

| Metric | Pre-COVID (FY 2019/20) | COVID peak (Apr–Jun 2020) | Latest (FY 2024/25) |
| ------ | ---------------------- | ------------------------- | -------------------- |
| Total patients waiting | ~4.4m | ~3.2m | ~7.5m |
| New referrals per month | ~1.3m | ~0.8m | ~1.4m |
| 52+ week waiters | <2,000 | ~21,000 | ~300,000+ |
| Referral-to-Treatment Ratio | ~1.0 | ~0.6 | ~1.0 |
| Breach rate (>18 weeks) | ~16% | ~40% | ~38% |

**The headline:** The waiting list grew despite referrals collapsing. As suppressed demand returned post-COVID, the ratio exceeded 1.0 and the list expanded sharply. Where the list appeared to improve, the referral index — not treatment throughput — was the dominant mechanism.

---

## NHS domain coverage

| Convention | Implementation |
| ---------- | -------------- |
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
| ----- | -------------- |
| Data engineering | Python pipeline scraping ~600 monthly Excel files from NHS England and loading into MySQL via staging tables |
| Dimensional modelling | Star schema: 3 fact tables · 5 dimension tables; staging → fact transformation via stored procedures |
| SQL analytics | 7 analytical queries and 2 mart views using window functions (`LAG`, `RANK`, `OVER`), CTEs, and `UNION ALL` unpivoting |
| Python web scraping | BeautifulSoup scraping of NHS England RTT pages; automatic `.xls` (xlrd) / `.xlsx` (openpyxl) engine selection by year |
| Data normalisation | 52 individual weekly band columns collapsed to 12 reporting bands via `BAND_MAP` in processing layer |
| Power BI & DAX | Time intelligence, rolling averages, referral index measures, dual-axis charts, filled UK map |
| NHS domain knowledge | RTT framework, 18-week standard, incomplete/completed/new pathway distinctions, referral suppression analysis |

---

## Database schema

**`nhs_waiting_list_db`**

| Table / View | Description |
| ------------ | ----------- |
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

---

## Project structure

```
├── sql/
│   ├── schema.sql          Star schema DDL — dimensions, fact tables, reference seed data
│   ├── etl.sql             Staging tables, stored procedures, mart views
│   └── analysis.sql        7 analytical queries (KPIs, benchmarking, COVID recovery)
│
├── python/
│   ├── data_download.py    Scrapes and downloads RTT Excel files from NHS England (2019–2025)
│   ├── data_processing.py  Cleans and normalises Excel → CSV; aggregates 52 bands → 12
│   └── load_to_mysql.py    Upserts dimensions, bulk-loads staging, calls stored procedures
│
├── powerbi/
│   └── measures.md         All DAX measures + 5-page dashboard layout specification
│
├── notebooks/
│   └── 01_referral_suppression_analysis.ipynb   Exploratory analysis with charts
│
├── data/
│   ├── raw/                Downloaded NHS England .xls / .xlsx files (gitignored)
│   └── processed/          Cleaned CSVs ready for MySQL import (gitignored)
│
├── .env.example            Database credentials template
└── requirements.txt        Python dependencies
```

---

## Power BI dashboard (5 pages)

| Page | Visuals |
| ---- | ------- |
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
# 1. Create the schema and seed reference data
mysql -u root -p < sql/schema.sql

# 2. Build staging tables, stored procedures, and mart views
mysql -u root -p < sql/etl.sql

# 3. Configure database credentials
cp .env.example .env
# Edit .env — set DB_HOST, DB_USER, DB_PASSWORD, DB_NAME

# 4. Install Python dependencies
pip install -r requirements.txt

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

---

## Data notes

- `new_rtt_periods` counts new RTT **clock starts**, not raw GP referrals. It includes self-referrals and internal re-referrals, making it a broader but consistent proxy for demand across all periods.
- NHS England RTT files before 2022/23 use `.xls` format (xlrd engine); from 2022/23 onwards they use `.xlsx` (openpyxl). The pipeline selects the engine automatically.
- NHS England published data with quality caveats throughout the COVID period (Mar 2020 – Mar 2022). `dim_date.is_covid_period` flags these rows so they can be excluded from or clearly labelled in trend analysis.
- The 18-week standard (92% of patients treated within 18 weeks) has not been met nationally since July 2015. `dim_wait_band.is_breach` reflects the standard, not current performance.
- Source: [NHS England RTT Waiting Times Statistics](https://www.england.nhs.uk/statistics/statistical-work-areas/rtt-waiting-times/) — published monthly, freely available under the [Open Government Licence v3.0](https://www.nationalarchives.gov.uk/doc/open-government-licence/version/3/).
