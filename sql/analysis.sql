-- ============================================================
-- NHS Waiting List Analytics - Core Analytical Queries
-- Database: nhs_waiting_list_db
-- Purpose:  Answer the key question:
--           "Is the waiting list falling because patients are being
--            treated faster, or because fewer patients are being
--            referred in the first place?"
-- Author:   Teslim Uthman Adeyanju
-- Date:     April 2026
-- ============================================================

USE nhs_waiting_list_db;


-- ============================================================
-- QUERY 1: National waiting list trend (headline KPI)
-- Shows the total incomplete RTT pathway count month-by-month.
-- This is the "official" figure reported in the press.
-- ============================================================

SELECT
    d.full_date                     AS reporting_month,
    d.financial_year,
    d.is_covid_period,
    SUM(fi.patients_waiting)        AS total_on_waiting_list,

    -- 12-month rolling average to smooth monthly volatility
    ROUND(AVG(SUM(fi.patients_waiting)) OVER (
        ORDER BY d.full_date
        ROWS BETWEEN 11 PRECEDING AND CURRENT ROW
    ), 0)                           AS rolling_12m_avg,

    -- Month-on-month change
    SUM(fi.patients_waiting) - LAG(SUM(fi.patients_waiting)) OVER (
        ORDER BY d.full_date
    )                               AS mom_change,

    -- Year-on-year change
    SUM(fi.patients_waiting) - LAG(SUM(fi.patients_waiting), 12) OVER (
        ORDER BY d.full_date
    )                               AS yoy_change

FROM fact_rtt_incomplete fi
JOIN dim_date d ON d.date_key = fi.date_key
GROUP BY d.full_date, d.financial_year, d.is_covid_period
ORDER BY d.full_date;


-- ============================================================
-- QUERY 2: THE CORE INSIGHT — Referrals vs Treatments vs List Size
-- If referrals drop faster than the list shrinks, demand is being
-- suppressed, not resolved. This is the "killer query."
-- ============================================================

SELECT
    d.full_date                                                           AS reporting_month,
    d.financial_year,
    d.is_covid_period,

    -- Demand side: new clock starts (referrals accepted into RTT)
    COALESCE(SUM(fn.new_rtt_periods), 0)                                 AS new_referrals,

    -- Supply side: patients exiting the list through treatment
    COALESCE(SUM(fc.total_completed), 0)                                 AS total_treated,

    -- List size snapshot
    COALESCE(SUM(fi.patients_waiting), 0)                                AS total_waiting,

    -- Net flow: positive = list growing, negative = list shrinking
    COALESCE(SUM(fn.new_rtt_periods), 0)
        - COALESCE(SUM(fc.total_completed), 0)                           AS net_flow,

    -- Referral-to-treatment ratio: > 1 = more coming in than going out
    ROUND(
        COALESCE(SUM(fn.new_rtt_periods), 0)
        / NULLIF(COALESCE(SUM(fc.total_completed), 0), 0)
    , 3)                                                                  AS referral_to_treatment_ratio,

    -- Pre-COVID baseline index (Jan 2020 = 100)
    ROUND(
        100.0 * SUM(fn.new_rtt_periods)
        / NULLIF((
            SELECT SUM(fn2.new_rtt_periods)
            FROM fact_rtt_new_periods fn2
            WHERE fn2.date_key = 202001    -- January 2020
        ), 0)
    , 1)                                                                  AS referral_index_vs_jan2020

FROM dim_date d
LEFT JOIN fact_rtt_new_periods  fn ON fn.date_key = d.date_key
LEFT JOIN fact_rtt_completed    fc ON fc.date_key = d.date_key
LEFT JOIN fact_rtt_incomplete   fi ON fi.date_key = d.date_key
GROUP BY d.full_date, d.financial_year, d.is_covid_period
ORDER BY d.full_date;


-- ============================================================
-- QUERY 3: Long waiter trend (52+ weeks) — political pressure metric
-- NHSE targets have focused on eliminating 52+ week waits.
-- Did they actually treat long waiters, or just remove them?
-- ============================================================

SELECT
    d.full_date                                                          AS reporting_month,
    d.financial_year,

    SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END) AS waiting_52_plus_weeks,
    SUM(CASE WHEN wb.is_breach      = 1 THEN fi.patients_waiting ELSE 0 END) AS waiting_over_18_weeks,
    SUM(fi.patients_waiting)                                             AS total_waiting,

    -- 52-week breach rate (% of all waiters who are long waiters)
    ROUND(
        100.0 * SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END)
        / NULLIF(SUM(fi.patients_waiting), 0)
    , 2)                                                                  AS long_waiter_pct,

    -- 18-week breach rate
    ROUND(
        100.0 * SUM(CASE WHEN wb.is_breach = 1 THEN fi.patients_waiting ELSE 0 END)
        / NULLIF(SUM(fi.patients_waiting), 0)
    , 2)                                                                  AS breach_rate_pct,

    -- MoM change in 52-week waiters
    SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END)
    - LAG(SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END)) OVER (
        ORDER BY d.full_date
    )                                                                     AS long_waiters_mom_change

FROM fact_rtt_incomplete fi
JOIN dim_date     d  ON d.date_key     = fi.date_key
JOIN dim_wait_band wb ON wb.wait_band_key = fi.wait_band_key
GROUP BY d.full_date, d.financial_year
ORDER BY d.full_date;


-- ============================================================
-- QUERY 4: Specialty-level pressure (which areas are worst?)
-- Identifies specialties where demand consistently outstrips supply
-- ============================================================

SELECT
    d.financial_year,
    tf.treatment_function_name,
    tf.specialty_group,

    SUM(fi.patients_waiting)                                             AS avg_monthly_waiting,
    SUM(fn.new_rtt_periods)                                             AS total_new_referrals,
    SUM(fc.total_completed)                                             AS total_treated,

    -- Unmet demand gap: referrals not converted to treatments
    SUM(fn.new_rtt_periods) - SUM(fc.total_completed)                  AS cumulative_demand_gap,

    -- Throughput ratio: treatments as % of referrals
    ROUND(
        100.0 * SUM(fc.total_completed)
        / NULLIF(SUM(fn.new_rtt_periods), 0)
    , 1)                                                                  AS throughput_pct,

    -- Average median wait
    ROUND(AVG(fc.median_wait_weeks), 1)                                  AS avg_median_wait_weeks,

    -- Long waiter concentration
    ROUND(
        100.0 * SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END)
        / NULLIF(SUM(fi.patients_waiting), 0)
    , 2)                                                                  AS long_waiter_pct

FROM dim_treatment_function tf
LEFT JOIN fact_rtt_incomplete fi   ON fi.treatment_function_key = tf.treatment_function_key
LEFT JOIN fact_rtt_new_periods fn  ON fn.treatment_function_key = tf.treatment_function_key
                                  AND fn.date_key = fi.date_key
                                  AND fn.trust_key = fi.trust_key
LEFT JOIN fact_rtt_completed   fc  ON fc.treatment_function_key = tf.treatment_function_key
                                  AND fc.date_key = fi.date_key
                                  AND fc.trust_key = fi.trust_key
LEFT JOIN dim_wait_band        wb  ON wb.wait_band_key = fi.wait_band_key
LEFT JOIN dim_date             d   ON d.date_key = fi.date_key

GROUP BY d.financial_year, tf.treatment_function_name, tf.specialty_group
HAVING avg_monthly_waiting > 0
ORDER BY d.financial_year, cumulative_demand_gap DESC;


-- ============================================================
-- QUERY 5: Regional performance benchmarking
-- Identifies which NHS England regions are outliers in
-- referral suppression vs treatment delivery
-- ============================================================

SELECT
    d.full_date,
    d.financial_year,
    r.region_name,

    SUM(fi.patients_waiting)                                            AS total_waiting,
    SUM(fn.new_rtt_periods)                                             AS new_referrals,
    SUM(fc.total_completed)                                             AS total_treated,

    -- Regional referral index vs national average
    ROUND(
        SUM(fn.new_rtt_periods) /
        NULLIF(AVG(SUM(fn.new_rtt_periods)) OVER (PARTITION BY d.full_date), 0)
    , 2)                                                                  AS referral_index_vs_national,

    -- Regional breach rate
    ROUND(
        100.0 * SUM(CASE WHEN wb.is_breach = 1 THEN fi.patients_waiting ELSE 0 END)
        / NULLIF(SUM(fi.patients_waiting), 0)
    , 2)                                                                  AS breach_rate_pct,

    -- Long waiter % for region
    ROUND(
        100.0 * SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END)
        / NULLIF(SUM(fi.patients_waiting), 0)
    , 2)                                                                  AS long_waiter_pct

FROM fact_rtt_incomplete fi
JOIN dim_date    d  ON d.date_key    = fi.date_key
JOIN dim_trust   t  ON t.trust_key   = fi.trust_key
JOIN dim_region  r  ON r.region_key  = t.region_key
JOIN dim_wait_band wb ON wb.wait_band_key = fi.wait_band_key

LEFT JOIN fact_rtt_new_periods fn
       ON fn.date_key = fi.date_key AND fn.trust_key = fi.trust_key
      AND fn.treatment_function_key = fi.treatment_function_key

LEFT JOIN fact_rtt_completed fc
       ON fc.date_key = fi.date_key AND fc.trust_key = fi.trust_key
      AND fc.treatment_function_key = fi.treatment_function_key

GROUP BY d.full_date, d.financial_year, r.region_name
ORDER BY d.full_date, r.region_name;


-- ============================================================
-- QUERY 6: Trust-level performance scorecard
-- A league table of trusts: ranked by breach rate, referral
-- suppression signal, and throughput efficiency
-- ============================================================

SELECT
    t.trust_code,
    t.trust_name,
    r.region_name,
    d.financial_year,

    SUM(fi.patients_waiting)                                            AS avg_waiting,
    ROUND(AVG(fc.median_wait_weeks), 1)                                 AS avg_median_wait_wks,

    -- Breach rate
    ROUND(
        100.0 * SUM(CASE WHEN wb.is_breach = 1 THEN fi.patients_waiting ELSE 0 END)
        / NULLIF(SUM(fi.patients_waiting), 0)
    , 1)                                                                  AS breach_rate_pct,

    -- Throughput rate
    ROUND(
        100.0 * SUM(fc.total_completed)
        / NULLIF(SUM(fn.new_rtt_periods), 0)
    , 1)                                                                  AS throughput_pct,

    -- Referral suppression signal:
    -- large negative = trust completing far more than new referrals →
    -- possible referral gatekeeping or working down backlog
    SUM(fn.new_rtt_periods) - SUM(fc.total_completed)                  AS referral_vs_treatment_gap,

    -- Rank by breach rate within region/year
    RANK() OVER (
        PARTITION BY r.region_name, d.financial_year
        ORDER BY
            100.0 * SUM(CASE WHEN wb.is_breach = 1 THEN fi.patients_waiting ELSE 0 END)
            / NULLIF(SUM(fi.patients_waiting), 0) DESC
    )                                                                     AS breach_rank_in_region

FROM fact_rtt_incomplete fi
JOIN dim_trust   t  ON t.trust_key   = fi.trust_key
JOIN dim_region  r  ON r.region_key  = t.region_key
JOIN dim_date    d  ON d.date_key    = fi.date_key
JOIN dim_wait_band wb ON wb.wait_band_key = fi.wait_band_key

LEFT JOIN fact_rtt_new_periods fn
       ON fn.date_key = fi.date_key AND fn.trust_key = fi.trust_key
      AND fn.treatment_function_key = fi.treatment_function_key

LEFT JOIN fact_rtt_completed fc
       ON fc.date_key = fi.date_key AND fc.trust_key = fi.trust_key
      AND fc.treatment_function_key = fi.treatment_function_key

GROUP BY t.trust_code, t.trust_name, r.region_name, d.financial_year
HAVING avg_waiting > 0
ORDER BY d.financial_year, breach_rate_pct DESC;


-- ============================================================
-- QUERY 7: Pre/Post COVID recovery trajectory
-- Has each region recovered referral and treatment volumes
-- to pre-pandemic (2019/20) baseline?
-- ============================================================

WITH baseline AS (
    -- FY 2019/20 averages as the 100-point index
    SELECT
        t.region_key,
        AVG(fn.new_rtt_periods)  AS baseline_referrals,
        AVG(fc.total_completed)  AS baseline_treatments,
        AVG(fi.patients_waiting) AS baseline_waiting
    FROM fact_rtt_new_periods fn
    JOIN dim_date d ON d.date_key = fn.date_key
    JOIN dim_trust t ON t.trust_key = fn.trust_key
    LEFT JOIN fact_rtt_completed fc
           ON fc.date_key = fn.date_key AND fc.trust_key = fn.trust_key
    LEFT JOIN fact_rtt_incomplete fi
           ON fi.date_key = fn.date_key AND fi.trust_key = fn.trust_key
    WHERE d.financial_year = '2019/20'
    GROUP BY t.region_key
)
SELECT
    d.full_date,
    d.financial_year,
    r.region_name,

    -- Recovery index: 100 = pre-COVID level, < 100 = below baseline
    ROUND(100.0 * SUM(fn.new_rtt_periods) / NULLIF(b.baseline_referrals, 0),  1) AS referral_recovery_index,
    ROUND(100.0 * SUM(fc.total_completed) / NULLIF(b.baseline_treatments, 0), 1) AS treatment_recovery_index,
    ROUND(100.0 * SUM(fi.patients_waiting) / NULLIF(b.baseline_waiting, 0),   1) AS waiting_list_index

FROM dim_date d
JOIN dim_trust t ON 1=1                   -- cross join to get all trusts
JOIN dim_region r ON r.region_key = t.region_key
JOIN baseline b ON b.region_key = t.region_key

LEFT JOIN fact_rtt_new_periods  fn ON fn.date_key = d.date_key AND fn.trust_key = t.trust_key
LEFT JOIN fact_rtt_completed    fc ON fc.date_key = d.date_key AND fc.trust_key = t.trust_key
LEFT JOIN fact_rtt_incomplete   fi ON fi.date_key = d.date_key AND fi.trust_key = t.trust_key

WHERE d.full_date >= '2019-04-01'
GROUP BY d.full_date, d.financial_year, r.region_name, b.baseline_referrals, b.baseline_treatments, b.baseline_waiting
ORDER BY d.full_date, r.region_name;
