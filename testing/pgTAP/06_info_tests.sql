-- 06_info_tests.sql: INFO severity health checks
BEGIN;
SELECT plan(18);

-- =============================================================================
-- Database Size Tests
-- =============================================================================

-- Test 1: Database Size check exists in function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Database Size'
          AND severity = 'INFO'
    ),
    'Function returns Database Size info check'
);

-- Test 2: Database Size has non-empty current_value
SELECT ok(
    (SELECT current_value IS NOT NULL AND current_value != ''
     FROM pg_firstAid()
     WHERE check_name = 'Database Size'
     LIMIT 1),
    'Database Size current_value is non-empty'
);

-- Test 3: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Database Size'
          AND severity = 'INFO'
    ),
    'View returns Database Size info check'
);

-- =============================================================================
-- PostgreSQL Version Tests
-- =============================================================================

-- Test 4: PostgreSQL Version check exists in function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'PostgreSQL Version'
          AND severity = 'INFO'
    ),
    'Function returns PostgreSQL Version info check'
);

-- Test 5: Version string contains 'PostgreSQL'
SELECT ok(
    (SELECT current_value LIKE 'PostgreSQL%'
     FROM pg_firstAid()
     WHERE check_name = 'PostgreSQL Version'
     LIMIT 1),
    'PostgreSQL Version current_value starts with "PostgreSQL"'
);

-- Test 6: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'PostgreSQL Version'
          AND severity = 'INFO'
    ),
    'View returns PostgreSQL Version info check'
);

-- =============================================================================
-- Installed Extensions Tests
-- =============================================================================

-- Test 7: Installed Extension check exists in function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Installed Extension'
          AND severity = 'INFO'
    ),
    'Function returns Installed Extension info check'
);

-- Test 8: pgTAP extension appears in results (since we installed it)
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Installed Extension'
          AND current_value LIKE 'pgtap:%'
    ),
    'pgTAP extension appears in Installed Extension results'
);

-- Test 9: View parity - pgTAP in extension results
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Installed Extension'
          AND current_value LIKE 'pgtap:%'
    ),
    'View: pgTAP extension appears in Installed Extension results'
);

-- =============================================================================
-- Server Uptime Tests
-- =============================================================================

-- Test 10: Server Uptime check exists in function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Server Uptime'
          AND severity = 'INFO'
    ),
    'Function returns Server Uptime info check'
);

-- Test 11: Uptime has non-empty current_value
SELECT ok(
    (SELECT current_value IS NOT NULL AND current_value != ''
     FROM pg_firstAid()
     WHERE check_name = 'Server Uptime'
     LIMIT 1),
    'Server Uptime current_value is non-empty'
);

-- Test 12: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Server Uptime'
          AND severity = 'INFO'
    ),
    'View returns Server Uptime info check'
);

-- =============================================================================
-- Log Directory Tests
-- =============================================================================

-- Test 13: Log Directory check exists in function
SELECT ok(
    EXISTS(
        SELECT 1 FROM pg_firstAid()
        WHERE check_name = 'Is Logging Enabled'
          AND severity = 'INFO'
    ),
    'Function returns Is Logging Enabled info check'
);

-- Test 14: View parity
SELECT ok(
    EXISTS(
        SELECT 1 FROM v_pgfirstAid
        WHERE check_name = 'Is Logging Enabled'
          AND severity = 'INFO'
    ),
    'View returns Is Logging Enabled info check'
);

-- =============================================================================
-- Log File Size Tests
-- =============================================================================

-- Test 15: Log File Size check executes without error (function)
-- Note: This may fail on cloud-managed instances without filesystem access
SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid()
     WHERE check_name = 'Size of ALL Logfiles combined'),
    'Log file size check executes without error (function)'
);

-- Test 16: View parity
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstAid
     WHERE check_name = 'Size of ALL Logfiles combined'),
    'Log file size check executes without error (view)'
);

-- =============================================================================
-- Parity Tests for all INFO checks
-- =============================================================================

-- Test 17: All INFO check_names from function exist in view
SELECT is(
    (SELECT count(*)::int FROM (
        SELECT DISTINCT check_name FROM pg_firstAid() WHERE severity = 'INFO'
        EXCEPT
        SELECT DISTINCT check_name FROM v_pgfirstAid WHERE severity = 'INFO'
    ) diff),
    0,
    'All INFO check_names from function exist in view'
);

-- Test 18: All INFO check_names from view exist in function
SELECT is(
    (SELECT count(*)::int FROM (
        SELECT DISTINCT check_name FROM v_pgfirstAid WHERE severity = 'INFO'
        EXCEPT
        SELECT DISTINCT check_name FROM pg_firstAid() WHERE severity = 'INFO'
    ) diff),
    0,
    'All INFO check_names from view exist in function'
);

SELECT * FROM finish();
ROLLBACK;
