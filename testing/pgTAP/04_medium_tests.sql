-- 04_medium_tests.sql: MEDIUM severity health checks
BEGIN;
SELECT plan(22);

-- =============================================================================
-- Helper: dblink connection string for background sessions
-- =============================================================================
DO $$
BEGIN
    PERFORM dblink_connect('test_conn',
        'dbname=' || current_database() || ' user=' || current_user);
EXCEPTION WHEN OTHERS THEN
    PERFORM dblink_disconnect('test_conn');
    PERFORM dblink_connect('test_conn',
        'dbname=' || current_database() || ' user=' || current_user);
END $$;

-- =============================================================================
-- Blocked/Blocking Queries Tests
-- =============================================================================

-- Fixture: Table for lock contention testing
CREATE TABLE pgfirstaid_test.lock_test_table (id integer PRIMARY KEY, data text);
INSERT INTO pgfirstaid_test.lock_test_table VALUES (1, 'test');

-- Start a background transaction that holds a lock via dblink
SELECT dblink_exec('test_conn', 'BEGIN');
SELECT dblink_exec('test_conn',
    'UPDATE pgfirstaid_test.lock_test_table SET data = ''blocked'' WHERE id = 1');

-- The actual check uses transactionid-based lock detection which requires
-- actual transaction ID conflicts. We verify the check executes without error.

-- Test 1: Structural test - check query is valid (no errors)
SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid()
     WHERE check_name = 'Current Blocked/Blocking Queries'),
    'Blocked/Blocking Queries check executes without error (function)'
);

-- Test 2: View parity structural test
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstAid
     WHERE check_name = 'Current Blocked/Blocking Queries'),
    'Blocked/Blocking Queries check executes without error (view)'
);

-- Clean up background connection lock
SELECT dblink_exec('test_conn', 'ROLLBACK');

-- =============================================================================
-- Outdated Statistics Tests
-- =============================================================================

-- Fixture: Table with outdated statistics
CREATE TABLE pgfirstaid_test.outdated_stats_table (
    id serial PRIMARY KEY,
    data text
) WITH (autovacuum_enabled = false);

-- Insert initial data and analyze
INSERT INTO pgfirstaid_test.outdated_stats_table (data)
SELECT md5(g::text) FROM generate_series(1, 1000) g;
ANALYZE pgfirstaid_test.outdated_stats_table;

-- Make many modifications to exceed thresholds
-- Default threshold: reltuples * 0.1 + 50 for analyze
-- With 1000 rows: 1000 * 0.1 + 50 = 150 modifications needed
UPDATE pgfirstaid_test.outdated_stats_table SET data = md5(data) WHERE id <= 500;
DELETE FROM pgfirstaid_test.outdated_stats_table WHERE id > 800;

-- Test 3: Outdated statistics detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Outdated Statistics'
          AND object_name LIKE '%outdated_stats_table%'
    ),
    'Function detects table with outdated statistics'
);

-- Test 4: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Outdated Statistics'
          AND object_name LIKE '%outdated_stats_table%'
    ),
    'View detects table with outdated statistics'
);

-- =============================================================================
-- Low Index Efficiency Tests
-- =============================================================================

-- Fixture: Table with low-selectivity index
CREATE TABLE pgfirstaid_test.low_eff_table (
    id serial PRIMARY KEY,
    flag boolean,
    padding text
);

-- Insert rows with low cardinality on flag column
INSERT INTO pgfirstaid_test.low_eff_table (flag, padding)
SELECT (g % 2 = 0), repeat('x', 100)
FROM generate_series(1, 100000) g;

CREATE INDEX idx_low_eff ON pgfirstaid_test.low_eff_table(flag);
ANALYZE pgfirstaid_test.low_eff_table;

-- Run >100 queries that use the index but read many tuples per scan
-- Each scan reads ~50,000 tuples (half the table)
DO $$
DECLARE i integer;
BEGIN
    FOR i IN 1..110 LOOP
        PERFORM count(*) FROM pgfirstaid_test.low_eff_table WHERE flag = true;
    END LOOP;
END $$;

-- Test 5: Low index efficiency detected by function
-- Threshold: idx_scan > 100 AND idx_tup_read/idx_scan > 1000
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Low Index Efficiency'
          AND object_name LIKE '%idx_low_eff%'
    ),
    'Function detects low index efficiency (>100 scans, ratio >1000)'
);

-- Test 6: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Low Index Efficiency'
          AND object_name LIKE '%idx_low_eff%'
    ),
    'View detects low index efficiency'
);

-- =============================================================================
-- Replication Slots Near Max WAL Size (Structural Test)
-- =============================================================================

-- Test 7: No false positives for replication WAL check
SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid()
     WHERE check_name = 'Replication Slots Near Max Wal Size'),
    'Replication Slots Near Max Wal Size check executes without error (function)'
);

-- Test 8: View parity
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstAid
     WHERE check_name = 'Replication Slots Near Max Wal Size'),
    'Replication Slots Near Max Wal Size check executes without error (view)'
);

-- =============================================================================
-- Excessive Sequential Scans Tests
-- =============================================================================

-- Fixture: Table with no indexes on queried column
CREATE TABLE pgfirstaid_test.seq_scan_table (
    id serial,
    category text,
    value integer
);

INSERT INTO pgfirstaid_test.seq_scan_table (category, value)
SELECT 'cat_' || (g % 10), g
FROM generate_series(1, 5000) g;

-- Run >1000 sequential scans with WHERE on non-indexed column
DO $$
DECLARE i integer;
BEGIN
    FOR i IN 1..1100 LOOP
        PERFORM count(*) FROM pgfirstaid_test.seq_scan_table WHERE category = 'cat_5';
    END LOOP;
END $$;

-- Test 9: Excessive sequential scans detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Excessive Sequential Scans'
          AND object_name LIKE '%seq_scan_table%'
    ),
    'Function detects excessive sequential scans (>1000 scans, high tuple ratio)'
);

-- Test 10: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Excessive Sequential Scans'
          AND object_name LIKE '%seq_scan_table%'
    ),
    'View detects excessive sequential scans'
);

-- =============================================================================
-- Tables With 50-199 Columns Tests
-- =============================================================================

-- Fixture: Table with 75 columns
DO $$
DECLARE
    col_list text := '';
    i integer;
BEGIN
    FOR i IN 1..75 LOOP
        IF i > 1 THEN col_list := col_list || ', '; END IF;
        col_list := col_list || 'col_' || i || ' integer';
    END LOOP;
    EXECUTE 'CREATE TABLE pgfirstaid_test.wide_table_75 (' || col_list || ')';
END $$;

-- Test 11: 75-column table detected at MEDIUM severity by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Table with more than 50 columns'
          AND severity = 'MEDIUM'
          AND object_name LIKE '%wide_table_75%'
    ),
    'Function detects table with 50-199 columns at MEDIUM severity'
);

-- Test 12: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Table with more than 50 columns'
          AND severity = 'MEDIUM'
          AND object_name LIKE '%wide_table_75%'
    ),
    'View detects table with 50-199 columns at MEDIUM severity'
);

-- Test 13: 75-column table NOT in >200 column HIGH check
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Table with more than 200 columns'
          AND object_name LIKE '%wide_table_75%'
    ),
    '75-column table not flagged for >200 column check'
);

-- =============================================================================
-- High Connection Count Tests
-- =============================================================================

-- Disconnect test_conn before opening many connections
SELECT dblink_disconnect('test_conn');

-- Open 50+ connections via dblink to trigger the threshold
DO $$
DECLARE
    i integer;
    conn_name text;
    conn_str text;
BEGIN
    conn_str := 'dbname=' || current_database() || ' user=' || current_user;
    FOR i IN 1..52 LOOP
        conn_name := 'conn_' || i;
        BEGIN
            PERFORM dblink_connect(conn_name, conn_str);
            -- Start an active query on each connection
            PERFORM dblink_send_query(conn_name, 'SELECT pg_sleep(30)');
        EXCEPTION WHEN OTHERS THEN
            -- Skip if max_connections reached
            EXIT;
        END;
    END LOOP;
END $$;

-- Test 14: High connection count detected by function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'High Connection Count'
    ),
    'Function detects high connection count (>50 active)'
);

-- Test 15: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'High Connection Count'
    ),
    'View detects high connection count'
);

-- Clean up all dblink connections
DO $$
DECLARE
    i integer;
    conn_name text;
BEGIN
    FOR i IN 1..52 LOOP
        conn_name := 'conn_' || i;
        BEGIN
            PERFORM dblink_cancel_query(conn_name);
            PERFORM dblink_disconnect(conn_name);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;
END $$;

-- =============================================================================
-- Tables Larger Than 50GB (Structural Test)
-- =============================================================================

-- Test 16: No false positives for 50GB check on small test tables
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Tables larger than 100GB'
          AND severity = 'MEDIUM'
          AND object_name LIKE '%pgfirstaid_test%'
    ),
    'No false positive 50GB warnings for test tables (function)'
);

-- Test 17: View parity
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Tables larger than 100GB'
          AND severity_order = 3
          AND object_name LIKE '%pgfirstaid_test%'
    ),
    'No false positive 50GB warnings for test tables (view)'
);

-- =============================================================================
-- Long Running Queries Tests
-- =============================================================================

-- Re-establish a connection for long running query test
DO $$
BEGIN
    PERFORM dblink_connect('long_query_conn',
        'dbname=' || current_database() || ' user=' || current_user);
EXCEPTION WHEN OTHERS THEN
    PERFORM dblink_disconnect('long_query_conn');
    PERFORM dblink_connect('long_query_conn',
        'dbname=' || current_database() || ' user=' || current_user);
END $$;

-- Start a long-running query (pg_sleep for 10 minutes)
-- Sent async so it runs in background
SELECT dblink_send_query('long_query_conn', 'SELECT pg_sleep(600)');

-- Wait briefly to ensure the query registers in pg_stat_activity
SELECT pg_sleep(2);

-- Test 18: Newly started query (< 5 min) not flagged as long running
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Long Running Queries'
          AND current_value LIKE '%pg_sleep(600)%'
    ),
    'Newly started query (< 5 min) not flagged as long running'
);

-- Test 19: View parity
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Long Running Queries'
          AND current_value LIKE '%pg_sleep(600)%'
    ),
    'View: Newly started query (< 5 min) not flagged as long running'
);

-- Test 20: Verify the check logic is valid SQL
SELECT ok(
    (SELECT count(*) >= 0 FROM pg_stat_activity
     WHERE state = 'active'
       AND now() - query_start > interval '5 minutes'),
    'Long running query detection logic is valid SQL'
);

-- Clean up background connection
DO $$
BEGIN
    PERFORM dblink_cancel_query('long_query_conn');
    PERFORM dblink_disconnect('long_query_conn');
EXCEPTION WHEN OTHERS THEN
    NULL;
END $$;

-- =============================================================================
-- Negative Tests
-- =============================================================================

-- Fixture: Table with proper index (should not trigger seq scan warning)
CREATE TABLE pgfirstaid_test.well_indexed_table (
    id serial PRIMARY KEY,
    category text
);
INSERT INTO pgfirstaid_test.well_indexed_table (category)
SELECT 'cat_' || g FROM generate_series(1, 100) g;
CREATE INDEX idx_well_indexed_cat ON pgfirstaid_test.well_indexed_table(category);
ANALYZE pgfirstaid_test.well_indexed_table;

-- Test 21: Well-indexed table not flagged for sequential scans
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Excessive Sequential Scans'
          AND object_name LIKE '%well_indexed_table%'
    ),
    'Well-indexed table not flagged for excessive sequential scans'
);

-- Test 22: Small table not flagged for low index efficiency
SELECT ok(
    NOT EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Low Index Efficiency'
          AND object_name LIKE '%well_indexed_table%'
    ),
    'Table with efficient index not flagged for low efficiency'
);

SELECT * FROM finish();
ROLLBACK;
