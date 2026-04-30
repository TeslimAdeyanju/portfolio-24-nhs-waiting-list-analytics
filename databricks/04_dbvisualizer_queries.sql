-- ============================================================
-- NHS Waiting List Analytics — DbVisualizer Query Suite
-- Database:  nhs_waiting_list (Databricks SQL Warehouse)
-- Purpose:   7 analytical queries answering the core question:
--            "Is the waiting list falling because patients are
--             being treated faster, or because fewer are being
--             referred in the first place?"
-- Run in:    DbVisualizer connected to Databricks via JDBC
-- Author:    Teslim Uthman Adeyanju
-- Date:      April 2026
-- ============================================================


-- ============================================================
-- Connection checks (run first to confirm DbVisualizer is working)
-- ============================================================

SHOW SCHEMAS;

USE nhs_waiting_list;

SHOW TABLES;

SHOW VIEWS IN nhs_waiting_list;


-- ============================================================
-- QUERY 1: National waiting list trend
-- The headline "official" figure reported monthly.
-- ============================================================

SELECT
    period_date,
    total_waiting,
    total_completed,
    new_rtt_periods,
    breach_rate_pct,

    -- Month-on-month change in waiting list
    total_waiting - LAG(total_waiting) OVER (ORDER BY period_date) AS mom_change,

    -- Year-on-year change
    total_waiting - LAG(total_waiting, 12) OVER (ORDER BY period_date) AS yoy_change,

    -- 12-month rolling average (smooths monthly volatility)
    ROUND(AVG(total_waiting) OVER (
        ORDER BY period_date
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
    ), 0) AS rolling_12m_avg

FROM nhs_waiting_list.v_national_monthly
ORDER BY period_date;


-- ============================================================
-- QUERY 2: THE CORE INSIGHT — Referrals vs Treatments vs List Size
-- KEY: if referral_to_treatment_ratio drops AND list shrinks,
-- demand is being suppressed — not resolved.
-- ============================================================

SELECT
    period_date,
    new_rtt_periods                                                    AS new_referrals,
    total_completed                                                    AS total_treated,
    total_waiting,
    net_list_change,
    treatment_per_referral_ratio,

    -- Pre-COVID baseline index (Jan 2020 = 100)
    ROUND(
        100.0 * new_rtt_periods /
        NULLIF(FIRST_VALUE(new_rtt_periods) OVER (
            ORDER BY period_date
            ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
        ), 0)
    , 1) AS referral_index_vs_start

FROM nhs_waiting_list.v_national_monthly
ORDER BY period_date;


-- ============================================================
-- QUERY 3: Long waiter (52+ weeks) trend
-- NHSE targeted elimination of 52-week waits as a policy goal.
-- Did they treat long waiters — or just remove them from the list?
-- ============================================================

SELECT
    period_date,
    total_waiting,
    waiting_over_18wks,
    waiting_over_52wks,

    -- Long waiter concentration
    ROUND(100.0 * waiting_over_52wks / NULLIF(total_waiting, 0), 2)   AS long_waiter_pct,

    -- 18-week breach rate
    breach_rate_pct,

    -- MoM change in 52-week waiters
    waiting_over_52wks - LAG(waiting_over_52wks) OVER (ORDER BY period_date) AS long_waiters_mom_change

FROM nhs_waiting_list.v_national_monthly
ORDER BY period_date;


-- ============================================================
-- QUERY 4: Specialty pressure — which areas are worst?
-- Identifies specialties where demand consistently outstrips supply.
-- ============================================================

SELECT
    treatment_function_name,

    SUM(total_waiting)                                                 AS total_waiting,
    SUM(new_rtt_periods)                                               AS total_referrals,
    SUM(total_completed)                                               AS total_treated,

    -- Unmet demand gap: referrals not converted to treatments
    SUM(new_rtt_periods) - SUM(total_completed)                        AS cumulative_demand_gap,

    -- Throughput ratio: treatments as % of referrals
    ROUND(100.0 * SUM(total_completed) / NULLIF(SUM(new_rtt_periods), 0), 1) AS throughput_pct,

    -- Long waiter concentration
    ROUND(100.0 * SUM(waiting_over_52wks) / NULLIF(SUM(total_waiting), 0), 2) AS long_waiter_pct

FROM nhs_waiting_list.v_monthly_summary
GROUP BY treatment_function_name
HAVING SUM(total_waiting) > 0
ORDER BY cumulative_demand_gap DESC;


-- ============================================================
-- QUERY 5: Regional performance benchmarking
-- Which NHS England regions are outliers in referral vs treatment?
-- ============================================================

SELECT
    period_date,
    region_code,

    SUM(total_waiting)                                                 AS total_waiting,
    SUM(new_rtt_periods)                                               AS new_referrals,
    SUM(total_completed)                                               AS total_treated,

    -- Regional referral index vs national average for the same month
    ROUND(
        SUM(new_rtt_periods) /
        NULLIF(AVG(SUM(new_rtt_periods)) OVER (PARTITION BY period_date), 0)
    , 2)                                                               AS referral_index_vs_national,

    ROUND(100.0 * SUM(waiting_over_18wks) / NULLIF(SUM(total_waiting), 0), 2) AS breach_rate_pct,
    ROUND(100.0 * SUM(waiting_over_52wks) / NULLIF(SUM(total_waiting), 0), 2) AS long_waiter_pct

FROM nhs_waiting_list.v_monthly_summary
GROUP BY period_date, region_code
ORDER BY period_date, region_code;


-- ============================================================
-- QUERY 6: Trust performance scorecard (league table)
-- Ranked by breach rate — the standard NHS accountability metric.
-- ============================================================

SELECT
    provider_org_code,
    provider_org_name,
    region_code,

    SUM(total_waiting)                                                 AS total_waiting,
    ROUND(AVG(avg_median_wait_weeks), 1)                               AS avg_median_wait_wks,

    ROUND(100.0 * SUM(waiting_over_18wks) / NULLIF(SUM(total_waiting), 0), 1) AS breach_rate_pct,
    ROUND(100.0 * SUM(total_completed) / NULLIF(SUM(new_rtt_periods), 0), 1)  AS throughput_pct,

    -- Referral suppression signal:
    -- large negative = treating far more than referred → possible gatekeeping
    SUM(new_rtt_periods) - SUM(total_completed)                        AS referral_vs_treatment_gap,

    -- Rank by breach rate within region
    RANK() OVER (
        PARTITION BY region_code
        ORDER BY
            100.0 * SUM(waiting_over_18wks) / NULLIF(SUM(total_waiting), 0) DESC
    ) AS breach_rank_in_region

FROM nhs_waiting_list.v_monthly_summary
GROUP BY provider_org_code, provider_org_name, region_code
HAVING SUM(total_waiting) > 0
ORDER BY breach_rate_pct DESC;


-- ============================================================
-- QUERY 7: Pre/Post COVID recovery trajectory
-- Has referral and treatment volume returned to the 2019/20 baseline?
-- ============================================================

WITH baseline AS (
    -- Average monthly volumes from the pre-pandemic financial year
    SELECT
        AVG(new_rtt_periods)  AS baseline_referrals,
        AVG(total_completed)  AS baseline_treatments,
        AVG(total_waiting)    AS baseline_waiting
    FROM nhs_waiting_list.v_national_monthly
    WHERE period_date BETWEEN '2019-04-01' AND '2020-03-01'
)
SELECT
    m.period_date,
    m.total_waiting,
    m.new_rtt_periods,
    m.total_completed,

    -- Recovery index: 100 = pre-COVID FY2019/20 level
    ROUND(100.0 * m.new_rtt_periods  / NULLIF(b.baseline_referrals,  0), 1) AS referral_recovery_index,
    ROUND(100.0 * m.total_completed  / NULLIF(b.baseline_treatments, 0), 1) AS treatment_recovery_index,
    ROUND(100.0 * m.total_waiting    / NULLIF(b.baseline_waiting,    0), 1) AS waiting_list_index

FROM nhs_waiting_list.v_national_monthly m
CROSS JOIN baseline b
WHERE m.period_date >= '2019-04-01'
ORDER BY m.period_date;
