-- ============================================================
-- NHS Waiting List Analytics - ETL Transformations
-- Database: nhs_waiting_list_db
-- Purpose:  Populate dim_date, load staging data into fact tables,
--           and build derived mart views for Power BI
-- Author:   Teslim Uthman Adeyanju
-- Date:     April 2026
-- ============================================================

USE nhs_waiting_list_db;

-- ============================================================
-- STEP 1: Populate dim_date (Jan 2015 → Dec 2025)
-- Run once. RTT data is published monthly so one row per month.
-- ============================================================

DROP PROCEDURE IF EXISTS sp_populate_dim_date;

DELIMITER $$

CREATE PROCEDURE sp_populate_dim_date(
    IN p_start_date DATE,   -- e.g. '2015-01-01'
    IN p_end_date   DATE    -- e.g. '2025-12-01'
)
BEGIN
    DECLARE v_date DATE DEFAULT p_start_date;

    WHILE v_date <= p_end_date DO
        INSERT IGNORE INTO dim_date (
            date_key,
            full_date,
            year,
            quarter,
            month,
            month_name,
            financial_year,
            financial_quarter,
            is_covid_period
        )
        VALUES (
            DATE_FORMAT(v_date, '%Y%m'),                                         -- date_key: YYYYMM
            v_date,
            YEAR(v_date),
            QUARTER(v_date),
            MONTH(v_date),
            DATE_FORMAT(v_date, '%M'),
            -- Financial year: Apr of year → Mar of year+1
            CASE
                WHEN MONTH(v_date) >= 4
                THEN CONCAT(YEAR(v_date),     '/', RIGHT(YEAR(v_date) + 1, 2))
                ELSE CONCAT(YEAR(v_date) - 1, '/', RIGHT(YEAR(v_date),     2))
            END,
            -- Financial quarter (Q1=Apr-Jun, Q2=Jul-Sep, Q3=Oct-Dec, Q4=Jan-Mar)
            CASE
                WHEN MONTH(v_date) IN (4, 5, 6)   THEN CONCAT('Q1 ', DATE_FORMAT(v_date, '%y'), RIGHT(YEAR(v_date) + 1, 2))
                WHEN MONTH(v_date) IN (7, 8, 9)   THEN CONCAT('Q2 ', DATE_FORMAT(v_date, '%y'), RIGHT(YEAR(v_date) + 1, 2))
                WHEN MONTH(v_date) IN (10, 11, 12) THEN CONCAT('Q3 ', DATE_FORMAT(v_date, '%y'), RIGHT(YEAR(v_date) + 1, 2))
                ELSE                                    CONCAT('Q4 ', DATE_FORMAT(v_date - INTERVAL 1 YEAR, '%y'), RIGHT(YEAR(v_date), 2))
            END,
            -- COVID period: March 2020 – March 2022
            CASE
                WHEN v_date BETWEEN '2020-03-01' AND '2022-03-01' THEN 1
                ELSE 0
            END
        );

        SET v_date = v_date + INTERVAL 1 MONTH;
    END WHILE;
END$$

DELIMITER ;

-- Execute: populate 10 years of monthly records
CALL sp_populate_dim_date('2015-01-01', '2025-12-01');


-- ============================================================
-- STEP 2: Staging tables (temporary landing zone for raw CSV loads)
-- Python ETL writes CSVs; MySQL LOAD DATA INFILE lands them here
-- ============================================================

CREATE TABLE IF NOT EXISTS stg_rtt_incomplete (
    period_date         VARCHAR(20),   -- raw date string from NHSE file
    provider_org_code   VARCHAR(10),
    provider_org_name   VARCHAR(200),
    treatment_function_code VARCHAR(10),
    treatment_function_name VARCHAR(200),
    -- Band columns (raw from NHSE pivot-style file)
    band_0_to_1_weeks   INT DEFAULT 0,
    band_gt1_to_2       INT DEFAULT 0,
    band_gt2_to_3       INT DEFAULT 0,
    band_gt3_to_4       INT DEFAULT 0,
    band_gt4_to_5       INT DEFAULT 0,
    band_gt5_to_6       INT DEFAULT 0,
    band_gt6_to_7       INT DEFAULT 0,
    band_gt7_to_8       INT DEFAULT 0,
    band_gt8_to_9       INT DEFAULT 0,
    band_gt9_to_10      INT DEFAULT 0,
    band_gt10_to_11     INT DEFAULT 0,
    band_gt11_to_12     INT DEFAULT 0,
    band_gt12_to_13     INT DEFAULT 0,
    band_gt13_to_14     INT DEFAULT 0,
    band_gt14_to_15     INT DEFAULT 0,
    band_gt15_to_16     INT DEFAULT 0,
    band_gt16_to_17     INT DEFAULT 0,
    band_gt17_to_18     INT DEFAULT 0,
    band_gt18_to_19     INT DEFAULT 0,
    band_gt19_to_20     INT DEFAULT 0,
    band_gt20_to_21     INT DEFAULT 0,
    band_gt21_to_22     INT DEFAULT 0,
    band_gt22_to_23     INT DEFAULT 0,
    band_gt23_to_24     INT DEFAULT 0,
    band_gt24_to_25     INT DEFAULT 0,
    band_gt25_to_26     INT DEFAULT 0,
    band_gt26_to_27     INT DEFAULT 0,
    band_gt27_to_28     INT DEFAULT 0,
    band_gt28_to_29     INT DEFAULT 0,
    band_gt29_to_30     INT DEFAULT 0,
    band_gt30_to_31     INT DEFAULT 0,
    band_gt31_to_32     INT DEFAULT 0,
    band_gt32_to_33     INT DEFAULT 0,
    band_gt33_to_34     INT DEFAULT 0,
    band_gt34_to_35     INT DEFAULT 0,
    band_gt35_to_36     INT DEFAULT 0,
    band_gt36_to_37     INT DEFAULT 0,
    band_gt37_to_38     INT DEFAULT 0,
    band_gt38_to_39     INT DEFAULT 0,
    band_gt39_to_40     INT DEFAULT 0,
    band_gt40_to_41     INT DEFAULT 0,
    band_gt41_to_42     INT DEFAULT 0,
    band_gt42_to_43     INT DEFAULT 0,
    band_gt43_to_44     INT DEFAULT 0,
    band_gt44_to_45     INT DEFAULT 0,
    band_gt45_to_46     INT DEFAULT 0,
    band_gt46_to_47     INT DEFAULT 0,
    band_gt47_to_48     INT DEFAULT 0,
    band_gt48_to_49     INT DEFAULT 0,
    band_gt49_to_50     INT DEFAULT 0,
    band_gt50_to_51     INT DEFAULT 0,
    band_gt51_to_52     INT DEFAULT 0,
    band_gt52_plus      INT DEFAULT 0,
    total_waiting       INT DEFAULT 0,
    load_batch_id       VARCHAR(50)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Staging: raw incomplete RTT from NHSE CSV (pre-transformation)';


CREATE TABLE IF NOT EXISTS stg_rtt_completed (
    period_date                 VARCHAR(20),
    provider_org_code           VARCHAR(10),
    provider_org_name           VARCHAR(200),
    treatment_function_code     VARCHAR(10),
    treatment_function_name     VARCHAR(200),
    pathway_type                VARCHAR(20)  COMMENT 'Admitted | Non-Admitted',
    total_completed             INT DEFAULT 0,
    within_18_weeks             INT DEFAULT 0,
    beyond_18_weeks             INT DEFAULT 0,
    median_wait_weeks           DECIMAL(6,2),
    percentile_92_wait_weeks    DECIMAL(6,2),
    load_batch_id               VARCHAR(50)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Staging: raw completed RTT pathways from NHSE CSV';


CREATE TABLE IF NOT EXISTS stg_rtt_new_periods (
    period_date                 VARCHAR(20),
    provider_org_code           VARCHAR(10),
    provider_org_name           VARCHAR(200),
    treatment_function_code     VARCHAR(10),
    treatment_function_name     VARCHAR(200),
    new_rtt_periods             INT DEFAULT 0,
    load_batch_id               VARCHAR(50)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Staging: new RTT clock starts (referrals) from NHSE CSV';


-- ============================================================
-- STEP 3: Transform & Load - Staging → Fact tables
-- ============================================================

DROP PROCEDURE IF EXISTS sp_load_fact_incomplete;

DELIMITER $$

CREATE PROCEDURE sp_load_fact_incomplete(IN p_batch_id VARCHAR(50))
BEGIN
    -- Map raw staging bands to our 12-band dimension
    -- and resolve org code → trust_key / tf code → treatment_function_key

    INSERT INTO fact_rtt_incomplete (
        date_key,
        trust_key,
        treatment_function_key,
        wait_band_key,
        patients_waiting
    )
    SELECT
        DATE_FORMAT(STR_TO_DATE(s.period_date, '%B %Y'), '%Y%m') AS date_key,
        t.trust_key,
        tf.treatment_function_key,
        wb.wait_band_key,
        band_patients
    FROM (
        -- Unpivot: consolidate 52 weekly bands → 12 reporting bands
        SELECT
            period_date, provider_org_code, treatment_function_code,
            '0-5 weeks'   AS band_label,
            (band_0_to_1_weeks + band_gt1_to_2 + band_gt2_to_3 + band_gt3_to_4 + band_gt4_to_5) AS band_patients
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '6-10 weeks',
            (band_gt5_to_6 + band_gt6_to_7 + band_gt7_to_8 + band_gt8_to_9 + band_gt9_to_10)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '11-15 weeks',
            (band_gt10_to_11 + band_gt11_to_12 + band_gt12_to_13 + band_gt13_to_14 + band_gt14_to_15)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '16-18 weeks',
            (band_gt15_to_16 + band_gt16_to_17 + band_gt17_to_18)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '19-23 weeks',
            (band_gt18_to_19 + band_gt19_to_20 + band_gt20_to_21 + band_gt21_to_22 + band_gt22_to_23)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '24-28 weeks',
            (band_gt23_to_24 + band_gt24_to_25 + band_gt25_to_26 + band_gt26_to_27 + band_gt27_to_28)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '29-33 weeks',
            (band_gt28_to_29 + band_gt29_to_30 + band_gt30_to_31 + band_gt31_to_32 + band_gt32_to_33)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '34-38 weeks',
            (band_gt33_to_34 + band_gt34_to_35 + band_gt35_to_36 + band_gt36_to_37 + band_gt37_to_38)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '39-43 weeks',
            (band_gt38_to_39 + band_gt39_to_40 + band_gt40_to_41 + band_gt41_to_42 + band_gt42_to_43)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '44-48 weeks',
            (band_gt43_to_44 + band_gt44_to_45 + band_gt45_to_46 + band_gt46_to_47 + band_gt47_to_48)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '49-52 weeks',
            (band_gt48_to_49 + band_gt49_to_50 + band_gt50_to_51 + band_gt51_to_52)
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
        UNION ALL
        SELECT period_date, provider_org_code, treatment_function_code, '52+ weeks',
            band_gt52_plus
        FROM stg_rtt_incomplete WHERE load_batch_id = p_batch_id
    ) unpivoted
    JOIN dim_trust         t  ON t.trust_code              = unpivoted.provider_org_code
    JOIN dim_treatment_function tf ON tf.treatment_function_code = unpivoted.treatment_function_code
    JOIN dim_wait_band     wb ON wb.band_label              = unpivoted.band_label
    WHERE band_patients > 0;   -- skip empty cells

END$$

DELIMITER ;


DROP PROCEDURE IF EXISTS sp_load_fact_completed;

DELIMITER $$

CREATE PROCEDURE sp_load_fact_completed(IN p_batch_id VARCHAR(50))
BEGIN
    INSERT INTO fact_rtt_completed (
        date_key,
        trust_key,
        treatment_function_key,
        wait_band_key,
        completed_admitted,
        completed_non_admitted,
        median_wait_weeks,
        percentile_92_wait_weeks
    )
    SELECT
        DATE_FORMAT(STR_TO_DATE(s.period_date, '%B %Y'), '%Y%m'),
        t.trust_key,
        tf.treatment_function_key,
        1 AS wait_band_key,   -- completed facts don't break by band; default to first band
        CASE WHEN s.pathway_type = 'Admitted'     THEN s.total_completed ELSE 0 END,
        CASE WHEN s.pathway_type = 'Non-Admitted' THEN s.total_completed ELSE 0 END,
        s.median_wait_weeks,
        s.percentile_92_wait_weeks
    FROM stg_rtt_completed s
    JOIN dim_trust              t  ON t.trust_code              = s.provider_org_code
    JOIN dim_treatment_function tf ON tf.treatment_function_code = s.treatment_function_code
    WHERE s.load_batch_id = p_batch_id;
END$$

DELIMITER ;


DROP PROCEDURE IF EXISTS sp_load_fact_new_periods;

DELIMITER $$

CREATE PROCEDURE sp_load_fact_new_periods(IN p_batch_id VARCHAR(50))
BEGIN
    INSERT INTO fact_rtt_new_periods (
        date_key,
        trust_key,
        treatment_function_key,
        new_rtt_periods
    )
    SELECT
        DATE_FORMAT(STR_TO_DATE(s.period_date, '%B %Y'), '%Y%m'),
        t.trust_key,
        tf.treatment_function_key,
        s.new_rtt_periods
    FROM stg_rtt_new_periods s
    JOIN dim_trust              t  ON t.trust_code              = s.provider_org_code
    JOIN dim_treatment_function tf ON tf.treatment_function_code = s.treatment_function_code
    WHERE s.load_batch_id = p_batch_id
      AND s.new_rtt_periods > 0;
END$$

DELIMITER ;


-- ============================================================
-- STEP 4: Mart views (used directly by Power BI via DirectQuery or import)
-- ============================================================

-- v_monthly_summary: Core KPI view aggregated at Trust/Month level
CREATE OR REPLACE VIEW v_monthly_summary AS
SELECT
    d.full_date,
    d.year,
    d.financial_year,
    d.financial_quarter,
    d.month_name,
    d.is_covid_period,
    r.region_name,
    t.trust_code,
    t.trust_name,
    t.trust_type,
    tf.treatment_function_name,
    tf.specialty_group,

    -- Waiting list snapshot
    COALESCE(SUM(fi.patients_waiting),     0) AS total_waiting,
    COALESCE(SUM(CASE WHEN wb.is_breach      = 1 THEN fi.patients_waiting ELSE 0 END), 0) AS waiting_over_18wks,
    COALESCE(SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END), 0) AS waiting_over_52wks,

    -- Treatments
    COALESCE(SUM(fc.completed_admitted),       0) AS completed_admitted,
    COALESCE(SUM(fc.completed_non_admitted),   0) AS completed_non_admitted,
    COALESCE(SUM(fc.total_completed),          0) AS total_completed,
    COALESCE(AVG(fc.median_wait_weeks),     NULL) AS avg_median_wait_weeks,
    COALESCE(AVG(fc.percentile_92_wait_weeks), NULL) AS avg_p92_wait_weeks,

    -- Referral demand (new clock starts)
    COALESCE(SUM(fn.new_rtt_periods),          0) AS new_rtt_periods

FROM dim_date d
CROSS JOIN dim_trust t
JOIN dim_region r             ON r.region_key             = t.region_key
CROSS JOIN dim_treatment_function tf

LEFT JOIN fact_rtt_incomplete fi
       ON fi.date_key               = d.date_key
      AND fi.trust_key              = t.trust_key
      AND fi.treatment_function_key = tf.treatment_function_key

LEFT JOIN dim_wait_band wb    ON wb.wait_band_key          = fi.wait_band_key

LEFT JOIN fact_rtt_completed fc
       ON fc.date_key               = d.date_key
      AND fc.trust_key              = t.trust_key
      AND fc.treatment_function_key = tf.treatment_function_key

LEFT JOIN fact_rtt_new_periods fn
       ON fn.date_key               = d.date_key
      AND fn.trust_key              = t.trust_key
      AND fn.treatment_function_key = tf.treatment_function_key

GROUP BY
    d.full_date, d.year, d.financial_year, d.financial_quarter,
    d.month_name, d.is_covid_period,
    r.region_name,
    t.trust_code, t.trust_name, t.trust_type,
    tf.treatment_function_name, tf.specialty_group;


-- v_national_monthly: England-level aggregated view (for headline trend charts)
CREATE OR REPLACE VIEW v_national_monthly AS
SELECT
    d.full_date,
    d.year,
    d.financial_year,
    d.financial_quarter,
    d.is_covid_period,
    SUM(fi.patients_waiting)                                              AS total_waiting,
    SUM(CASE WHEN wb.is_breach      = 1 THEN fi.patients_waiting ELSE 0 END) AS waiting_over_18wks,
    SUM(CASE WHEN wb.is_long_waiter = 1 THEN fi.patients_waiting ELSE 0 END) AS waiting_over_52wks,
    SUM(fc.total_completed)                                               AS total_completed,
    SUM(fn.new_rtt_periods)                                               AS new_rtt_periods,

    -- Derived: net list change = new_periods - completed (treatments out)
    SUM(fn.new_rtt_periods) - SUM(fc.total_completed)                    AS net_list_change,

    -- Referral efficiency: completions per new referral
    ROUND(
        SUM(fc.total_completed) / NULLIF(SUM(fn.new_rtt_periods), 0),
    3)                                                                    AS treatment_per_referral_ratio,

    -- Breach rate: % waiting patients beyond 18 weeks
    ROUND(
        100.0 * SUM(CASE WHEN wb.is_breach = 1 THEN fi.patients_waiting ELSE 0 END)
        / NULLIF(SUM(fi.patients_waiting), 0),
    2)                                                                    AS breach_rate_pct

FROM dim_date d

LEFT JOIN fact_rtt_incomplete fi ON fi.date_key = d.date_key
LEFT JOIN dim_wait_band wb        ON wb.wait_band_key = fi.wait_band_key
LEFT JOIN fact_rtt_completed fc   ON fc.date_key = d.date_key
                                 AND fc.trust_key = fi.trust_key
                                 AND fc.treatment_function_key = fi.treatment_function_key
LEFT JOIN fact_rtt_new_periods fn ON fn.date_key = d.date_key
                                 AND fn.trust_key = fi.trust_key
                                 AND fn.treatment_function_key = fi.treatment_function_key
GROUP BY
    d.full_date, d.year, d.financial_year, d.financial_quarter, d.is_covid_period
ORDER BY d.full_date;
