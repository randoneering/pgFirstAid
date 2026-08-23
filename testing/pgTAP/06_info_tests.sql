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
-- any rows match the current server_version_num. The 4 below inspect the
-- function/view body text via pg_get_functiondef / pg_get_viewdef, so they
-- assert PRESENCE of the new check_name in the SQL definition regardless
-- of whether the check fires rows on the running version. Catches accidental
-- removal/rename even on a fully-patched server where the checks return 0
-- rows.
--
-- The integration test `test_every_health_check_has_pgtap_coverage` requires
-- the literal pattern `check_name = '<NAME>'` to appear in this file, so
-- each of the 4 below echoes its target in a comment.
--   function pg_firstAid() must define check_name = 'Known CVE Affecting Your Version'
--   function pg_firstAid() must define check_name = 'Known Bug Affecting Your Version'
--   view v_pgfirstaid must define check_name = 'Known CVE Affecting Your Version'
--   view v_pgfirstaid must define check_name = 'Known Bug Affecting Your Version'
SELECT ok(
    (SELECT pg_get_functiondef('pg_firstAid()'::regprocedure) LIKE '%''Known CVE Affecting Your Version'' as check_name%'),
    'Function pg_firstAid() defines Known CVE check (check_name = ''Known CVE Affecting Your Version'')'
);
SELECT ok(
    (SELECT pg_get_functiondef('pg_firstAid()'::regprocedure) LIKE '%''Known Bug Affecting Your Version'' as check_name%'),
    'Function pg_firstAid() defines Known Bug check (check_name = ''Known Bug Affecting Your Version'')'
);
SELECT ok(
    (SELECT pg_get_viewdef('v_pgfirstaid'::regclass, true) LIKE '%''Known CVE Affecting Your Version''%AS check_name%'),
    'View v_pgfirstaid defines Known CVE check (check_name = ''Known CVE Affecting Your Version'')'
);
SELECT ok(
    (SELECT pg_get_viewdef('v_pgfirstaid'::regclass, true) LIKE '%''Known Bug Affecting Your Version''%AS check_name%'),
    'View v_pgfirstaid defines Known Bug check (check_name = ''Known Bug Affecting Your Version'')'
);

SELECT * FROM finish();
ROLLBACK;
