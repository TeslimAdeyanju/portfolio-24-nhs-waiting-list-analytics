-- ============================================================
-- NHS Waiting List Analytics — Databricks Gold Views
-- Database:  nhs_waiting_list
-- Purpose:   Analytical mart views used by Power BI and DbVisualizer.
--            Mirrors the MySQL v_monthly_summary and v_national_monthly
--            views but works directly against the flat Delta tables.
-- Run in:    Databricks SQL Editor (after 02_create_delta_tables.sql)
-- Author:    Teslim Uthman Adeyanju
-- Date:      April 2026
-- ============================================================

USE nhs_waiting_list;


-- ============================================================
-- VIEW 1: v_monthly_summary
-- Trust / specialty / month grain.
-- Joins all three fact tables on period_date + org code + tf code.
-- Used for trust-level analysis, regional benchmarking, and
-- specialty-level comparisons in Power BI.
-- ============================================================

CREATE OR REPLACE VIEW nhs_waiting_list.v_monthly_summary AS
SELECT
    i.period_date,
    i.region_code,
    i.provider_org_code,
    i.provider_org_name,
    i.treatment_function_code,
    i.treatment_function_name,

    -- Waiting list snapshot
    COALESCE(SUM(i.total_waiting), 0)                                        AS total_waiting,

    -- Patients breaching the 18-week standard (bands 19 weeks and above)
    COALESCE(SUM(
        i.band_19_23_wks + i.band_24_28_wks + i.band_29_33_wks +
        i.band_34_38_wks + i.band_39_43_wks + i.band_44_48_wks +
        i.band_49_52_wks + i.band_52_plus
    ), 0)                                                                     AS waiting_over_18wks,

    -- Long waiters: patients waiting 52+ weeks (key NHSE political metric)
    COALESCE(SUM(i.band_52_plus), 0)                                         AS waiting_over_52wks,

    AVG(i.median_wait_weeks)                                                 AS avg_median_wait_weeks,
    AVG(i.percentile_92_wait_weeks)                                          AS avg_p92_wait_weeks,

    -- Treatments (admitted vs non-admitted from fact_rtt_completed)
    COALESCE(SUM(CASE WHEN c.pathway_type = 'Admitted'     THEN c.total_completed ELSE 0 END), 0) AS completed_admitted,
    COALESCE(SUM(CASE WHEN c.pathway_type = 'Non-Admitted' THEN c.total_completed ELSE 0 END), 0) AS completed_non_admitted,
    COALESCE(SUM(c.total_completed), 0)                                      AS total_completed,

    -- Referral demand (new RTT clock starts)
    COALESCE(SUM(n.new_rtt_periods), 0)                                      AS new_rtt_periods

FROM nhs_waiting_list.fact_rtt_incomplete i

LEFT JOIN nhs_waiting_list.fact_rtt_completed c
       ON c.period_date             = i.period_date
      AND c.provider_org_code       = i.provider_org_code
      AND c.treatment_function_code = i.treatment_function_code

LEFT JOIN nhs_waiting_list.fact_rtt_new_periods n
       ON n.period_date             = i.period_date
      AND n.provider_org_code       = i.provider_org_code
      AND n.treatment_function_code = i.treatment_function_code

GROUP BY
    i.period_date,
    i.region_code,
    i.provider_org_code,
    i.provider_org_name,
    i.treatment_function_code,
    i.treatment_function_name;


-- ============================================================
-- VIEW 2: v_national_monthly
-- England-level aggregate — one row per month.
-- Used for headline trend charts and the referral suppression
-- analysis (the core analytical question in this project).
--
-- Key derived columns:
--   net_list_change              — positive = list growing
--   treatment_per_referral_ratio — < 1.0 means more people
--                                  referred than treated;
--                                  falling ratio + shrinking list
--                                  signals referral suppression
-- ============================================================

CREATE OR REPLACE VIEW nhs_waiting_list.v_national_monthly AS
SELECT
    period_date,

    SUM(total_waiting)                                                        AS total_waiting,
    SUM(waiting_over_18wks)                                                   AS waiting_over_18wks,
    SUM(waiting_over_52wks)                                                   AS waiting_over_52wks,
    SUM(total_completed)                                                      AS total_completed,
    SUM(new_rtt_periods)                                                      AS new_rtt_periods,

    -- Net flow: referrals in minus treatments out
    SUM(new_rtt_periods) - SUM(total_completed)                               AS net_list_change,

    -- Referral efficiency: treatments per new referral
    ROUND(
        SUM(total_completed) / NULLIF(SUM(new_rtt_periods), 0),
    3)                                                                        AS treatment_per_referral_ratio,

    -- 18-week breach rate
    ROUND(
        100.0 * SUM(waiting_over_18wks) / NULLIF(SUM(total_waiting), 0),
    2)                                                                        AS breach_rate_pct

FROM nhs_waiting_list.v_monthly_summary
GROUP BY period_date
ORDER BY period_date;


-- ============================================================
-- Verify
-- ============================================================

SELECT * FROM nhs_waiting_list.v_national_monthly
ORDER BY period_date
LIMIT 20;
