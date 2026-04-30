-- ============================================================
-- NHS Waiting List Analytics — Databricks Star Schema Layer
-- Database:  nhs_waiting_list
-- Purpose:   Convert raw flat Delta tables into a proper star
--            schema by resolving natural keys (org codes, dates)
--            into surrogate keys from dimension tables.
--
-- Why this matters:
--   The raw fact tables (02_create_delta_tables.sql) use natural
--   keys such as provider_org_code and period_date. A star schema
--   replaces these with integer surrogate keys (trust_key, date_key
--   etc.) so that fact tables join to dimension tables efficiently
--   on indexed integers rather than string comparisons.
--
-- Tables created:
--   fact_rtt_incomplete_star      — waiting list with surrogate keys
--   fact_rtt_completed_star       — treatments with surrogate keys
--   fact_rtt_new_periods_star     — referrals with surrogate keys
--   fact_rtt_wait_band_star       — unpivoted wait bands (one row
--                                   per trust/specialty/month/band)
--                                   enabling full dim_wait_band joins
--
-- Run order:
--   01_upload_processed_csvs.md   ← upload CSVs
--   02_create_delta_tables.sql    ← raw flat tables
--   03_create_gold_views.sql      ← aggregated mart views
--   04_dbvisualizer_queries.sql   ← analytical queries
--   05_create_star_schema.sql     ← THIS FILE (star schema layer)
--
-- Author:    Teslim Uthman Adeyanju
-- Date:      April 2026
-- ============================================================

USE nhs_waiting_list;


-- ============================================================
-- STEP 1: Verify dimension tables are populated before proceeding
-- ============================================================

SELECT 'dim_date'               AS dim_table, COUNT(*) AS row_count FROM nhs_waiting_list.dim_date
UNION ALL
SELECT 'dim_trust',                           COUNT(*) FROM nhs_waiting_list.dim_trust
UNION ALL
SELECT 'dim_region',                          COUNT(*) FROM nhs_waiting_list.dim_region
UNION ALL
SELECT 'dim_treatment_function',              COUNT(*) FROM nhs_waiting_list.dim_treatment_function
UNION ALL
SELECT 'dim_wait_band',                       COUNT(*) FROM nhs_waiting_list.dim_wait_band;

-- Expected: 132 | 189 | 7 | 25 | 12


-- ============================================================
-- STEP 2: fact_rtt_incomplete_star
--
-- Resolves:
--   period_date       → date_key  (via dim_date.full_date)
--   provider_org_code → trust_key (via dim_trust.trust_code)
--   provider_org_code → region_key (via dim_trust.region_key)
--   tf_code           → treatment_function_key
--
-- Grain: one row per (date_key, trust_key, treatment_function_key)
-- Measure: total_waiting + 12 individual wait band columns
-- ============================================================

CREATE OR REPLACE TABLE nhs_waiting_list.fact_rtt_incomplete_star
USING DELTA AS
SELECT
    -- Surrogate keys (dimension references)
    d.date_key,
    t.trust_key,
    t.region_key,
    tf.treatment_function_key,

    -- Measures
    f.total_waiting,
    f.median_wait_weeks,
    f.percentile_92_wait_weeks,

    -- Wait band breakdown (wide format — kept for flexibility)
    f.band_0_5_wks,
    f.band_6_10_wks,
    f.band_11_15_wks,
    f.band_16_18_wks,
    f.band_19_23_wks,
    f.band_24_28_wks,
    f.band_29_33_wks,
    f.band_34_38_wks,
    f.band_39_43_wks,
    f.band_44_48_wks,
    f.band_49_52_wks,
    f.band_52_plus,

    -- Audit columns (retained for lineage tracing)
    f.period_date,
    f.provider_org_code,
    f.treatment_function_code,
    f.source_file

FROM nhs_waiting_list.fact_rtt_incomplete f
LEFT JOIN nhs_waiting_list.dim_date                d  ON f.period_date             = d.full_date
LEFT JOIN nhs_waiting_list.dim_trust               t  ON f.provider_org_code        = t.trust_code
LEFT JOIN nhs_waiting_list.dim_treatment_function  tf ON f.treatment_function_code  = tf.treatment_function_code;


-- ============================================================
-- STEP 3: fact_rtt_completed_star
--
-- Source: fact_rtt_completed contains both Admitted and
-- Non-Admitted pathways (unioned in 02_create_delta_tables.sql).
-- pathway_type column distinguishes the two.
--
-- Note: period_date may be stored as STRING in the combined table
-- (admitted CSV had string dates). CAST handles this safely.
-- ============================================================

CREATE OR REPLACE TABLE nhs_waiting_list.fact_rtt_completed_star
USING DELTA AS
SELECT
    d.date_key,
    t.trust_key,
    t.region_key,
    tf.treatment_function_key,

    f.total_completed,
    f.median_wait_weeks,
    f.percentile_92_wait_weeks,
    f.pathway_type,

    f.period_date,
    f.provider_org_code,
    f.treatment_function_code,
    f.source_file

FROM nhs_waiting_list.fact_rtt_completed f
LEFT JOIN nhs_waiting_list.dim_date                d  ON CAST(f.period_date AS DATE) = d.full_date
LEFT JOIN nhs_waiting_list.dim_trust               t  ON f.provider_org_code          = t.trust_code
LEFT JOIN nhs_waiting_list.dim_treatment_function  tf ON f.treatment_function_code    = tf.treatment_function_code;


-- ============================================================
-- STEP 4: fact_rtt_new_periods_star
--
-- Monthly new RTT clock starts — the referral demand proxy.
-- Used with fact_rtt_incomplete_star to compute the
-- referral-to-treatment ratio and net list change.
-- ============================================================

CREATE OR REPLACE TABLE nhs_waiting_list.fact_rtt_new_periods_star
USING DELTA AS
SELECT
    d.date_key,
    t.trust_key,
    t.region_key,
    tf.treatment_function_key,

    f.new_rtt_periods,

    f.period_date,
    f.provider_org_code,
    f.treatment_function_code,
    f.source_file

FROM nhs_waiting_list.fact_rtt_new_periods f
LEFT JOIN nhs_waiting_list.dim_date                d  ON f.period_date            = d.full_date
LEFT JOIN nhs_waiting_list.dim_trust               t  ON f.provider_org_code       = t.trust_code
LEFT JOIN nhs_waiting_list.dim_treatment_function  tf ON f.treatment_function_code = tf.treatment_function_code;


-- ============================================================
-- STEP 5: fact_rtt_wait_band_star  (UNPIVOT)
--
-- This is the most analytically powerful table in the schema.
-- It converts the 12 wide wait band columns into rows, adding
-- wait_band_key so that dim_wait_band can filter and aggregate
-- directly against the fact data.
--
-- Pattern: each UNION ALL block extracts one band column,
-- labels it with the matching band_label from dim_wait_band,
-- and joins to dim_wait_band on that label to resolve the key.
-- WHERE waiting_count > 0 removes empty cells to keep the
-- table lean (matching the stored procedure logic in MySQL).
--
-- Grain: one row per (date_key, trust_key,
--                     treatment_function_key, wait_band_key)
-- Measure: waiting_count (patients in this band this month)
-- ============================================================

CREATE OR REPLACE TABLE nhs_waiting_list.fact_rtt_wait_band_star
USING DELTA AS

WITH unpivoted AS (

    -- Band 1: 0–5 weeks (within 18-week standard)
    SELECT period_date, provider_org_code, treatment_function_code,
           '0-5 weeks' AS band_label, band_0_5_wks AS waiting_count
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_0_5_wks > 0

    UNION ALL

    -- Band 2: 6–10 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '6-10 weeks', band_6_10_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_6_10_wks > 0

    UNION ALL

    -- Band 3: 11–15 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '11-15 weeks', band_11_15_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_11_15_wks > 0

    UNION ALL

    -- Band 4: 16–18 weeks (last band within standard)
    SELECT period_date, provider_org_code, treatment_function_code,
           '16-18 weeks', band_16_18_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_16_18_wks > 0

    UNION ALL

    -- Band 5: 19–23 weeks (BREACH — beyond 18-week standard)
    SELECT period_date, provider_org_code, treatment_function_code,
           '19-23 weeks', band_19_23_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_19_23_wks > 0

    UNION ALL

    -- Band 6: 24–28 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '24-28 weeks', band_24_28_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_24_28_wks > 0

    UNION ALL

    -- Band 7: 29–33 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '29-33 weeks', band_29_33_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_29_33_wks > 0

    UNION ALL

    -- Band 8: 34–38 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '34-38 weeks', band_34_38_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_34_38_wks > 0

    UNION ALL

    -- Band 9: 39–43 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '39-43 weeks', band_39_43_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_39_43_wks > 0

    UNION ALL

    -- Band 10: 44–48 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '44-48 weeks', band_44_48_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_44_48_wks > 0

    UNION ALL

    -- Band 11: 49–52 weeks
    SELECT period_date, provider_org_code, treatment_function_code,
           '49-52 weeks', band_49_52_wks
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_49_52_wks > 0

    UNION ALL

    -- Band 12: 52+ weeks (LONG WAITERS — key NHSE political metric)
    SELECT period_date, provider_org_code, treatment_function_code,
           '52+ weeks', band_52_plus
    FROM nhs_waiting_list.fact_rtt_incomplete WHERE band_52_plus > 0

)

SELECT
    d.date_key,
    t.trust_key,
    t.region_key,
    tf.treatment_function_key,
    wb.wait_band_key,

    -- Dimension attributes denormalised for query convenience
    wb.band_label,
    wb.is_breach,
    wb.is_long_waiter,

    u.waiting_count,

    u.period_date,
    u.provider_org_code,
    u.treatment_function_code

FROM unpivoted u
JOIN nhs_waiting_list.dim_date                d  ON u.period_date            = d.full_date
JOIN nhs_waiting_list.dim_trust               t  ON u.provider_org_code       = t.trust_code
JOIN nhs_waiting_list.dim_treatment_function  tf ON u.treatment_function_code = tf.treatment_function_code
JOIN nhs_waiting_list.dim_wait_band           wb ON u.band_label              = wb.band_label;


-- ============================================================
-- STEP 6: Data quality check — confirm surrogate key resolution
--
-- Missing keys mean the dimension table does not contain a
-- matching entry for that natural key. Ideally all counts = 0.
-- ============================================================

SELECT
    COUNT(*)                                                         AS total_rows,
    SUM(CASE WHEN date_key              IS NULL THEN 1 ELSE 0 END)  AS missing_date_key,
    SUM(CASE WHEN trust_key             IS NULL THEN 1 ELSE 0 END)  AS missing_trust_key,
    SUM(CASE WHEN region_key            IS NULL THEN 1 ELSE 0 END)  AS missing_region_key,
    SUM(CASE WHEN treatment_function_key IS NULL THEN 1 ELSE 0 END) AS missing_tf_key,
    SUM(CASE WHEN wait_band_key         IS NULL THEN 1 ELSE 0 END)  AS missing_band_key
FROM nhs_waiting_list.fact_rtt_wait_band_star;


-- ============================================================
-- STEP 7: Star schema drill-down validation query
--
-- Demonstrates the full dimensional join chain:
--   fact → dim_date → dim_trust → dim_region → dim_treatment_function
--
-- If this returns meaningful data, the star schema is working.
-- ============================================================

SELECT
    d.financial_year,
    d.month_name,
    r.region_name,
    t.trust_name,
    tf.treatment_function_name,
    SUM(f.total_waiting)    AS total_waiting
FROM nhs_waiting_list.fact_rtt_incomplete_star f
JOIN nhs_waiting_list.dim_date               d  ON f.date_key               = d.date_key
JOIN nhs_waiting_list.dim_trust              t  ON f.trust_key               = t.trust_key
JOIN nhs_waiting_list.dim_region             r  ON f.region_key              = r.region_key
JOIN nhs_waiting_list.dim_treatment_function tf ON f.treatment_function_key  = tf.treatment_function_key
GROUP BY
    d.financial_year,
    d.year,
    d.month,
    d.month_name,
    r.region_name,
    t.trust_name,
    tf.treatment_function_name
ORDER BY
    d.year,
    d.month,
    r.region_name,
    t.trust_name
LIMIT 50;


-- ============================================================
-- STEP 8: Wait band drill-down — breach and long waiter analysis
--
-- Uses fact_rtt_wait_band_star to filter by is_breach and
-- is_long_waiter flags from dim_wait_band.
-- This query is only possible with the unpivoted star table.
-- ============================================================

SELECT
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    wb.band_label,
    wb.is_breach,
    wb.is_long_waiter,
    SUM(f.waiting_count) AS patients_waiting
FROM nhs_waiting_list.fact_rtt_wait_band_star f
JOIN nhs_waiting_list.dim_date               d  ON f.date_key               = d.date_key
JOIN nhs_waiting_list.dim_trust              t  ON f.trust_key               = t.trust_key
JOIN nhs_waiting_list.dim_region             r  ON f.region_key              = r.region_key
JOIN nhs_waiting_list.dim_treatment_function tf ON f.treatment_function_key  = tf.treatment_function_key
JOIN nhs_waiting_list.dim_wait_band          wb ON f.wait_band_key           = wb.wait_band_key
WHERE wb.is_breach = 1
GROUP BY
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    wb.band_label,
    wb.is_breach,
    wb.is_long_waiter
ORDER BY
    d.financial_year,
    patients_waiting DESC
LIMIT 50;


-- ============================================================
-- Final star schema summary
-- ============================================================

SELECT 'fact_rtt_incomplete_star'  AS table_name, COUNT(*) AS row_count FROM nhs_waiting_list.fact_rtt_incomplete_star
UNION ALL
SELECT 'fact_rtt_completed_star',                 COUNT(*) FROM nhs_waiting_list.fact_rtt_completed_star
UNION ALL
SELECT 'fact_rtt_new_periods_star',               COUNT(*) FROM nhs_waiting_list.fact_rtt_new_periods_star
UNION ALL
SELECT 'fact_rtt_wait_band_star',                 COUNT(*) FROM nhs_waiting_list.fact_rtt_wait_band_star;
