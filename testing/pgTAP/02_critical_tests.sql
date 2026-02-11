-- 02_critical_tests.sql: CRITICAL severity health checks
BEGIN;
SELECT plan(8);

-- =============================================================================
-- Missing Primary Key Tests
-- =============================================================================

-- Fixture: Table without a primary key
CREATE TABLE pgfirstaid_test.no_pk_table (
    id integer,
    name text
);

-- Fixture: Table with a primary key (negative test)
CREATE TABLE pgfirstaid_test.has_pk_table (
    id integer PRIMARY KEY,
    name text
);

-- Test 1: Table without PK detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing Primary Key'
          AND object_name LIKE '%no_pk_table%'
    ),
    'Function detects table without primary key'
);

-- Test 2: Table with PK not flagged by function
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing Primary Key'
          AND object_name LIKE '%has_pk_table%'
    ),
    'Function does not flag table with primary key'
);

-- Test 3: View parity - table without PK detected
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Missing Primary Key'
          AND object_name LIKE '%no_pk_table%'
    ),
    'View detects table without primary key'
);

-- Test 4: View parity - table with PK not flagged
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Missing Primary Key'
          AND object_name LIKE '%has_pk_table%'
    ),
    'View does not flag table with primary key'
);

-- =============================================================================
-- Unused Large Index Tests
-- =============================================================================

-- Fixture: Large table with unused index (>100MB)
-- Need ~3 million rows with wide-ish data to push index over 100MB
CREATE TABLE pgfirstaid_test.large_idx_table (
    id bigint,
    data text
);

-- Insert enough rows to create a >100MB index
INSERT INTO pgfirstaid_test.large_idx_table
SELECT g, md5(g::text) || md5((g+1)::text)
FROM generate_series(1, 3000000) g;

-- Create index (will be >100MB with 3M rows of bigint)
CREATE INDEX idx_large_unused ON pgfirstaid_test.large_idx_table(id);

-- Force stats update so pg_relation_size reports correctly
ANALYZE pgfirstaid_test.large_idx_table;

-- Test 5: Large unused index detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Unused Large Index'
          AND object_name LIKE '%idx_large_unused%'
    ),
    'Function detects large unused index (>100MB, 0 scans)'
);

-- Test 6: View parity - large unused index detected
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Unused Large Index'
          AND object_name LIKE '%idx_large_unused%'
    ),
    'View detects large unused index'
);

-- Fixture: Small table with small index (negative test)
CREATE TABLE pgfirstaid_test.small_idx_table (
    id integer PRIMARY KEY,
    name text
);
INSERT INTO pgfirstaid_test.small_idx_table VALUES (1, 'test');

-- Test 7: Small index not flagged by function
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Unused Large Index'
          AND object_name LIKE '%small_idx_table%'
    ),
    'Function does not flag small unused index'
);

-- Test 8: Small index not flagged by view
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Unused Large Index'
          AND object_name LIKE '%small_idx_table%'
    ),
    'View does not flag small unused index'
);

SELECT * FROM finish();
ROLLBACK;
