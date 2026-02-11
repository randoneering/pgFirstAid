-- 01_structural_tests.sql: Validate function/view structure and parity
BEGIN;
SELECT plan(14);

-- =============================================================================
-- Function Structure Tests
-- =============================================================================

-- Test 1: Function exists
SELECT has_function('pg_firstaid', 'pg_firstAid() function exists');

-- Test 2: Function returns 8 columns
SELECT is(
    (SELECT array_length(proargnames, 1)
     FROM pg_proc WHERE proname = 'pg_firstaid'),
    8,
    'pg_firstAid() returns 8 columns'
);

-- Test 3: Column names match expected
SELECT is(
    (SELECT proargnames
     FROM pg_proc WHERE proname = 'pg_firstaid'),
    ARRAY['severity','category','check_name','object_name',
          'issue_description','current_value','recommended_action',
          'documentation_link'],
    'pg_firstAid() column names match expected'
);

-- Test 4: All severity values are valid
SELECT is(
    (SELECT count(*)::int FROM pg_firstAid()
     WHERE severity NOT IN ('CRITICAL','HIGH','MEDIUM','LOW','INFO')),
    0,
    'All severity values are valid (CRITICAL/HIGH/MEDIUM/LOW/INFO)'
);

-- Test 5: No null severity values
SELECT is(
    (SELECT count(*)::int FROM pg_firstAid() WHERE severity IS NULL),
    0,
    'No NULL severity values in function results'
);

-- Test 6: No null category values
SELECT is(
    (SELECT count(*)::int FROM pg_firstAid() WHERE category IS NULL),
    0,
    'No NULL category values in function results'
);

-- Test 7: No null check_name values
SELECT is(
    (SELECT count(*)::int FROM pg_firstAid() WHERE check_name IS NULL),
    0,
    'No NULL check_name values in function results'
);

-- Test 8: Severity ordering is correct (CRITICAL before HIGH before MEDIUM etc.)
SELECT ok(
    (WITH ordered AS (
        SELECT severity,
               ROW_NUMBER() OVER () as rn,
               CASE severity
                   WHEN 'CRITICAL' THEN 1
                   WHEN 'HIGH' THEN 2
                   WHEN 'MEDIUM' THEN 3
                   WHEN 'LOW' THEN 4
                   WHEN 'INFO' THEN 5
               END as expected_order
        FROM pg_firstAid()
    )
    SELECT bool_and(
        expected_order >= LAG(expected_order, 1, 0) OVER (ORDER BY rn)
    ) FROM ordered),
    'Function results are ordered by severity (CRITICAL -> HIGH -> MEDIUM -> LOW -> INFO)'
);

-- =============================================================================
-- View Structure Tests
-- =============================================================================

-- Test 9: View exists
SELECT has_view('public', 'v_pgfirstAid', 'v_pgfirstAid view exists');

-- Test 10: View has correct columns (includes severity_order)
SELECT columns_are(
    'public', 'v_pgfirstAid',
    ARRAY['severity','category','check_name','object_name',
          'issue_description','current_value','recommended_action',
          'documentation_link','severity_order'],
    'v_pgfirstAid view has expected columns (including severity_order)'
);

-- =============================================================================
-- Parity Tests
-- =============================================================================

-- Test 11: Function and view return same check_names (function minus view)
SELECT is(
    (SELECT count(*)::int FROM (
        SELECT check_name FROM pg_firstAid()
        EXCEPT
        SELECT check_name FROM v_pgfirstAid
    ) diff),
    0,
    'No check_names in function that are missing from view'
);

-- Test 12: View has no extra check_names vs function
SELECT is(
    (SELECT count(*)::int FROM (
        SELECT check_name FROM v_pgfirstAid
        EXCEPT
        SELECT check_name FROM pg_firstAid()
    ) diff),
    0,
    'No check_names in view that are missing from function'
);

-- Test 13: Row counts match
SELECT is(
    (SELECT count(*)::int FROM pg_firstAid()),
    (SELECT count(*)::int FROM v_pgfirstAid),
    'Function and view return same number of rows'
);

-- Test 14: INFO checks always present (baseline sanity)
SELECT ok(
    (SELECT count(*) > 0 FROM pg_firstAid() WHERE severity = 'INFO'),
    'INFO severity results are always present'
);

SELECT * FROM finish();
ROLLBACK;
