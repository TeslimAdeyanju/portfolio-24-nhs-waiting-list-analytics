-- ============================================================
-- NHS Waiting List Analytics — Databricks Delta Tables
-- Database:  nhs_waiting_list
-- Source:    CSVs uploaded to /FileStore/tables/
--            (see 01_upload_processed_csvs.md)
-- Run in:    Databricks SQL Editor
-- Author:    Teslim Uthman Adeyanju
-- Date:      April 2026
-- ============================================================

CREATE DATABASE IF NOT EXISTS nhs_waiting_list;

-- ============================================================
-- TABLE 1: fact_rtt_incomplete
-- Monthly snapshot of patients still on the waiting list.
-- Source: data/processed/incomplete/combined.csv
-- Columns: region_code, provider_org_code, provider_org_name,
--          treatment_function_code, treatment_function_name,
--          band_0_5_wks … band_52_plus (12 aggregated bands),
--          total_waiting, median_wait_weeks,
--          percentile_92_wait_weeks, period_date, source_file
-- ============================================================

CREATE OR REPLACE TABLE nhs_waiting_list.fact_rtt_incomplete
USING DELTA
AS
SELECT *
FROM csv.`/FileStore/tables/fact_rtt_incomplete.csv`
WITH (header = 'true', inferSchema = 'true');


-- ============================================================
-- TABLE 2: fact_rtt_completed
-- Monthly treated pathways — admitted and non-admitted combined.
-- Sources: data/processed/completed_admitted/combined.csv
--          data/processed/completed_non_admitted/combined.csv
-- Both CSVs share the same schema; pathway_type column
-- distinguishes 'Admitted' from 'Non-Admitted' rows.
-- ============================================================

CREATE OR REPLACE TABLE nhs_waiting_list.fact_rtt_completed
USING DELTA
AS
SELECT * FROM csv.`/FileStore/tables/fact_rtt_completed_admitted.csv`
    WITH (header = 'true', inferSchema = 'true')
UNION ALL
SELECT * FROM csv.`/FileStore/tables/fact_rtt_completed_non_admitted.csv`
    WITH (header = 'true', inferSchema = 'true');


-- ============================================================
-- TABLE 3: fact_rtt_new_periods
-- Monthly new RTT clock starts — proxy for referral demand.
-- Source: data/processed/new_periods/combined.csv
-- ============================================================

CREATE OR REPLACE TABLE nhs_waiting_list.fact_rtt_new_periods
USING DELTA
AS
SELECT *
FROM csv.`/FileStore/tables/fact_rtt_new_periods.csv`
WITH (header = 'true', inferSchema = 'true');


-- ============================================================
-- Verify
-- ============================================================

USE nhs_waiting_list;
SHOW TABLES;

-- Quick row counts
SELECT 'fact_rtt_incomplete'  AS table_name, COUNT(*) AS row_count FROM nhs_waiting_list.fact_rtt_incomplete
UNION ALL
SELECT 'fact_rtt_completed',                 COUNT(*) FROM nhs_waiting_list.fact_rtt_completed
UNION ALL
SELECT 'fact_rtt_new_periods',               COUNT(*) FROM nhs_waiting_list.fact_rtt_new_periods;

-- Period coverage check
SELECT
    MIN(period_date) AS earliest_period,
    MAX(period_date) AS latest_period,
    COUNT(DISTINCT period_date) AS months_loaded
FROM nhs_waiting_list.fact_rtt_incomplete;
