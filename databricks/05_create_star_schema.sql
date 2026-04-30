-- ============================================================
-- NHS Waiting List Analytics — Databricks Star Schema Layer
-- Catalog:   nhs
-- Schema:    nhs_waiting_list
-- Purpose:   Convert raw flat Delta tables into a proper star
--            schema by resolving natural keys into surrogate keys.
--
-- Author:    Teslim Uthman Adeyanju
-- Date:      April 2026
-- ============================================================

USE CATALOG nhs;
USE SCHEMA nhs_waiting_list;

-- ============================================================
-- STEP 1: Verify dimension tables
-- Expected: dim_date 132 | dim_trust 189 | dim_region 7
--           dim_treatment_function 25 | dim_wait_band 12
-- ============================================================

SELECT 'dim_date' AS dim_table, COUNT(*) AS row_count FROM dim_date
UNION ALL
SELECT 'dim_trust', COUNT(*) FROM dim_trust
UNION ALL
SELECT 'dim_region', COUNT(*) FROM dim_region
UNION ALL
SELECT 'dim_treatment_function', COUNT(*) FROM dim_treatment_function
UNION ALL
SELECT 'dim_wait_band', COUNT(*) FROM dim_wait_band;

-- ============================================================
-- STEP 2: fact_rtt_incomplete_star
-- Grain: one row per period, trust, and treatment function
-- ============================================================

CREATE OR REPLACE TABLE fact_rtt_incomplete_star
USING DELTA AS
SELECT
    d.date_key,
    t.trust_key,
    t.region_key,
    tf.treatment_function_key,

    f.total_waiting,
    f.median_wait_weeks,
    f.percentile_92_wait_weeks,

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

    f.period_date,
    f.provider_org_code,
    f.treatment_function_code,
    f.source_file
FROM fact_rtt_incomplete f
LEFT JOIN dim_date d
    ON f.period_date = d.full_date
LEFT JOIN dim_trust t
    ON f.provider_org_code = t.trust_code
LEFT JOIN dim_treatment_function tf
    ON f.treatment_function_code = tf.treatment_function_code;

-- ============================================================
-- STEP 3: fact_rtt_completed_star
-- Combines admitted and non-admitted completed pathways
-- try_cast handles malformed dates such as 'Unknown'
-- ============================================================

CREATE OR REPLACE TABLE fact_rtt_completed_star
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
FROM (
    SELECT
        provider_org_code,
        provider_org_name,
        treatment_function_code,
        treatment_function_name,
        total_completed,
        median_wait_weeks,
        percentile_92_wait_weeks,
        'Admitted' AS pathway_type,
        try_cast(period_date AS DATE) AS period_date,
        source_file
    FROM fact_rtt_completed_admitted
    WHERE try_cast(period_date AS DATE) IS NOT NULL

    UNION ALL

    SELECT
        provider_org_code,
        provider_org_name,
        treatment_function_code,
        treatment_function_name,
        total_completed,
        median_wait_weeks,
        percentile_92_wait_weeks,
        'Non-Admitted' AS pathway_type,
        try_cast(period_date AS DATE) AS period_date,
        source_file
    FROM fact_rtt_completed_non_admitted
    WHERE try_cast(period_date AS DATE) IS NOT NULL
) f
LEFT JOIN dim_date d
    ON f.period_date = d.full_date
LEFT JOIN dim_trust t
    ON f.provider_org_code = t.trust_code
LEFT JOIN dim_treatment_function tf
    ON f.treatment_function_code = tf.treatment_function_code;

-- ============================================================
-- STEP 4: fact_rtt_new_periods_star
-- Monthly new RTT clock starts, used as referral demand proxy
-- ============================================================

CREATE OR REPLACE TABLE fact_rtt_new_periods_star
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
FROM fact_rtt_new_periods f
LEFT JOIN dim_date d
    ON f.period_date = d.full_date
LEFT JOIN dim_trust t
    ON f.provider_org_code = t.trust_code
LEFT JOIN dim_treatment_function tf
    ON f.treatment_function_code = tf.treatment_function_code;

-- ============================================================
-- STEP 5: fact_rtt_wait_band_star
-- Unpivots 12 wait band columns into rows so dim_wait_band can
-- filter and aggregate waiting list records directly.
-- ============================================================

CREATE OR REPLACE TABLE fact_rtt_wait_band_star
USING DELTA AS
WITH unpivoted AS (
    SELECT period_date, provider_org_code, treatment_function_code, '0-5 weeks' AS band_label, band_0_5_wks AS waiting_count
    FROM fact_rtt_incomplete WHERE band_0_5_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '6-10 weeks', band_6_10_wks
    FROM fact_rtt_incomplete WHERE band_6_10_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '11-15 weeks', band_11_15_wks
    FROM fact_rtt_incomplete WHERE band_11_15_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '16-18 weeks', band_16_18_wks
    FROM fact_rtt_incomplete WHERE band_16_18_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '19-23 weeks', band_19_23_wks
    FROM fact_rtt_incomplete WHERE band_19_23_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '24-28 weeks', band_24_28_wks
    FROM fact_rtt_incomplete WHERE band_24_28_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '29-33 weeks', band_29_33_wks
    FROM fact_rtt_incomplete WHERE band_29_33_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '34-38 weeks', band_34_38_wks
    FROM fact_rtt_incomplete WHERE band_34_38_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '39-43 weeks', band_39_43_wks
    FROM fact_rtt_incomplete WHERE band_39_43_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '44-48 weeks', band_44_48_wks
    FROM fact_rtt_incomplete WHERE band_44_48_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '49-52 weeks', band_49_52_wks
    FROM fact_rtt_incomplete WHERE band_49_52_wks > 0

    UNION ALL
    SELECT period_date, provider_org_code, treatment_function_code, '52+ weeks', band_52_plus
    FROM fact_rtt_incomplete WHERE band_52_plus > 0
)

SELECT
    d.date_key,
    t.trust_key,
    t.region_key,
    tf.treatment_function_key,
    wb.wait_band_key,

    wb.band_label,
    wb.is_breach,
    wb.is_long_waiter,

    u.waiting_count,

    u.period_date,
    u.provider_org_code,
    u.treatment_function_code
FROM unpivoted u
JOIN dim_date d
    ON u.period_date = d.full_date
JOIN dim_trust t
    ON u.provider_org_code = t.trust_code
JOIN dim_treatment_function tf
    ON u.treatment_function_code = tf.treatment_function_code
JOIN dim_wait_band wb
    ON u.band_label = wb.band_label;

-- ============================================================
-- STEP 6: Data quality checks
-- Expected missing key values: 0 for all checks
-- ============================================================

SELECT
    'fact_rtt_incomplete_star' AS table_name,
    COUNT(*) AS total_rows,
    SUM(CASE WHEN date_key IS NULL THEN 1 ELSE 0 END) AS missing_date_key,
    SUM(CASE WHEN trust_key IS NULL THEN 1 ELSE 0 END) AS missing_trust_key,
    SUM(CASE WHEN region_key IS NULL THEN 1 ELSE 0 END) AS missing_region_key,
    SUM(CASE WHEN treatment_function_key IS NULL THEN 1 ELSE 0 END) AS missing_treatment_function_key,
    NULL AS missing_wait_band_key
FROM fact_rtt_incomplete_star

UNION ALL

SELECT
    'fact_rtt_completed_star',
    COUNT(*),
    SUM(CASE WHEN date_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN trust_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN region_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN treatment_function_key IS NULL THEN 1 ELSE 0 END),
    NULL
FROM fact_rtt_completed_star

UNION ALL

SELECT
    'fact_rtt_new_periods_star',
    COUNT(*),
    SUM(CASE WHEN date_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN trust_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN region_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN treatment_function_key IS NULL THEN 1 ELSE 0 END),
    NULL
FROM fact_rtt_new_periods_star

UNION ALL

SELECT
    'fact_rtt_wait_band_star',
    COUNT(*),
    SUM(CASE WHEN date_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN trust_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN region_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN treatment_function_key IS NULL THEN 1 ELSE 0 END),
    SUM(CASE WHEN wait_band_key IS NULL THEN 1 ELSE 0 END)
FROM fact_rtt_wait_band_star;

-- ============================================================
-- STEP 7: Star schema drill-down validation
-- ============================================================

SELECT
    d.financial_year,
    d.month_name,
    r.region_name,
    t.trust_name,
    tf.treatment_function_name,
    SUM(f.total_waiting) AS total_waiting
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
-- STEP 8: Wait band breach analysis
-- ============================================================

SELECT
    d.financial_year,
    r.region_name,
    tf.treatment_function_name,
    wb.band_label,
    wb.is_breach,
    wb.is_long_waiter,
    SUM(f.waiting_count) AS patients_waiting
FROM fact_rtt_wait_band_star f
JOIN dim_date d
    ON f.date_key = d.date_key
JOIN dim_region r
    ON f.region_key = r.region_key
JOIN dim_treatment_function tf
    ON f.treatment_function_key = tf.treatment_function_key
JOIN dim_wait_band wb
    ON f.wait_band_key = wb.wait_band_key
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
-- Expected after validation:
-- fact_rtt_incomplete_star      85,360
-- fact_rtt_completed_star       552,128
-- fact_rtt_new_periods_star     276,064
-- fact_rtt_wait_band_star       553,983
-- ============================================================

SELECT 'fact_rtt_incomplete_star' AS table_name, COUNT(*) AS row_count FROM fact_rtt_incomplete_star
UNION ALL
SELECT 'fact_rtt_completed_star', COUNT(*) FROM fact_rtt_completed_star
UNION ALL
SELECT 'fact_rtt_new_periods_star', COUNT(*) FROM fact_rtt_new_periods_star
UNION ALL
SELECT 'fact_rtt_wait_band_star', COUNT(*) FROM fact_rtt_wait_band_star;