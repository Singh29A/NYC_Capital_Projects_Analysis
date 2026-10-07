-- =====================================================================
-- 02_load_staging.sql
-- Loads the cleaned CSVs (from 02_data_cleaning.ipynb) into staging tables.
-- Staging tables mirror the CSVs one-to-one; the star schema is built
-- from them in the next script.
--
-- Before running: copy the three files from data/processed/for_mysql/ into
-- C:\ProgramData\MySQL\MySQL Server 26.7\Uploads\  (MySQL's secure_file_priv folder)
-- =====================================================================

USE nyc_capital_projects;

-- ---------------------------------------------------------------------
-- 1. Agency lookup
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dim_agency;
CREATE TABLE dim_agency (
    agency_code  VARCHAR(10)  PRIMARY KEY,
    agency_name  VARCHAR(100) NOT NULL
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 26.7/Uploads/dim_agency.csv'
INTO TABLE dim_agency
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

-- ---------------------------------------------------------------------
-- 2. Budget & schedule snapshots (10 reporting periods, May 2023 - May 2026)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_budget_schedule;
CREATE TABLE stg_budget_schedule (
    reporting_period                       DATE,
    managing_agency                        VARCHAR(50),
    sponsor_agency                         VARCHAR(500),
    pid                                    INT,
    fms_id                                 VARCHAR(100),
    total_budget                           DOUBLE,
    spend_to_date                          DOUBLE,
    spend_to_date_pct                      DOUBLE,
    fms_project_name                       VARCHAR(1000),
    agency_project_name                    VARCHAR(1000),
    agency_project_description             TEXT,
    current_phase                          VARCHAR(255),
    current_phase_start                    DATE,
    forecast_current_phase_end             DATE,
    forecast_completion                    DATE,
    actual_design_start                    DATE,
    actual_design_end                      DATE,
    actual_construction_procurement_start  DATE,
    actual_construction_procurement_end    DATE,
    actual_construction_start              DATE,
    actual_construction_end                DATE,
    borough                                VARCHAR(500),
    community_board                        VARCHAR(500),
    budget_line                            TEXT,
    ten_year_plan_category                 VARCHAR(1000),
    agency_data_date                       DATE,
    fms_data_date                          DATE,
    has_schedule                           TINYINT,
    current_phase_raw                      VARCHAR(255),
    phase_in_brackets                      TINYINT,
    phase_group                            VARCHAR(100),
    flag_zero_or_negative_budget           TINYINT,
    flag_spend_exceeds_budget              TINYINT
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 26.7/Uploads/budget_schedule_clean.csv'
INTO TABLE stg_budget_schedule
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

CREATE INDEX ix_bs_period_fms ON stg_budget_schedule (reporting_period, fms_id, managing_agency);
CREATE INDEX ix_bs_period_pid ON stg_budget_schedule (reporting_period, pid);

-- ---------------------------------------------------------------------
-- 3. Schedule history (every change to a project's completion date)
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS stg_schedule_history;
CREATE TABLE stg_schedule_history (
    reporting_period                       DATE,
    managing_agency                        VARCHAR(50),
    pid                                    INT,
    agency_project_name                    VARCHAR(1000),
    current_phase                          VARCHAR(255),
    completion_date                        DATE,
    completion_date_type                   VARCHAR(50),
    variance_days                          DOUBLE,
    reason_for_forecast_completion_change  VARCHAR(1000),
    data_date                              DATE,
    current_phase_raw                      VARCHAR(255),
    phase_group                            VARCHAR(100),
    delay_reason                           VARCHAR(255),
    change_type                            VARCHAR(50),
    flag_pid_not_in_budget                 TINYINT
);

LOAD DATA INFILE 'C:/ProgramData/MySQL/MySQL Server 26.7/Uploads/schedule_history_clean.csv'
INTO TABLE stg_schedule_history
CHARACTER SET utf8mb4
FIELDS TERMINATED BY ',' OPTIONALLY ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;

CREATE INDEX ix_sh_pid ON stg_schedule_history (pid, reporting_period);

-- ---------------------------------------------------------------------
-- 4. Validation: every number here should match the Python notebook
-- ---------------------------------------------------------------------
SELECT 'dim_agency rows'                         AS check_name, COUNT(*) AS result, '25'      AS expected FROM dim_agency
UNION ALL
SELECT 'stg_budget_schedule rows',               COUNT(*),                         '56525'   FROM stg_budget_schedule
UNION ALL
SELECT 'stg_schedule_history rows',              COUNT(*),                         '22464'   FROM stg_schedule_history
UNION ALL
SELECT 'budget rows with no PID',                SUM(pid IS NULL),                 '26461'   FROM stg_budget_schedule
UNION ALL
SELECT 'distinct reporting periods',             COUNT(DISTINCT reporting_period), '10'      FROM stg_budget_schedule
UNION ALL
SELECT 'latest snapshot naive budget ($B)',
       ROUND(SUM(total_budget) / 1e9, 2),                                          '207.59'
FROM stg_budget_schedule
WHERE reporting_period = (SELECT MAX(reporting_period) FROM stg_budget_schedule);
