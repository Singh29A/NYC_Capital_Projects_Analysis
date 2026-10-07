-- =====================================================================
-- 04_analysis.sql
-- Answers the case-study questions. Part A creates reusable views
-- (Power BI will read these). Part B runs the analysis queries.
--
-- Note on wording: "budget growth" = change between the first and latest
-- snapshot of a budget line in this dataset (May 2023 - May 2026). It can
-- reflect overruns *or* deliberate scope additions; the data doesn't say which.
-- =====================================================================

USE nyc_capital_projects;

-- =====================================================================
-- PART A: VIEWS
-- =====================================================================

-- A1. Budget growth per budget line (first vs latest snapshot)
CREATE OR REPLACE VIEW vw_budget_growth AS
WITH ranked AS (
    SELECT f.*,
           FIRST_VALUE(total_budget)     OVER w AS first_budget,
           FIRST_VALUE(reporting_period) OVER w AS first_period,
           ROW_NUMBER() OVER (PARTITION BY fms_id, agency_code ORDER BY reporting_period DESC) AS rn_latest
    FROM fact_budget_snapshot f
    WINDOW w AS (PARTITION BY fms_id, agency_code ORDER BY reporting_period)
)
SELECT fms_id,
       agency_code,
       fms_project_name,
       ten_year_plan_category,
       first_period,
       reporting_period                AS latest_period,
       first_budget,
       total_budget                    AS latest_budget,
       total_budget - first_budget     AS budget_change,
       CASE WHEN first_budget > 0
            THEN (total_budget - first_budget) / first_budget END AS budget_change_pct,
       spend_to_date
FROM ranked
WHERE rn_latest = 1;

-- A2. Schedule slippage per project (first vs latest forecast completion)
CREATE OR REPLACE VIEW vw_project_slippage AS
WITH s AS (
    SELECT pid, reporting_period, forecast_completion,
           FIRST_VALUE(forecast_completion) OVER w AS first_forecast,
           FIRST_VALUE(reporting_period)    OVER w AS first_period,
           ROW_NUMBER() OVER (PARTITION BY pid ORDER BY reporting_period DESC) AS rn
    FROM fact_project_snapshot
    WHERE forecast_completion IS NOT NULL
    WINDOW w AS (PARTITION BY pid ORDER BY reporting_period)
),
c AS (
    SELECT pid,
           SUM(change_type = 'Delay')        AS delay_count,
           SUM(change_type = 'Acceleration') AS acceleration_count,
           SUM(CASE WHEN change_type = 'Delay' THEN variance_days ELSE 0 END) AS days_delayed_reported
    FROM fact_schedule_change
    GROUP BY pid
)
SELECT s.pid,
       p.project_name,
       p.agency_code,
       p.borough,
       p.latest_phase_group,
       s.first_period,
       s.reporting_period                              AS latest_period,
       s.first_forecast,
       s.forecast_completion                           AS latest_forecast,
       DATEDIFF(s.forecast_completion, s.first_forecast) AS slip_days,
       COALESCE(c.delay_count, 0)                      AS delay_count,
       COALESCE(c.acceleration_count, 0)               AS acceleration_count,
       COALESCE(c.days_delayed_reported, 0)            AS days_delayed_reported
FROM s
JOIN dim_project p ON p.pid = s.pid
LEFT JOIN c        ON c.pid = s.pid
WHERE s.rn = 1;

-- A3. Latest budget per project. Shared budget lines are split evenly
--     across the projects they fund, so no dollar is counted twice.
CREATE OR REPLACE VIEW vw_project_budget_latest AS
SELECT x.pid,
       SUM(f.total_budget  / f.linked_projects) AS allocated_budget,
       SUM(f.spend_to_date / f.linked_projects) AS allocated_spend,
       COUNT(*)                                 AS funding_lines
FROM (
    SELECT DISTINCT fms_id, COALESCE(managing_agency, 'N/A') AS agency_code, pid
    FROM stg_budget_schedule
    WHERE pid IS NOT NULL
      AND reporting_period = (SELECT MAX(reporting_period) FROM stg_budget_schedule)
) x
JOIN fact_budget_snapshot f
  ON  f.fms_id      = x.fms_id
  AND f.agency_code = x.agency_code
  AND f.reporting_period = (SELECT MAX(reporting_period) FROM fact_budget_snapshot)
GROUP BY x.pid;


-- =====================================================================
-- PART B: ANALYSIS QUERIES
-- =====================================================================

-- Q0. Headline KPIs
SELECT
    (SELECT ROUND(SUM(total_budget) / 1e9, 2) FROM fact_budget_snapshot
      WHERE reporting_period = (SELECT MAX(reporting_period) FROM fact_budget_snapshot))   AS portfolio_budget_bn,
    (SELECT COUNT(*) FROM vw_budget_growth)                                                 AS budget_lines,
    (SELECT COUNT(*) FROM vw_project_slippage)                                              AS projects_with_schedule,
    (SELECT ROUND(100 * AVG(slip_days > 0), 1) FROM vw_project_slippage
      WHERE first_period < latest_period)                                                   AS pct_projects_slipped,
    (SELECT ROUND(AVG(slip_days)) FROM vw_project_slippage
      WHERE first_period < latest_period)                                                   AS avg_slip_days;

-- Q1. Portfolio budget over time (deduplicated)
SELECT reporting_period,
       COUNT(*)                          AS budget_lines,
       ROUND(SUM(total_budget)  / 1e9, 2) AS total_budget_bn,
       ROUND(SUM(spend_to_date) / 1e9, 2) AS spend_to_date_bn
FROM fact_budget_snapshot
GROUP BY reporting_period
ORDER BY reporting_period;

-- Q2. Budget growth by agency (lines tracked across more than one snapshot)
SELECT g.agency_code,
       a.agency_name,
       COUNT(*)                                                        AS budget_lines,
       ROUND(SUM(g.first_budget)  / 1e6, 1)                            AS first_budget_m,
       ROUND(SUM(g.latest_budget) / 1e6, 1)                            AS latest_budget_m,
       ROUND(SUM(g.budget_change) / 1e6, 1)                            AS change_m,
       ROUND(100 * SUM(g.budget_change) / NULLIF(SUM(g.first_budget), 0), 1) AS change_pct,
       ROUND(100 * AVG(g.budget_change_pct > 0.10), 1)                 AS pct_lines_grew_over_10pct
FROM vw_budget_growth g
LEFT JOIN dim_agency a ON a.agency_code = g.agency_code
WHERE g.first_period < g.latest_period
  AND g.first_budget > 0
GROUP BY g.agency_code, a.agency_name
ORDER BY change_m DESC;

-- Q3. Schedule slippage by agency (agencies with 20+ tracked projects)
SELECT s.agency_code,
       a.agency_name,
       COUNT(*)                               AS projects,
       ROUND(AVG(s.slip_days))                AS avg_slip_days,
       ROUND(100 * AVG(s.slip_days > 0), 1)   AS pct_slipped,
       ROUND(100 * AVG(s.slip_days > 180), 1) AS pct_slipped_over_6_months,
       ROUND(AVG(s.delay_count), 1)           AS avg_reported_delays
FROM vw_project_slippage s
LEFT JOIN dim_agency a ON a.agency_code = s.agency_code
WHERE s.first_period < s.latest_period
GROUP BY s.agency_code, a.agency_name
HAVING COUNT(*) >= 20
ORDER BY avg_slip_days DESC;

-- Q4. Why projects slip: delay reasons
SELECT delay_reason,
       COUNT(*)                                          AS delays,
       ROUND(SUM(variance_days))                         AS total_days_lost,
       ROUND(AVG(variance_days))                         AS avg_days_per_delay,
       ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (), 1)  AS pct_of_delays
FROM fact_schedule_change
WHERE change_type = 'Delay'
GROUP BY delay_reason
ORDER BY total_days_lost DESC;

-- Q5. Do bigger projects slip more?
SELECT CASE
         WHEN b.allocated_budget <   1e6 THEN '1. Under $1M'
         WHEN b.allocated_budget <  10e6 THEN '2. $1M - $10M'
         WHEN b.allocated_budget <  50e6 THEN '3. $10M - $50M'
         WHEN b.allocated_budget < 100e6 THEN '4. $50M - $100M'
         ELSE                                 '5. $100M+'
       END                                    AS size_band,
       COUNT(*)                               AS projects,
       ROUND(AVG(s.slip_days))                AS avg_slip_days,
       ROUND(100 * AVG(s.slip_days > 180), 1) AS pct_slipped_over_6_months,
       ROUND(AVG(s.delay_count), 1)           AS avg_reported_delays
FROM vw_project_slippage s
JOIN vw_project_budget_latest b ON b.pid = s.pid
WHERE s.first_period < s.latest_period
GROUP BY size_band
ORDER BY size_band;

-- Q6. At-risk watchlist: active projects with repeated or long slips
SELECT s.pid,
       s.project_name,
       s.agency_code,
       s.borough,
       s.latest_phase_group,
       s.delay_count,
       s.slip_days,
       s.latest_forecast,
       ROUND(b.allocated_budget / 1e6, 1) AS budget_m
FROM vw_project_slippage s
JOIN vw_project_budget_latest b ON b.pid = s.pid
WHERE s.latest_phase_group IN ('2 Design', '3 Procurement', '4 Construction')
  AND (s.delay_count >= 3 OR s.slip_days > 365)
ORDER BY s.slip_days DESC
LIMIT 25;
