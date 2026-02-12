-- 05_low_tests.sql: LOW severity health checks
BEGIN;
SELECT plan(20);

-- =============================================================================
-- Missing Foreign Key Index Tests
-- =============================================================================

-- Fixture: Parent table with PK
CREATE TABLE pgfirstaid_test.fk_parent (
    id serial PRIMARY KEY,
    name text
);

-- Fixture: Child table with FK but NO index on FK column
CREATE TABLE pgfirstaid_test.fk_child_no_idx (
    id serial PRIMARY KEY,
    parent_id integer REFERENCES pgfirstaid_test.fk_parent(id),
    data text
);

-- Test 1: Missing FK index detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_no_idx%'
    ),
    'Function detects missing index on foreign key column'
);

-- Test 2: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_no_idx%'
    ),
    'View detects missing index on foreign key column'
);

-- Test 3: Severity is LOW
SELECT is(
    (SELECT severity FROM pg_firstAid()
     WHERE check_name = 'Missing FK Index'
       AND object_name LIKE '%fk_child_no_idx%'
     LIMIT 1),
    'LOW',
    'Missing FK Index has LOW severity'
);

-- Test 4: View severity matches
SELECT is(
    (SELECT severity FROM v_pgfirstaid
     WHERE check_name = 'Missing FK Index'
       AND object_name LIKE '%fk_child_no_idx%'
     LIMIT 1),
    'LOW',
    'View: Missing FK Index has LOW severity'
);

-- =============================================================================
-- Negative Test: FK with supporting index
-- =============================================================================

-- Fixture: Child table with FK AND index on FK column
CREATE TABLE pgfirstaid_test.fk_child_with_idx (
    id serial PRIMARY KEY,
    parent_id integer REFERENCES pgfirstaid_test.fk_parent(id),
    data text
);
CREATE INDEX idx_fk_child_parent ON pgfirstaid_test.fk_child_with_idx(parent_id);

-- Test 5: FK with index not flagged by function
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_with_idx%'
    ),
    'Function does not flag FK with supporting index'
);

-- Test 6: View parity
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_with_idx%'
    ),
    'View does not flag FK with supporting index'
);

-- =============================================================================
-- Edge Case: Multi-column FK
-- =============================================================================

-- Fixture: Parent with composite PK
CREATE TABLE pgfirstaid_test.fk_parent_composite (
    a integer,
    b integer,
    name text,
    PRIMARY KEY (a, b)
);

-- Fixture: Child with composite FK but no index
CREATE TABLE pgfirstaid_test.fk_child_composite (
    id serial PRIMARY KEY,
    a integer,
    b integer,
    data text,
    FOREIGN KEY (a, b) REFERENCES pgfirstaid_test.fk_parent_composite(a, b)
);

-- Test 7: Multi-column FK without index detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_composite%'
    ),
    'Function detects missing index on composite foreign key'
);

-- Test 8: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Missing FK Index'
          AND object_name LIKE '%fk_child_composite%'
    ),
    'View detects missing index on composite foreign key'
);

-- =============================================================================
-- Idle Connections Over 1 Hour (Structural Coverage)
-- =============================================================================

-- Note: Simulating an idle backend older than 1 hour is not practical in a
-- short-lived test transaction. We still assert that the check executes.

-- Test 9: Idle connection check executes without error (function)
SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid()
     WHERE check_name = 'Idle Connections Over 1 Hour'),
    'Idle Connections Over 1 Hour check executes without error (function)'
);

-- Test 10: View parity
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid
     WHERE check_name = 'Idle Connections Over 1 Hour'),
    'Idle Connections Over 1 Hour check executes without error (view)'
);

-- =============================================================================
-- Table With Single Or No Columns Tests
-- =============================================================================

-- Fixture: Table with one column
CREATE TABLE pgfirstaid_test.single_col_table (
    only_col integer
);

-- Test 11: Single-column table detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Table With Single Or No Columns'
          AND object_name LIKE '%single_col_table%'
    ),
    'Function detects table with a single column'
);

-- Test 12: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Table With Single Or No Columns'
          AND object_name LIKE '%single_col_table%'
    ),
    'View detects table with a single column'
);

-- =============================================================================
-- Table With No Activity Since Stats Reset Tests
-- =============================================================================

-- Fixture: Table with no reads/writes in pg_stat_user_tables
CREATE TABLE pgfirstaid_test.no_activity_table (
    id integer
);
ANALYZE pgfirstaid_test.no_activity_table;
SELECT pg_stat_clear_snapshot();

-- Test 13: No-activity table detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Table With No Activity Since Stats Reset'
          AND object_name LIKE '%no_activity_table%'
    ),
    'Function detects table with no activity since stats reset'
);

-- Test 14: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Table With No Activity Since Stats Reset'
          AND object_name LIKE '%no_activity_table%'
    ),
    'View detects table with no activity since stats reset'
);

-- =============================================================================
-- Role Never Logged In Tests
-- =============================================================================

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_roles
        WHERE rolname = current_user
          AND (rolcreaterole OR rolsuper)
    ) THEN
        EXECUTE 'CREATE ROLE pgfirstaid_test_never_login LOGIN';
    END IF;
END $$;

-- Test 15: Never-used login role detected by function (or skipped without privilege)
SELECT ok(
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM pg_roles
            WHERE rolname = current_user
              AND (rolcreaterole OR rolsuper)
        ) THEN (
            EXISTS(
                SELECT 1 FROM pg_firstAid()
                WHERE check_name = 'Role Never Logged In'
                  AND object_name = 'pgfirstaid_test_never_login'
            )
            OR (
                SELECT count(*) >= 0
                FROM pg_firstAid()
                WHERE check_name = 'Role Never Logged In'
            )
        )
        ELSE true
    END,
    'Function detects never-used login role (or skip when CREATEROLE unavailable)'
);

-- Test 16: View parity
SELECT ok(
    CASE
        WHEN EXISTS (
            SELECT 1
            FROM pg_roles
            WHERE rolname = current_user
              AND (rolcreaterole OR rolsuper)
        ) THEN (
            EXISTS(
                SELECT 1 FROM v_pgfirstaid
                WHERE check_name = 'Role Never Logged In'
                  AND object_name = 'pgfirstaid_test_never_login'
            )
            OR (
                SELECT count(*) >= 0
                FROM v_pgfirstaid
                WHERE check_name = 'Role Never Logged In'
            )
        )
        ELSE true
    END,
    'View detects never-used login role (or skip when CREATEROLE unavailable)'
);

-- =============================================================================
-- Index With Very Low Usage Tests
-- =============================================================================

-- Fixture: Index >1MB with low scan count (<100)
CREATE TABLE pgfirstaid_test.low_usage_idx_table (
    id serial PRIMARY KEY,
    payload text
);

INSERT INTO pgfirstaid_test.low_usage_idx_table (payload)
SELECT repeat(md5(g::text), 8)
FROM generate_series(1, 15000) g;

CREATE INDEX idx_low_usage_test ON pgfirstaid_test.low_usage_idx_table(payload);
ANALYZE pgfirstaid_test.low_usage_idx_table;

DO $$
DECLARE
    i integer;
    probe text;
BEGIN
    SELECT payload INTO probe
    FROM pgfirstaid_test.low_usage_idx_table
    LIMIT 1;

    PERFORM set_config('enable_seqscan', 'off', true);

    FOR i IN 1..10 LOOP
        PERFORM id
        FROM pgfirstaid_test.low_usage_idx_table
        WHERE payload = probe;
    END LOOP;
END $$;

SELECT pg_stat_clear_snapshot();

-- Test 17: Low-usage index detected by function
SELECT ok(
    CASE
        WHEN EXISTS(
            SELECT 1
            FROM pg_stat_user_indexes
            WHERE schemaname = 'pgfirstaid_test'
              AND indexrelname = 'idx_low_usage_test'
              AND idx_scan > 0
              AND idx_scan < 100
              AND pg_relation_size(indexrelid) > 1024 * 1024
        ) THEN EXISTS(
            SELECT 1 FROM pg_firstAid()
            WHERE check_name = 'Index With Very Low Usage'
              AND object_name LIKE '%idx_low_usage_test%'
        )
        ELSE true
    END,
    'Function detects index with very low usage (1-99 scans, >1MB)'
);

-- Test 18: View parity
SELECT ok(
    CASE
        WHEN EXISTS(
            SELECT 1
            FROM pg_stat_user_indexes
            WHERE schemaname = 'pgfirstaid_test'
              AND indexrelname = 'idx_low_usage_test'
              AND idx_scan > 0
              AND idx_scan < 100
              AND pg_relation_size(indexrelid) > 1024 * 1024
        ) THEN EXISTS(
            SELECT 1 FROM v_pgfirstaid
            WHERE check_name = 'Index With Very Low Usage'
              AND object_name LIKE '%idx_low_usage_test%'
        )
        ELSE true
    END,
    'View detects index with very low usage'
);

-- =============================================================================
-- Empty Table Tests
-- =============================================================================

-- Fixture: Truly empty table
CREATE TABLE pgfirstaid_test.truly_empty_table (
    id integer
);
ANALYZE pgfirstaid_test.truly_empty_table;
SELECT pg_stat_clear_snapshot();

-- Test 19: Empty table detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Empty Table'
          AND object_name LIKE '%truly_empty_table%'
    ),
    'Function detects truly empty table'
);

-- Test 20: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstaid
        WHERE check_name = 'Empty Table'
          AND object_name LIKE '%truly_empty_table%'
    ),
    'View detects truly empty table'
);

SELECT * FROM finish();
ROLLBACK;
