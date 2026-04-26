-- ============================================================
-- NHS Waiting List Analytics - Star Schema
-- Database: nhs_waiting_list_db
-- Purpose: Analyse RTT waiting list dynamics, referral behaviour,
--          and system incentive effects across NHS England Trusts
-- Author:   Teslim Uthman Adeyanju
-- Source:   NHS England RTT Statistics
--           https://www.england.nhs.uk/statistics/statistical-work-areas/rtt-waiting-times/
-- Date:     April 2026
-- ============================================================

CREATE DATABASE IF NOT EXISTS nhs_waiting_list_db
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE nhs_waiting_list_db;

-- ============================================================
-- DIMENSION TABLES
-- ============================================================

-- dim_date: Calendar dimension covering the full RTT reporting period
CREATE TABLE IF NOT EXISTS dim_date (
    date_key            INT PRIMARY KEY COMMENT 'Surrogate key: YYYYMM',
    full_date           DATE         NOT NULL COMMENT 'First day of reporting month',
    year                SMALLINT     NOT NULL,
    quarter             TINYINT      NOT NULL COMMENT '1-4',
    month               TINYINT      NOT NULL COMMENT '1-12',
    month_name          VARCHAR(10)  NOT NULL,
    financial_year      VARCHAR(9)   NOT NULL COMMENT 'e.g. 2023/24 (Apr-Mar)',
    financial_quarter   VARCHAR(6)   NOT NULL COMMENT 'e.g. Q1 2324',
    is_covid_period     TINYINT(1)   NOT NULL DEFAULT 0 COMMENT '1 = Mar 2020 – Mar 2022',

    INDEX idx_year        (year),
    INDEX idx_fin_year    (financial_year),
    INDEX idx_full_date   (full_date)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Calendar dimension — one row per reporting month';


-- dim_trust: NHS Trust/commissioner dimension
CREATE TABLE IF NOT EXISTS dim_trust (
    trust_key           INT AUTO_INCREMENT PRIMARY KEY,
    trust_code          VARCHAR(10)  NOT NULL UNIQUE COMMENT 'ODS code, e.g. RJ1',
    trust_name          VARCHAR(200) NOT NULL,
    trust_type          VARCHAR(50)  COMMENT 'Acute / Mental Health / Community / Specialist',
    region_key          INT          NOT NULL COMMENT 'FK → dim_region',
    is_active           TINYINT(1)   NOT NULL DEFAULT 1,
    created_at          TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,

    INDEX idx_trust_code (trust_code),
    INDEX idx_region     (region_key)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='NHS Trust dimension — organisational reference';


-- dim_region: NHS England regional dimension
CREATE TABLE IF NOT EXISTS dim_region (
    region_key          INT AUTO_INCREMENT PRIMARY KEY,
    region_code         VARCHAR(10)  NOT NULL UNIQUE,
    region_name         VARCHAR(100) NOT NULL,
    nhs_region_abbrev   VARCHAR(10)  COMMENT 'e.g. NHSE-NW',

    INDEX idx_region_code (region_code)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='NHS England regional boundaries';


-- dim_treatment_function: Clinical specialty dimension
CREATE TABLE IF NOT EXISTS dim_treatment_function (
    treatment_function_key  INT AUTO_INCREMENT PRIMARY KEY,
    treatment_function_code VARCHAR(10)  NOT NULL UNIQUE COMMENT 'e.g. 100 = General Surgery',
    treatment_function_name VARCHAR(200) NOT NULL,
    specialty_group         VARCHAR(100) COMMENT 'Surgical / Medical / Diagnostic / Mental Health',

    INDEX idx_tf_code (treatment_function_code)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Clinical specialty/treatment function reference';


-- dim_wait_band: Waiting time band dimension (aligns to NHS reporting bands)
CREATE TABLE IF NOT EXISTS dim_wait_band (
    wait_band_key       INT AUTO_INCREMENT PRIMARY KEY,
    band_label          VARCHAR(30)  NOT NULL UNIQUE COMMENT 'e.g. 0-18 weeks',
    lower_weeks         SMALLINT     NOT NULL COMMENT 'inclusive lower bound',
    upper_weeks         SMALLINT              COMMENT 'NULL = open-ended (52+)',
    is_breach           TINYINT(1)   NOT NULL DEFAULT 0 COMMENT '1 = breaches 18-week standard',
    is_long_waiter      TINYINT(1)   NOT NULL DEFAULT 0 COMMENT '1 = 52+ weeks (tracked separately by NHSE)'
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Waiting time banding reference — mirrors NHS England RTT bands';


-- ============================================================
-- FACT TABLES
-- ============================================================

-- fact_rtt_incomplete: Monthly snapshot of patients still on a waiting list
-- (incomplete RTT pathways — the "waiting list" headline figure)
CREATE TABLE IF NOT EXISTS fact_rtt_incomplete (
    rtt_incomplete_key          BIGINT AUTO_INCREMENT PRIMARY KEY,

    -- Dimension keys
    date_key                    INT         NOT NULL COMMENT 'FK → dim_date',
    trust_key                   INT         NOT NULL COMMENT 'FK → dim_trust',
    treatment_function_key      INT         NOT NULL COMMENT 'FK → dim_treatment_function',
    wait_band_key               INT         NOT NULL COMMENT 'FK → dim_wait_band',

    -- Measures
    patients_waiting            INT         NOT NULL DEFAULT 0 COMMENT 'Patients on list in this wait band',

    -- Metadata
    data_source                 VARCHAR(50) NOT NULL DEFAULT 'NHS England RTT',
    load_timestamp              TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,

    -- Constraints
    CHECK (patients_waiting >= 0),

    -- Indexes
    INDEX idx_incomplete_date   (date_key),
    INDEX idx_incomplete_trust  (trust_key),
    INDEX idx_incomplete_tf     (treatment_function_key),
    INDEX idx_incomplete_band   (wait_band_key),

    FOREIGN KEY (date_key)               REFERENCES dim_date(date_key),
    FOREIGN KEY (trust_key)              REFERENCES dim_trust(trust_key),
    FOREIGN KEY (treatment_function_key) REFERENCES dim_treatment_function(treatment_function_key),
    FOREIGN KEY (wait_band_key)          REFERENCES dim_wait_band(wait_band_key)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Fact: monthly incomplete RTT pathways (patients still waiting) by wait band';


-- fact_rtt_completed: Monthly completed RTT pathways (patients treated/discharged)
CREATE TABLE IF NOT EXISTS fact_rtt_completed (
    rtt_completed_key           BIGINT AUTO_INCREMENT PRIMARY KEY,

    -- Dimension keys
    date_key                    INT         NOT NULL COMMENT 'FK → dim_date',
    trust_key                   INT         NOT NULL COMMENT 'FK → dim_trust',
    treatment_function_key      INT         NOT NULL COMMENT 'FK → dim_treatment_function',
    wait_band_key               INT         NOT NULL COMMENT 'FK → dim_wait_band',

    -- Measures: admitted vs non-admitted completed pathways
    completed_admitted          INT         NOT NULL DEFAULT 0 COMMENT 'Elective inpatient/daycase admissions',
    completed_non_admitted      INT         NOT NULL DEFAULT 0 COMMENT 'Outpatient first consultations',
    total_completed             INT         GENERATED ALWAYS AS (completed_admitted + completed_non_admitted) STORED,

    -- Derived wait percentiles (populated from published summary files)
    median_wait_weeks           DECIMAL(6,2)         COMMENT 'Median wait for completed pathways',
    percentile_92_wait_weeks    DECIMAL(6,2)         COMMENT '92nd percentile wait (18-wk standard proxy)',

    -- Metadata
    data_source                 VARCHAR(50) NOT NULL DEFAULT 'NHS England RTT',
    load_timestamp              TIMESTAMP   DEFAULT CURRENT_TIMESTAMP,

    CHECK (completed_admitted     >= 0),
    CHECK (completed_non_admitted >= 0),

    INDEX idx_completed_date    (date_key),
    INDEX idx_completed_trust   (trust_key),
    INDEX idx_completed_tf      (treatment_function_key),

    FOREIGN KEY (date_key)               REFERENCES dim_date(date_key),
    FOREIGN KEY (trust_key)              REFERENCES dim_trust(trust_key),
    FOREIGN KEY (treatment_function_key) REFERENCES dim_treatment_function(treatment_function_key),
    FOREIGN KEY (wait_band_key)          REFERENCES dim_wait_band(wait_band_key)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Fact: monthly completed RTT pathways (treatments) — admitted and non-admitted';


-- fact_rtt_new_periods: Monthly new RTT clock starts (proxy for referral demand)
-- This is the key table for detecting referral suppression vs genuine demand reduction
CREATE TABLE IF NOT EXISTS fact_rtt_new_periods (
    rtt_new_key                 BIGINT AUTO_INCREMENT PRIMARY KEY,

    -- Dimension keys
    date_key                    INT         NOT NULL COMMENT 'FK → dim_date',
    trust_key                   INT         NOT NULL COMMENT 'FK → dim_trust',
    treatment_function_key      INT         NOT NULL COMMENT 'FK → dim_treatment_function',

    -- Measures
    new_rtt_periods             INT         NOT NULL DEFAULT 0 COMMENT 'New clock starts = referrals accepted into RTT',

    CHECK (new_rtt_periods >= 0),

    INDEX idx_new_date           (date_key),
    INDEX idx_new_trust          (trust_key),
    INDEX idx_new_tf             (treatment_function_key),

    FOREIGN KEY (date_key)               REFERENCES dim_date(date_key),
    FOREIGN KEY (trust_key)              REFERENCES dim_trust(trust_key),
    FOREIGN KEY (treatment_function_key) REFERENCES dim_treatment_function(treatment_function_key)
) ENGINE=InnoDB
  CHARSET=utf8mb4
  COMMENT='Fact: monthly new RTT clock starts — proxy for referral/demand volume';


-- ============================================================
-- REFERENCE DATA: SEED INSERTS
-- ============================================================

-- NHS England Regions (7 regions as of 2023)
INSERT INTO dim_region (region_code, region_name, nhs_region_abbrev) VALUES
    ('Y56', 'North East and Yorkshire',   'NHSE-NEY'),
    ('Y58', 'North West',                 'NHSE-NW'),
    ('Y59', 'Midlands',                   'NHSE-MID'),
    ('Y60', 'East of England',            'NHSE-EOE'),
    ('Y61', 'London',                     'NHSE-LON'),
    ('Y62', 'South East',                 'NHSE-SE'),
    ('Y63', 'South West',                 'NHSE-SW')
ON DUPLICATE KEY UPDATE region_name = VALUES(region_name);


-- NHS RTT Wait Bands (aligned to NHSE published breakdown)
INSERT INTO dim_wait_band (band_label, lower_weeks, upper_weeks, is_breach, is_long_waiter) VALUES
    ('0-5 weeks',       0,   5,  0, 0),
    ('6-10 weeks',      6,  10,  0, 0),
    ('11-15 weeks',    11,  15,  0, 0),
    ('16-18 weeks',    16,  18,  0, 0),
    ('19-23 weeks',    19,  23,  1, 0),
    ('24-28 weeks',    24,  28,  1, 0),
    ('29-33 weeks',    29,  33,  1, 0),
    ('34-38 weeks',    34,  38,  1, 0),
    ('39-43 weeks',    39,  43,  1, 0),
    ('44-48 weeks',    44,  48,  1, 0),
    ('49-52 weeks',    49,  52,  1, 0),
    ('52+ weeks',      52, NULL, 1, 1)
ON DUPLICATE KEY UPDATE band_label = VALUES(band_label);


-- High-volume treatment functions (top specialties by RTT volume)
INSERT INTO dim_treatment_function (treatment_function_code, treatment_function_name, specialty_group) VALUES
    ('100', 'General Surgery',              'Surgical'),
    ('101', 'Urology',                      'Surgical'),
    ('110', 'Trauma and Orthopaedic',       'Surgical'),
    ('120', 'Ear Nose and Throat (ENT)',     'Surgical'),
    ('130', 'Ophthalmology',                'Surgical'),
    ('140', 'Oral Surgery',                 'Surgical'),
    ('150', 'Neurosurgery',                 'Surgical'),
    ('160', 'Plastic Surgery',              'Surgical'),
    ('170', 'Cardiothoracic Surgery',       'Surgical'),
    ('300', 'General Medicine',             'Medical'),
    ('301', 'Gastroenterology',             'Medical'),
    ('320', 'Cardiology',                   'Medical'),
    ('330', 'Dermatology',                  'Medical'),
    ('340', 'Respiratory Medicine',         'Medical'),
    ('400', 'Neurology',                    'Medical'),
    ('410', 'Rheumatology',                 'Medical'),
    ('420', 'Endocrinology',                'Medical'),
    ('501', 'Obstetrics',                   'Medical'),
    ('502', 'Gynaecology',                  'Surgical'),
    ('711', 'Clinical Psychology',          'Mental Health'),
    ('800', 'Clinical Oncology',            'Medical'),
    ('502', 'Gynaecology',                  'Surgical')
ON DUPLICATE KEY UPDATE treatment_function_name = VALUES(treatment_function_name);
