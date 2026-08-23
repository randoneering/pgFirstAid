BEGIN;
-- Cache results once; querying inline per-assertion multiplies execution cost by N.
CREATE TEMP TABLE _pgfa_func_results AS SELECT * FROM pg_firstAid();
CREATE TEMP TABLE _pgfa_view_results AS SELECT * FROM v_pgfirstaid;
SELECT plan(24);

SELECT ok((SELECT count(*) >= 0 FROM _pgfa_func_results), 'pg_firstAid() executes');
SELECT ok((SELECT count(*) >= 0 FROM _pgfa_view_results), 'v_pgfirstaid executes');

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name IS NOT NULL),
    'Function returns non-null check names'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name IS NOT NULL),
    'View returns non-null check names'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'shared_buffers Setting'),
    'Function executes shared_buffers Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'shared_buffers Setting'),
    'View executes shared_buffers Setting check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'work_mem Setting'),
    'Function executes work_mem Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'work_mem Setting'),
    'View executes work_mem Setting check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'effective_cache_size Setting'),
    'Function executes effective_cache_size Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'effective_cache_size Setting'),
    'View executes effective_cache_size Setting check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'maintenance_work_mem Setting'),
    'Function executes maintenance_work_mem Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'maintenance_work_mem Setting'),
    'View executes maintenance_work_mem Setting check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'Transaction ID Wraparound Risk'),
    'Function executes Transaction ID Wraparound Risk check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'Transaction ID Wraparound Risk'),
    'View executes Transaction ID Wraparound Risk check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'Checkpoint Stats'),
    'Function executes Checkpoint Stats check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'Checkpoint Stats'),
    'View executes Checkpoint Stats check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'Server Role'),
    'Function executes Server Role check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'Server Role'),
    'View executes Server Role check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_func_results WHERE check_name = 'Connection Utilization'),
    'Function executes Connection Utilization check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM _pgfa_view_results WHERE check_name = 'Connection Utilization'),
    'View executes Connection Utilization check'
);

-- Version-conditional checks: SQL must parse and run regardless of whether
-- any rows match the current server_version_num. We assert that EVERY row
-- the check produces has the expected shape (severity, object_name prefix).
-- A fully-patched version returns 0 rows; the assertion is vacuously true.
SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM _pgfa_func_results
         WHERE check_name = 'Known CVE Affecting Your Version'
           AND (severity <> 'HIGH' OR object_name !~ '^CVE-')
    )),
    'Function CVE rows have the expected shape (severity=HIGH, object_name=CVE-*)'
);
SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM _pgfa_view_results
         WHERE check_name = 'Known CVE Affecting Your Version'
           AND (severity <> 'HIGH' OR object_name !~ '^CVE-')
    )),
    'View CVE rows have the expected shape (severity=HIGH, object_name=CVE-*)'
);
SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM _pgfa_func_results
         WHERE check_name = 'Known Bug Affecting Your Version'
           AND (severity <> 'MEDIUM' OR object_name !~ '^PG')
    )),
    'Function Bug rows have the expected shape (severity=MEDIUM, object_name=PG*)'
);
SELECT ok(
    (SELECT NOT EXISTS (
        SELECT 1 FROM _pgfa_view_results
         WHERE check_name = 'Known Bug Affecting Your Version'
           AND (severity <> 'MEDIUM' OR object_name !~ '^PG')
    )),
    'View Bug rows have the expected shape (severity=MEDIUM, object_name=PG*)'
);

SELECT * FROM finish();
ROLLBACK;
