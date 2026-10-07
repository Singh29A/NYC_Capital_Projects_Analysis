-- =====================================================================
-- 03_build_star_schema.sql
-- Builds analysis-ready tables from the staging tables.
--
-- Key modelling decision (verified in 02_data_cleaning.ipynb):
--   Budgets are stored once per  reporting_period + fms_id + managing_agency.
--   The raw table repeats the same budget on every project (PID) linked to a
--   budget line, so summing it directly overstates the portfolio by ~$47B.
--   Budgets and projects are therefore kept in separate tables, joined
--   through a bridge table (many-to-many).
-- =====================================================================

USE nyc_capital_projects;

-- ---------------------------------------------------------------------
-- 1. fact_budget_snapshot: one row per period + FMS ID + agency
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS fact_budget_snapshot;
CREATE TABLE fact_budget_snapshot (
    reporting_period        DATE          NOT NULL,
    fms_id                  VARCHAR(100)  NOT NULL,
    agency_code             VARCHAR(50)   NOT NULL,
    fms_project_name        VARCHAR(1000),
    budget_line             TEXT,
    ten_year_plan_category  VARCHAR(1000),
    total_budget            DECIMAL(18,2),
    spend_to_date           DECIMAL(18,2),
    linked_projects         INT,
    PRIMARY KEY (reporting_period, fms_id, agency_code)
);

INSERT INTO fact_budget_snapshot
SELECT
    reporting_period,
    fms_id,
    COALESCE(managing_agency, 'N/A'),
    MAX(fms_project_name),
    MAX(budget_line),
    MAX(ten_year_plan_category),
    MAX(total_budget),            -- identical within the group (verified), so MAX = the single value
    MAX(spend_to_date),
    COUNT(DISTINCT pid)
FROM stg_budget_schedule
WHERE fms_id IS NOT NULL
GROUP BY reporting_period, fms_id, COALESCE(managing_agency, 'N/A');

-- ---------------------------------------------------------------------
-- 2. fact_project_snapshot: one row per period + project (PID)
--    Only projects with an agency schedule. Phase labels from the agency
--    schedule (no brackets) are preferred over finance-system labels.
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS fact_project_snapshot;
CREATE TABLE fact_project_snapshot (
    reporting_period                       DATE  NOT NULL,
    pid                                    INT   NOT NULL,
    agency_code                            VARCHAR(50),
    current_phase                          VARCHAR(255),
    phase_group                            VARCHAR(100),
    current_phase_start                    DATE,
    forecast_current_phase_end             DATE,
    forecast_completion                    DATE,
    actual_design_start                    DATE,
    actual_design_end                      DATE,
    actual_construction_procurement_start  DATE,
    actual_construction_procurement_end    DATE,
    actual_construction_start              DATE,
    actual_construction_end                DATE,
    funding_lines                          INT,
    PRIMARY KEY (reporting_period, pid)
);

INSERT INTO fact_project_snapshot
SELECT
    reporting_period,
    pid,
    MAX(managing_agency),
    COALESCE(MAX(CASE WHEN phase_in_brackets = 0 THEN current_phase END), MAX(current_phase)),
    COALESCE(MAX(CASE WHEN phase_in_brackets = 0 THEN phase_group  END), MAX(phase_group)),
    MAX(current_phase_start),
    MAX(forecast_current_phase_end),
    MAX(forecast_completion),
    MIN(actual_design_start),
    MAX(actual_design_end),
    MIN(actual_construction_procurement_start),
    MAX(actual_construction_procurement_end),
    MIN(actual_construction_start),
    MAX(actual_construction_end),
    COUNT(DISTINCT fms_id)
FROM stg_budget_schedule
WHERE pid IS NOT NULL
GROUP BY reporting_period, pid;

-- ---------------------------------------------------------------------
-- 3. dim_project: one row per project, attributes from its latest snapshot
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS dim_project;
CREATE TABLE dim_project (
    pid                         INT PRIMARY KEY,
    project_name                VARCHAR(1000),
    agency_code                 VARCHAR(50),
    borough                     VARCHAR(500),
    first_reported              DATE,
    last_reported               DATE,
    latest_phase                VARCHAR(255),
    latest_phase_group          VARCHAR(100),
    latest_forecast_completion  DATE
);

INSERT INTO dim_project
SELECT
    r.pid,
    a.project_name,
    r.agency_code,
    a.borough,
    r.first_reported,
    r.reporting_period,
    r.current_phase,
    r.phase_group,
    r.forecast_completion
FROM (
    SELECT ps.*,
           ROW_NUMBER() OVER (PARTITION BY pid ORDER BY reporting_period DESC) AS rn,
           MIN(reporting_period) OVER (PARTITION BY pid)                    AS first_reported
    FROM fact_project_snapshot ps
) r
JOIN (
    SELECT pid, reporting_period,
           MAX(agency_project_name) AS project_name,
           MAX(borough)             AS borough
    FROM stg_budget_schedule
    WHERE pid IS NOT NULL
    GROUP BY pid, reporting_period
) a ON a.pid = r.pid AND a.reporting_period = r.reporting_period
WHERE r.rn = 1;

-- ---------------------------------------------------------------------
-- 4. bridge_fms_project: which budget lines fund which projects
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS bridge_fms_project;
CREATE TABLE bridge_fms_project (
    fms_id        VARCHAR(100) NOT NULL,
    agency_code   VARCHAR(50)  NOT NULL,
    pid           INT          NOT NULL,
    first_linked  DATE,
    last_linked   DATE,
    PRIMARY KEY (fms_id, agency_code, pid)
);

INSERT INTO bridge_fms_project
SELECT fms_id, COALESCE(managing_agency, 'N/A'), pid,
       MIN(reporting_period), MAX(reporting_period)
FROM stg_budget_schedule
WHERE pid IS NOT NULL AND fms_id IS NOT NULL
GROUP BY fms_id, COALESCE(managing_agency, 'N/A'), pid;

-- ---------------------------------------------------------------------
-- 5. fact_schedule_change: every reported change to a completion date
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS fact_schedule_change;
CREATE TABLE fact_schedule_change (
    change_id             INT AUTO_INCREMENT PRIMARY KEY,
    pid                   INT,
    reporting_period      DATE,
    agency_code           VARCHAR(50),
    current_phase         VARCHAR(255),
    phase_group           VARCHAR(100),
    completion_date       DATE,
    completion_date_type  VARCHAR(50),
    variance_days         INT,
    change_type           VARCHAR(50),
    delay_reason          VARCHAR(255),
    reason_raw            VARCHAR(1000),
    pid_in_budget_data    TINYINT,
    INDEX ix_pid_period (pid, reporting_period)
);

INSERT INTO fact_schedule_change
    (pid, reporting_period, agency_code, current_phase, phase_group, completion_date,
     completion_date_type, variance_days, change_type, delay_reason, reason_raw, pid_in_budget_data)
SELECT pid, reporting_period, managing_agency, current_phase, phase_group, completion_date,
       completion_date_type, ROUND(variance_days), change_type, delay_reason,
       reason_for_forecast_completion_change, 1 - flag_pid_not_in_budget
FROM stg_schedule_history
ORDER BY pid, reporting_period;

-- ---------------------------------------------------------------------
-- 6. Validation
-- ---------------------------------------------------------------------
SELECT 'fact_budget_snapshot rows' AS check_name, COUNT(*) AS result, '~55170' AS expected
FROM fact_budget_snapshot
UNION ALL
SELECT 'staging rows with no FMS ID (excluded)', SUM(fms_id IS NULL), '0 ideally'
FROM stg_budget_schedule
UNION ALL
SELECT 'latest portfolio budget, deduplicated ($B)', ROUND(SUM(total_budget) / 1e9, 2), '160.34'
FROM fact_budget_snapshot
WHERE reporting_period = (SELECT MAX(reporting_period) FROM fact_budget_snapshot)
UNION ALL
SELECT 'fact_project_snapshot rows', COUNT(*), '-'
FROM fact_project_snapshot
UNION ALL
SELECT 'dim_project rows', COUNT(*), '3638'
FROM dim_project
UNION ALL
SELECT 'bridge_fms_project rows', COUNT(*), '-'
FROM bridge_fms_project
UNION ALL
SELECT 'fact_schedule_change rows', COUNT(*), '22464'
FROM fact_schedule_change
UNION ALL
SELECT 'project snapshots with conflicting forecast dates', COUNT(*), 'small'
FROM (
    SELECT reporting_period, pid
    FROM stg_budget_schedule
    WHERE pid IS NOT NULL
    GROUP BY reporting_period, pid
    HAVING COUNT(DISTINCT forecast_completion) > 1
) conflicts;
