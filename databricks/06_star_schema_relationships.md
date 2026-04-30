# NHS Waiting List Analytics — Star Schema Relationship Report

**Catalog:** `nhs` | **Schema:** `nhs_waiting_list` | **Platform:** Databricks Delta Lake

---

## Overview

The star schema layer (`05_create_star_schema.sql`) transforms the flat Delta tables created in Step 2 into a proper dimensional model. Natural business keys (ODS trust codes, period dates, treatment function codes) are resolved into integer surrogate keys, enabling fast joins and consistent aggregation across all four fact tables.

The schema follows the classic **star topology**: five dimension tables sit at the centre, and four fact tables reference them via foreign keys. Each fact table captures a different analytical grain of the NHS Referral to Treatment (RTT) pathway.

---

## Entity Relationship Diagram

![NHS Waiting List Analytics — Star Schema](screenshots2/image.png)

---

## Dimension Tables

### dim_date

The time dimension. One row per month from January 2015 to December 2025 (132 rows). Every fact table joins to `dim_date` via `date_key` (an integer in `YYYYMM` format, e.g. `202309` = September 2023).

| Column | Type | Description |
| --- | --- | --- |
| `date_key` | INT | Surrogate key — format YYYYMM |
| `full_date` | DATE | First day of the month |
| `year` | INT | Calendar year |
| `quarter` | INT | Calendar quarter (1–4) |
| `month` | INT | Month number (1–12) |
| `month_name` | STRING | Month name (January … December) |
| `financial_year` | STRING | UK financial year (e.g. `2023/24`) |
| `financial_quarter` | STRING | Financial quarter (e.g. `Q2 2324`) |
| `is_covid_period` | INT | 1 = March 2020 – March 2022; 0 otherwise |

The `is_covid_period` flag exists because NHS England published data with quality caveats throughout the COVID period. It allows analysts to exclude or clearly label those rows in trend analysis.

---

### dim_trust

NHS provider trusts. One row per unique ODS organisation code (189 rows). Joins to fact tables via `trust_key`.

| Column | Type | Description |
| --- | --- | --- |
| `trust_key` | INT | Surrogate key |
| `trust_code` | STRING | ODS code (3–6 alphanumeric characters) |
| `trust_name` | STRING | Full trust name |
| `region_key` | INT | Foreign key to `dim_region` |
| `is_active` | INT | 1 = active trust in the dataset |

**Known gap:** `region_key` defaults to `1` (North East & Yorkshire) for all trusts. A full ODS-to-region mapping is not reliably available in the NHS England RTT source files. Analysts should join through the trust's `region_key` for a consistent grouping, but treat regional attribution at trust level as approximate.

---

### dim_region

The seven NHS England regions. One row per region (7 rows). Referenced by `dim_trust.region_key` and denormalised into all star fact tables as `region_key` at load time.

| Column | Type | Description |
| --- | --- | --- |
| `region_key` | INT | Surrogate key (1–7) |
| `region_code` | STRING | NHS England region code (Y56, Y58–Y63; Y57 not used) |
| `region_name` | STRING | Full region name |
| `nhs_region_abbrev` | STRING | Short form (e.g. `NHSE-LON`) |

The regions are: North East and Yorkshire (Y56), North West (Y58), Midlands (Y59), East of England (Y60), London (Y61), South East (Y62), South West (Y63).

---

### dim_treatment_function

Clinical specialties. One row per treatment function code (25 rows). Every fact table joins via `treatment_function_key` to enable specialty-level analysis.

| Column | Type | Description |
| --- | --- | --- |
| `treatment_function_key` | INT | Surrogate key |
| `treatment_function_code` | STRING | NHS treatment function code |
| `treatment_function_name` | STRING | Clinical specialty name (e.g. Trauma & Orthopaedics) |

---

### dim_wait_band

The 12 RTT reporting wait bands. One row per band (12 rows). **Joins only to `fact_rtt_wait_band_star`** — not to `fact_rtt_incomplete_star`, where bands are stored as wide columns rather than rows.

| Column | Type | Description |
| --- | --- | --- |
| `wait_band_key` | INT | Surrogate key (1–12) |
| `band_label` | STRING | Human-readable label (e.g. `19-23 weeks`) |
| `lower_weeks` | INT | Lower bound (inclusive) |
| `upper_weeks` | INT | Upper bound (inclusive; NULL for 52+) |
| `is_breach` | INT | 1 = band exceeds the 18-week RTT standard |
| `is_long_waiter` | INT | 1 = band is 52+ weeks (political KPI) |

The 18-week standard requires 92% of patients to be treated within 18 weeks. Any band above 18 weeks (`is_breach = 1`) contributes to the breach rate. The 52+ week band (`is_long_waiter = 1`) is tracked separately as a political and clinical priority.

---

## Fact Tables

### fact_rtt_incomplete_star

**Grain:** one row per `(period, trust, treatment function)`

The headline waiting list measure. Captures every patient currently waiting at the end of each month, by trust and specialty. Contains 12 wide wait band columns that provide a snapshot of how long those patients have been waiting. Also stores the overall `median_wait_weeks` and `percentile_92_wait_weeks` (the P92 target measure).

**Key measures:** `total_waiting`, `median_wait_weeks`, `percentile_92_wait_weeks`, `band_0_5_wks` … `band_52_plus`

**Row count:** ~85,360

---

### fact_rtt_completed_star

**Grain:** one row per `(period, trust, treatment function, pathway type)`

Records completed RTT pathways — patients who finished their wait during the month. Distinguishes `'Admitted'` (inpatient/daycase) and `'Non-Admitted'` (outpatient) pathways via the `pathway_type` column. Both pathway types are sourced from separate raw CSVs and unioned in the build step; `try_cast(period_date AS DATE)` filters out malformed date strings present in the admitted source file.

**Key measures:** `total_completed`, `median_wait_weeks`, `percentile_92_wait_weeks`, `pathway_type`

**Row count:** ~552,128

---

### fact_rtt_new_periods_star

**Grain:** one row per `(period, trust, treatment function)`

Monthly new RTT clock starts — the closest available proxy for referral demand across the dataset. A "new period" is not a raw GP referral count; it includes self-referrals and internal re-referrals, making it a broader but consistent demand signal across all periods.

The key analytical measure derived from this table is `treatment_per_referral_ratio = total_completed / new_rtt_periods`. When this ratio drops below 1.0 while the waiting list simultaneously shrinks, it signals demand suppression rather than genuine throughput improvement.

**Key measures:** `new_rtt_periods`

**Row count:** ~276,064

---

### fact_rtt_wait_band_star

**Grain:** one row per `(period, trust, treatment function, wait band)`

An unpivoted version of `fact_rtt_incomplete_star`. The 12 wide band columns from the source table are converted into individual rows, one per band per record, so that `dim_wait_band` can be used directly as a filter and aggregation axis. Only bands with `waiting_count > 0` are loaded.

This table is built from a 12-branch `UNION ALL` CTE (`unpivoted`) inside `05_create_star_schema.sql` — an inline unpivot pattern that avoids `UNPIVOT` syntax limitations in Databricks SQL. It carries the `is_breach` and `is_long_waiter` flags directly from `dim_wait_band` at load time, avoiding repeated joins in downstream queries.

**Key measures:** `waiting_count`, `band_label`, `is_breach`, `is_long_waiter`

**Row count:** ~553,983

---

## Relationship Table

| Dimension | Primary Key | Fact Table | Foreign Key | Analytical Purpose |
| --- | --- | --- | --- | --- |
| `dim_date` | `date_key` | `fact_rtt_incomplete_star` | `date_key` | Waiting list by month, financial year, COVID period |
| `dim_date` | `date_key` | `fact_rtt_completed_star` | `date_key` | Treatments by month, financial year |
| `dim_date` | `date_key` | `fact_rtt_new_periods_star` | `date_key` | New RTT periods by month |
| `dim_date` | `date_key` | `fact_rtt_wait_band_star` | `date_key` | Wait band distribution over time |
| `dim_trust` | `trust_key` | all four star fact tables | `trust_key` | Analyse by NHS provider organisation |
| `dim_region` | `region_key` | all four star fact tables | `region_key` | Analyse by NHS England region |
| `dim_treatment_function` | `treatment_function_key` | all four star fact tables | `treatment_function_key` | Analyse by clinical specialty |
| `dim_wait_band` | `wait_band_key` | `fact_rtt_wait_band_star` only | `wait_band_key` | Filter and aggregate by wait band, breach, long-waiter |

---

## Analytical Join Patterns

### 1. Waiting list by financial year, region, trust, and specialty

```sql
SELECT
    d.financial_year,
    r.region_name,
    t.trust_name,
    tf.treatment_function_name,
    SUM(f.total_waiting)          AS total_waiting,
    SUM(f.band_52_plus)           AS long_waiters_52_plus,
    AVG(f.percentile_92_wait_weeks) AS avg_p92_wait
FROM fact_rtt_incomplete_star f
JOIN dim_date d
    ON f.date_key = d.date_key
JOIN dim_trust t
    ON f.trust_key = t.trust_key
JOIN dim_region r
    ON f.region_key = r.region_key
JOIN dim_treatment_function tf
    ON f.treatment_function_key = tf.treatment_function_key
GROUP BY
    d.financial_year,
    r.region_name,
    t.trust_name,
    tf.treatment_function_name
ORDER BY
    d.financial_year,
    total_waiting DESC;
```

---

### 2. Completed treatments by pathway type, region, and specialty

```sql
SELECT
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    f.pathway_type,
    SUM(f.total_completed)          AS total_completed,
    AVG(f.median_wait_weeks)        AS avg_median_wait
FROM fact_rtt_completed_star f
JOIN dim_date d
    ON f.date_key = d.date_key
JOIN dim_region r
    ON f.region_key = r.region_key
JOIN dim_treatment_function tf
    ON f.treatment_function_key = tf.treatment_function_key
GROUP BY
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    f.pathway_type
ORDER BY
    d.financial_year,
    total_completed DESC;
```

---

### 3. Referral demand trend by region and specialty

```sql
SELECT
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    SUM(f.new_rtt_periods)  AS new_rtt_periods
FROM fact_rtt_new_periods_star f
JOIN dim_date d
    ON f.date_key = d.date_key
JOIN dim_region r
    ON f.region_key = r.region_key
JOIN dim_treatment_function tf
    ON f.treatment_function_key = tf.treatment_function_key
GROUP BY
    d.financial_year,
    r.region_name,
    tf.treatment_function_name
ORDER BY
    d.financial_year,
    new_rtt_periods DESC;
```

---

### 4. Wait band breach analysis by region and specialty

```sql
SELECT
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    wb.band_label,
    wb.is_breach,
    wb.is_long_waiter,
    SUM(f.waiting_count)  AS patients_waiting
FROM fact_rtt_wait_band_star f
JOIN dim_date d
    ON f.date_key = d.date_key
JOIN dim_region r
    ON f.region_key = r.region_key
JOIN dim_treatment_function tf
    ON f.treatment_function_key = tf.treatment_function_key
JOIN dim_wait_band wb
    ON f.wait_band_key = wb.wait_band_key
GROUP BY
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    wb.band_label,
    wb.is_breach,
    wb.is_long_waiter
ORDER BY
    d.financial_year,
    patients_waiting DESC;
```

---

### 5. Referral suppression signal — core analytical query

Compares referral demand (`new_rtt_periods`) against completed treatments to compute the referral-to-treatment ratio. A ratio below 1.0 while the waiting list simultaneously shrinks indicates demand suppression, not genuine throughput improvement.

```sql
-- Each fact table is aggregated to date grain first to prevent fanout
-- when three multi-row fact tables are joined on date_key alone.
WITH incomplete AS (
    SELECT date_key, SUM(total_waiting)   AS total_waiting
    FROM fact_rtt_incomplete_star
    GROUP BY date_key
),
completed AS (
    SELECT date_key, SUM(total_completed) AS total_completed
    FROM fact_rtt_completed_star
    GROUP BY date_key
),
new_periods AS (
    SELECT date_key, SUM(new_rtt_periods) AS new_rtt_periods
    FROM fact_rtt_new_periods_star
    GROUP BY date_key
)
SELECT
    d.financial_year,
    d.month_name,
    d.is_covid_period,
    i.total_waiting,
    c.total_completed,
    n.new_rtt_periods,
    ROUND(c.total_completed / NULLIF(n.new_rtt_periods, 0), 3) AS treatment_per_referral_ratio,
    i.total_waiting - LAG(i.total_waiting) OVER (ORDER BY d.date_key) AS mom_list_change
FROM incomplete i
JOIN dim_date d
    ON i.date_key = d.date_key
LEFT JOIN completed c
    ON i.date_key = c.date_key
LEFT JOIN new_periods n
    ON i.date_key = n.date_key
ORDER BY d.date_key;
```

---

## Design Decisions

### Why surrogate keys?

The raw source data uses natural business keys: ODS trust codes (e.g. `RJ1`), treatment function codes (e.g. `110`), and period dates. Surrogate integer keys (`trust_key`, `treatment_function_key`, `date_key`) replace these in the star schema for three reasons:

1. **Join performance** — integer equality joins are faster than string comparisons across millions of rows
2. **Stability** — surrogate keys do not change if an ODS code is corrected or a trust merges; the dimension row is simply updated
3. **Referential integrity** — a NULL surrogate key in a fact row immediately identifies an unresolved record, which the data quality check in Step 6 surfaces

### Why is dim_wait_band only on fact_rtt_wait_band_star?

The NHS England RTT source files publish wait bands as **columns** (one column per band per row). `fact_rtt_incomplete_star` preserves this wide format because it allows efficient computation of derived totals (`band_52_plus`, `band_19_23_wks + band_24_28_wks + ...`) without a separate join.

`fact_rtt_wait_band_star` is the **row-oriented** counterpart: it unpivots those 12 columns into individual rows so that `dim_wait_band` can serve as a filter and aggregation axis. Analysts choose the table based on their query:

- **Wide bands needed** (e.g. summing multiple bands, computing breach rate from the incomplete snapshot) → `fact_rtt_incomplete_star`
- **Band-level filtering or grouping** (e.g. how many patients are in each band this month) → `fact_rtt_wait_band_star` + `dim_wait_band`

### Why region_key in every fact table?

`region_key` is denormalised from `dim_trust` directly into each fact table at build time. This avoids a two-hop join (`fact → dim_trust → dim_region`) in every regional analysis query and ensures consistent regional grouping even if an analyst omits `dim_trust` from their query entirely.

---

## Build Order and Dependencies

The star schema tables must be built in this order because later steps depend on earlier ones:

```
01_upload_processed_csvs.md   Upload CSVs to FileStore
02_create_delta_tables.sql    Build flat fact + dimension Delta tables
                              (required before 05 can run)
05_create_star_schema.sql     STEP 1: Verify dimension tables (132 / 189 / 7 / 25 / 12)
                              STEP 2: fact_rtt_incomplete_star
                              STEP 3: fact_rtt_completed_star
                              STEP 4: fact_rtt_new_periods_star
                              STEP 5: fact_rtt_wait_band_star
                              STEP 6: Data quality checks (expected: 0 missing keys)
                              STEP 7: Drill-down validation query
                              STEP 8: Wait band breach analysis
```

The dimension tables (`dim_date`, `dim_trust`, `dim_region`, `dim_treatment_function`, `dim_wait_band`) are created in `02_create_delta_tables.sql` and must be fully populated before `05_create_star_schema.sql` runs. Step 1 of `05_create_star_schema.sql` verifies this with a row count check.

---

## Expected Row Counts

| Table | Expected Rows | Notes |
| --- | --- | --- |
| `dim_date` | 132 | Jan 2015 – Dec 2025 (one row per month) |
| `dim_trust` | 189 | Unique NHS trust ODS codes in the dataset |
| `dim_region` | 7 | Fixed NHS England regions (Y56–Y63) |
| `dim_treatment_function` | 25 | Clinical specialties present in RTT data |
| `dim_wait_band` | 12 | Fixed RTT reporting bands |
| `fact_rtt_incomplete_star` | ~85,360 | Monthly waiting list snapshot |
| `fact_rtt_completed_star` | ~552,128 | Admitted + Non-Admitted pathways combined |
| `fact_rtt_new_periods_star` | ~276,064 | Monthly new RTT clock starts |
| `fact_rtt_wait_band_star` | ~553,983 | Unpivoted band rows (non-zero only) |
