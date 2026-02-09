-- pgFirstAid Test Data
-- Creates database objects that trigger various health checks
--
-- USAGE:
--   1. Create a fresh test database: CREATE DATABASE pgfirstaid_test;
--   2. Copy the contents of the "pgfirstaid_test_data.sql" and use a tool like dbeaver to execute the sql statement or use psql
--   3. Run pgFirstAid: SELECT * FROM pg_firstAid();
--
-- CLEANUP: DROP DATABASE pgfirstaid_test;

BEGIN;

-- Create test schema
CREATE SCHEMA IF NOT EXISTS test_data;
SET search_path TO test_data, public;

--------------------------------------------------------------------------------
-- CRITICAL: Missing Primary Keys
--------------------------------------------------------------------------------
CREATE TABLE test_data.no_pk_table (
    id INTEGER,
    name TEXT,
    created_at TIMESTAMP DEFAULT now()
);

CREATE TABLE test_data.another_no_pk (
    col1 TEXT,
    col2 TEXT
);

INSERT INTO test_data.no_pk_table (id, name)
SELECT g, 'row_' || g FROM generate_series(1, 100) g;

--------------------------------------------------------------------------------
-- CRITICAL: Unused Large Index (>100MB, 0 scans)
-- NOTE: Requires ~2-3M rows to generate 100MB+ index
--------------------------------------------------------------------------------
CREATE TABLE test_data.big_indexed_table (
    id SERIAL PRIMARY KEY,
    data_col TEXT,
    indexed_col VARCHAR(100),
    padding TEXT
);

-- Generate enough data for a 100MB+ index
-- Each row with padding ~500 bytes, need ~200k rows for table, index on varchar(100)
-- with ~2M rows should exceed 100MB
INSERT INTO test_data.big_indexed_table (data_col, indexed_col, padding)
SELECT
    'data_' || g,
    'indexed_value_' || (g % 10000)::text || '_' || repeat('x', 50),
    repeat('p', 400)
FROM generate_series(1, 2500000) g;

-- Create index that will never be used (exceeds 100MB threshold)
CREATE INDEX idx_unused_large ON test_data.big_indexed_table (indexed_col);

-- Reset stats so the index shows 0 scans
SELECT pg_stat_reset();

--------------------------------------------------------------------------------
-- HIGH: Table Bloat (>50%)
-- Create bloat by inserting then deleting most rows without VACUUM
--------------------------------------------------------------------------------
CREATE TABLE test_data.bloated_table (
    id SERIAL PRIMARY KEY,
    data TEXT,
    status INTEGER
);

-- Insert rows
INSERT INTO test_data.bloated_table (data, status)
SELECT repeat('bloat_data_', 10) || g, g % 10
FROM generate_series(1, 100000) g;

-- Analyze to get baseline stats
ANALYZE test_data.bloated_table;

-- Delete 80% of rows to create bloat
DELETE FROM test_data.bloated_table WHERE id % 5 != 0;

-- Update remaining rows to fragment pages further
UPDATE test_data.bloated_table SET data = repeat('updated_', 20) || id;

--------------------------------------------------------------------------------
-- HIGH: Missing Statistics (never analyzed, >1000 modifications)
--------------------------------------------------------------------------------
CREATE TABLE test_data.never_analyzed (
    id SERIAL PRIMARY KEY,
    value TEXT,
    category INTEGER
);

-- Insert >1000 rows without running ANALYZE
INSERT INTO test_data.never_analyzed (value, category)
SELECT 'value_' || g, g % 100
FROM generate_series(1, 5000) g;

-- Ensure no analyze runs (stats show last_analyze = NULL)
-- Note: autovacuum might analyze this eventually in a real system

--------------------------------------------------------------------------------
-- HIGH: Duplicate Indexes
--------------------------------------------------------------------------------
CREATE TABLE test_data.duplicate_idx_table (
    id SERIAL PRIMARY KEY,
    email VARCHAR(255),
    username VARCHAR(100)
);

-- Create duplicate indexes on the same column
CREATE INDEX idx_email_1 ON test_data.duplicate_idx_table (email);
CREATE INDEX idx_email_2 ON test_data.duplicate_idx_table (email);

-- Another duplicate pair
CREATE INDEX idx_username_a ON test_data.duplicate_idx_table (username);
CREATE INDEX idx_username_b ON test_data.duplicate_idx_table (username);

--------------------------------------------------------------------------------
-- HIGH: Table with more than 200 columns
--------------------------------------------------------------------------------
DO $$
DECLARE
    col_sql TEXT := 'CREATE TABLE test_data.wide_table_200 (id SERIAL PRIMARY KEY';
    i INTEGER;
BEGIN
    FOR i IN 1..220 LOOP
        col_sql := col_sql || ', col_' || i || ' TEXT';
    END LOOP;
    col_sql := col_sql || ')';
    EXECUTE col_sql;
END $$;

INSERT INTO test_data.wide_table_200 (col_1, col_2, col_3)
VALUES ('a', 'b', 'c');

--------------------------------------------------------------------------------
-- MEDIUM: Tables with 50-199 columns
--------------------------------------------------------------------------------
DO $$
DECLARE
    col_sql TEXT := 'CREATE TABLE test_data.wide_table_75 (id SERIAL PRIMARY KEY';
    i INTEGER;
BEGIN
    FOR i IN 1..75 LOOP
        col_sql := col_sql || ', field_' || i || ' VARCHAR(50)';
    END LOOP;
    col_sql := col_sql || ')';
    EXECUTE col_sql;
END $$;

DO $$
DECLARE
    col_sql TEXT := 'CREATE TABLE test_data.wide_table_150 (id SERIAL PRIMARY KEY';
    i INTEGER;
BEGIN
    FOR i IN 1..150 LOOP
        col_sql := col_sql || ', attr_' || i || ' INTEGER';
    END LOOP;
    col_sql := col_sql || ')';
    EXECUTE col_sql;
END $$;

--------------------------------------------------------------------------------
-- LOW: Missing Foreign Key Indexes
--------------------------------------------------------------------------------
CREATE TABLE test_data.parent_table (
    id SERIAL PRIMARY KEY,
    name TEXT
);

CREATE TABLE test_data.child_no_fk_idx (
    id SERIAL PRIMARY KEY,
    parent_id INTEGER REFERENCES test_data.parent_table(id),
    data TEXT
);
-- Note: No index on parent_id - triggers "Missing FK Index" check

CREATE TABLE test_data.another_child (
    id SERIAL PRIMARY KEY,
    parent_id INTEGER REFERENCES test_data.parent_table(id),
    other_parent_id INTEGER REFERENCES test_data.parent_table(id),
    value TEXT
);
-- Two FK columns without indexes

INSERT INTO test_data.parent_table (name) VALUES ('parent1'), ('parent2'), ('parent3');
INSERT INTO test_data.child_no_fk_idx (parent_id, data) VALUES (1, 'child_data');
INSERT INTO test_data.another_child (parent_id, other_parent_id, value) VALUES (1, 2, 'test');

--------------------------------------------------------------------------------
-- LOW: Tables with 0 or 1 columns
--------------------------------------------------------------------------------
CREATE TABLE test_data.zero_column_table ();

CREATE TABLE test_data.single_column_table (
    only_col TEXT
);

INSERT INTO test_data.single_column_table VALUES ('lonely');

--------------------------------------------------------------------------------
-- LOW: Empty Tables
--------------------------------------------------------------------------------
CREATE TABLE test_data.empty_table_1 (
    id SERIAL PRIMARY KEY,
    data TEXT
);

CREATE TABLE test_data.empty_table_2 (
    id INTEGER,
    name VARCHAR(100),
    created_at TIMESTAMP
);

-- Analyze to confirm they're empty
ANALYZE test_data.empty_table_1;
ANALYZE test_data.empty_table_2;

--------------------------------------------------------------------------------
-- LOW: Roles that have never logged in
--------------------------------------------------------------------------------
-- Create roles with LOGIN privilege that will never connect
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'test_unused_role') THEN
        CREATE ROLE test_unused_role WITH LOGIN PASSWORD 'test123';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'abandoned_user') THEN
        CREATE ROLE abandoned_user WITH LOGIN PASSWORD 'abandoned123';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'old_service_account') THEN
        CREATE ROLE old_service_account WITH LOGIN PASSWORD 'oldservice123';
    END IF;
END $$;

--------------------------------------------------------------------------------
-- LOW: Index with very low usage (1-99 scans, >1MB)
-- NOTE: Requires manual query execution to register scans in stats
--------------------------------------------------------------------------------
CREATE TABLE test_data.low_usage_idx_table (
    id SERIAL PRIMARY KEY,
    searchable TEXT,
    payload TEXT
);

INSERT INTO test_data.low_usage_idx_table (searchable, payload)
SELECT
    'search_term_' || (g % 1000),
    repeat('x', 1000)
FROM generate_series(1, 50000) g;

CREATE INDEX idx_low_usage ON test_data.low_usage_idx_table (searchable);

-- To trigger this check, run a few queries that use the index:
-- SELECT * FROM test_data.low_usage_idx_table WHERE searchable = 'search_term_42';
-- (Repeat 10-50 times to get into the 1-99 scan range)

--------------------------------------------------------------------------------
-- Additional test data for stats-based checks
-- These need manual steps to trigger
--------------------------------------------------------------------------------

-- For MEDIUM: Outdated Statistics check
-- After creating, run many updates without ANALYZE:
CREATE TABLE test_data.outdated_stats_table (
    id SERIAL PRIMARY KEY,
    counter INTEGER,
    data TEXT
);

INSERT INTO test_data.outdated_stats_table (counter, data)
SELECT g, 'initial_' || g FROM generate_series(1, 10000) g;

ANALYZE test_data.outdated_stats_table;

-- Run these UPDATE statements to exceed autovacuum thresholds:
-- UPDATE test_data.outdated_stats_table SET counter = counter + 1;
-- DELETE FROM test_data.outdated_stats_table WHERE id % 10 = 0;
-- (This creates dead tuples and modifications that exceed thresholds)

-- For MEDIUM: Low Index Efficiency check
-- Needs index with scans >100 and tuple read ratio >1000
CREATE TABLE test_data.poor_selectivity (
    id SERIAL PRIMARY KEY,
    category INTEGER,  -- low cardinality column
    data TEXT
);

INSERT INTO test_data.poor_selectivity (category, data)
SELECT
    g % 5,  -- only 5 distinct values
    repeat('data', 100)
FROM generate_series(1, 500000) g;

CREATE INDEX idx_poor_selectivity ON test_data.poor_selectivity (category);

-- To trigger, run queries that use this index repeatedly:
-- SELECT count(*) FROM test_data.poor_selectivity WHERE category = 1;
-- (Each scan returns ~100k rows, ratio will exceed 1000 threshold)

-- For MEDIUM: Excessive Sequential Scans check
-- Needs seq_scan >1000 and seq_tup_read > seq_scan * 10000
CREATE TABLE test_data.seq_scan_heavy (
    id SERIAL PRIMARY KEY,
    unindexed_col TEXT,
    data TEXT
);

INSERT INTO test_data.seq_scan_heavy (unindexed_col, data)
SELECT 'value_' || g, repeat('x', 100)
FROM generate_series(1, 100000) g;

-- No index on unindexed_col, queries will seq scan
-- To trigger: run 1000+ queries like:
-- SELECT * FROM test_data.seq_scan_heavy WHERE unindexed_col = 'value_42';

COMMIT;

--------------------------------------------------------------------------------
-- Summary of what each check needs
--------------------------------------------------------------------------------
/*
CHECKS TRIGGERED BY SCHEMA/DATA ALONE:
  - CRITICAL: Missing Primary Key (no_pk_table, another_no_pk)
  - HIGH: Duplicate Indexes (duplicate_idx_table)
  - HIGH: Table >200 columns (wide_table_200)
  - MEDIUM: Table 50-199 columns (wide_table_75, wide_table_150)
  - LOW: Missing FK Index (child_no_fk_idx, another_child)
  - LOW: Tables with 0-1 columns (zero_column_table, single_column_table)
  - LOW: Empty Tables (empty_table_1, empty_table_2)
  - LOW: Roles never logged in (test_unused_role, abandoned_user, old_service_account)

CHECKS REQUIRING ADDITIONAL STEPS:
  - CRITICAL: Unused Large Index
      → Wait for stats reset, do NOT query big_indexed_table via idx_unused_large

  - HIGH: Table Bloat
      → May need to wait or check bloat calculation; VACUUM disables this check

  - HIGH: Missing Statistics
      → Ensure autovacuum doesn't analyze never_analyzed table

  - MEDIUM: Outdated Statistics
      → Run UPDATE/DELETE on outdated_stats_table without ANALYZE

  - MEDIUM: Low Index Efficiency
      → Run 100+ queries: SELECT * FROM poor_selectivity WHERE category = 1;

  - MEDIUM: Excessive Sequential Scans
      → Run 1000+ queries: SELECT * FROM seq_scan_heavy WHERE unindexed_col = 'value_X';

  - LOW: Index with Low Usage
      → Run 10-99 queries using idx_low_usage

CHECKS NOT COVERED (per user request):
  - Tables >50GB / >100GB (resource intensive)
  - Long Running Queries (runtime)
  - Blocked/Blocking Queries (runtime)
  - High Connection Count (runtime)
  - Idle Connections >1 hour (runtime)
  - Replication Slots (requires replication setup)
  - Tables with no activity (requires stats timing)
*/

-- Verify test data was created
SELECT 'Test tables created:' AS status;
SELECT schemaname, tablename
FROM pg_tables
WHERE schemaname = 'test_data'
ORDER BY tablename;

SELECT 'Test indexes created:' AS status;
SELECT schemaname, indexname, tablename
FROM pg_indexes
WHERE schemaname = 'test_data'
ORDER BY indexname;

SELECT 'Test roles created:' AS status;
SELECT rolname, rolcanlogin
FROM pg_roles
WHERE rolname IN ('test_unused_role', 'abandoned_user', 'old_service_account');
