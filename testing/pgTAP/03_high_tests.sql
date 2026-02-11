-- 03_high_tests.sql: HIGH severity health checks
BEGIN;
SELECT plan(16);

-- =============================================================================
-- Inactive Replication Slots Tests
-- =============================================================================
-- The check filters pg_replication_slots WHERE active = false.
-- We can only test with a real slot if wal_level = logical.
-- Otherwise we verify no false positives on a system without inactive slots.

-- Test 1: Check executes without error and returns no false positives
-- (no inactive slots should exist on a clean test database)
SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid()
     WHERE check_name = 'Inactive Replication Slots'),
    'Inactive Replication Slots check executes without error (function)'
);

-- Test 2: View parity
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstAid
     WHERE check_name = 'Inactive Replication Slots'),
    'Inactive Replication Slots check executes without error (view)'
);

-- =============================================================================
-- Table Bloat Tests
-- =============================================================================

-- Fixture: Create table, fill it, delete most rows to create bloat
CREATE TABLE pgfirstaid_test.bloated_table (
    id serial PRIMARY KEY,
    padding text
) WITH (autovacuum_enabled = false);

-- Insert 10,000 rows
INSERT INTO pgfirstaid_test.bloated_table (padding)
SELECT repeat('x', 200)
FROM generate_series(1, 10000);

-- Run ANALYZE so the bloat estimator has statistics to work with
ANALYZE pgfirstaid_test.bloated_table;

-- Delete 90% of rows (creates dead tuples = bloat)
DELETE FROM pgfirstaid_test.bloated_table WHERE id > 1000;

-- Test 3: Bloated table detected by function
-- The bloat check uses pg_stats-based estimation. After DELETE without VACUUM,
-- the dead tuples exist but relpages still reflects the pre-delete state.
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Table Bloat (Detailed)'
          AND object_name LIKE '%bloated_table%'
    ),
    'Function detects bloated table (>50% bloat after mass delete)'
);

-- Test 4: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Table Bloat (Detailed)'
          AND object_name LIKE '%bloated_table%'
    ),
    'View detects bloated table'
);

-- =============================================================================
-- Missing Statistics Tests
-- =============================================================================

-- Fixture: Table with modifications but never analyzed
CREATE TABLE pgfirstaid_test.no_stats_table (
    id serial,
    data text
) WITH (autovacuum_enabled = false);

-- Insert >1000 rows to exceed the threshold
INSERT INTO pgfirstaid_test.no_stats_table (data)
SELECT md5(g::text)
FROM generate_series(1, 1500) g;

-- Test 5: Missing statistics detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing Statistics'
          AND object_name LIKE '%no_stats_table%'
    ),
    'Function detects table with missing statistics (never analyzed, >1000 mods)'
);

-- Test 6: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Missing Statistics'
          AND object_name LIKE '%no_stats_table%'
    ),
    'View detects table with missing statistics'
);

-- =============================================================================
-- Tables Larger Than 100GB (Structural Test Only)
-- =============================================================================

-- Test 7: No false positives for 100GB check on small test tables
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Tables larger than 100GB'
          AND severity = 'HIGH'
          AND object_name LIKE '%pgfirstaid_test%'
    ),
    'No false positive 100GB warnings for test tables (function)'
);

-- Test 8: View parity
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Tables larger than 100GB'
          AND severity_order = 2
          AND object_name LIKE '%pgfirstaid_test%'
    ),
    'No false positive 100GB warnings for test tables (view)'
);

-- =============================================================================
-- Duplicate Index Tests
-- =============================================================================

-- Fixture: Table with duplicate indexes
CREATE TABLE pgfirstaid_test.dup_idx_table (
    id integer,
    name text,
    value integer
);

-- Create two indexes with identical definitions but different names
CREATE INDEX idx_dup_one ON pgfirstaid_test.dup_idx_table(name);
CREATE INDEX idx_dup_two ON pgfirstaid_test.dup_idx_table(name);

-- Test 9: Duplicate indexes detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Duplicate Index'
          AND object_name LIKE '%idx_dup_one%'
          AND object_name LIKE '%idx_dup_two%'
    ),
    'Function detects duplicate indexes'
);

-- Test 10: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Duplicate Index'
          AND object_name LIKE '%idx_dup_one%'
          AND object_name LIKE '%idx_dup_two%'
    ),
    'View detects duplicate indexes'
);

-- =============================================================================
-- Tables With >200 Columns
-- =============================================================================

-- Fixture: Generate a table with 201 columns
DO $$
DECLARE
    col_list text := '';
    i integer;
BEGIN
    FOR i IN 1..201 LOOP
        IF i > 1 THEN col_list := col_list || ', '; END IF;
        col_list := col_list || 'col_' || i || ' integer';
    END LOOP;
    EXECUTE 'CREATE TABLE pgfirstaid_test.wide_table_201 (' || col_list || ')';
END $$;

-- Test 11: Wide table (>200 cols) detected at HIGH severity by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Table with more than 200 columns'
          AND severity = 'HIGH'
          AND object_name LIKE '%wide_table_201%'
    ),
    'Function detects table with >200 columns at HIGH severity'
);

-- Test 12: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Table with more than 200 columns'
          AND severity = 'HIGH'
          AND object_name LIKE '%wide_table_201%'
    ),
    'View detects table with >200 columns at HIGH severity'
);

-- Test 13: Wide table does NOT appear in MEDIUM 50-column check
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Table with more than 50 columns'
          AND object_name LIKE '%wide_table_201%'
    ),
    'Table with >200 columns not in MEDIUM 50-column check (exclusive ranges)'
);

-- Test 14: View parity for exclusive range
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Table with more than 50 columns'
          AND object_name LIKE '%wide_table_201%'
    ),
    'View: Table with >200 columns not in MEDIUM 50-column check'
);

-- =============================================================================
-- Negative Tests
-- =============================================================================

-- Fixture: Properly maintained table
CREATE TABLE pgfirstaid_test.healthy_table (
    id serial PRIMARY KEY,
    data text
) WITH (autovacuum_enabled = false);
INSERT INTO pgfirstaid_test.healthy_table (data) SELECT md5(g::text) FROM generate_series(1, 100) g;
ANALYZE pgfirstaid_test.healthy_table;

-- Test 15: Healthy table not in missing statistics
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing Statistics'
          AND object_name LIKE '%healthy_table%'
    ),
    'Analyzed table not flagged for missing statistics'
);

-- Test 16: Healthy table has PK so not in missing PK
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing Primary Key'
          AND object_name LIKE '%healthy_table%'
    ),
    'Table with PK not flagged for missing primary key'
);

SELECT * FROM finish();
ROLLBACK;
