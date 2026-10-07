-- =====================================================================
-- 01_create_database.sql
-- Creates the project database and checks MySQL's file-loading settings.
-- Run this first, then 02_load_staging.sql, 03_build_star_schema.sql,
-- and 04_analysis.sql in order.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS nyc_capital_projects;
USE nyc_capital_projects;

-- Folder MySQL is allowed to load CSV files from (used by 02_load_staging.sql).
-- On this setup: C:\ProgramData\MySQL\MySQL Server 26.7\Uploads\
SHOW VARIABLES LIKE 'secure_file_priv';
SHOW VARIABLES LIKE 'local_infile';
