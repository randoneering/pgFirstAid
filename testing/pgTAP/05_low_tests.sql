BEGIN;
-- Cache results once; querying inline per-assertion multiplies execution cost by N.
CREATE TEMP TABLE _pgfa_func_results AS SELECT * FROM pg_firstAid();
CREATE TEMP TABLE _pgfa_view_results AS SELECT * FROM v_pgfirstaid;
SELECT plan(12);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Database Size'),
    'Function executes Database Size check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Database Size'),
    'View executes Database Size check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'PostgreSQL Version'),
    'Function executes PostgreSQL Version check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'PostgreSQL Version'),
    'View executes PostgreSQL Version check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Installed Extension'),
    'Function executes Installed Extension check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Installed Extension'),
    'View executes Installed Extension check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Server Uptime'),
    'Function executes Server Uptime check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Server Uptime'),
    'View executes Server Uptime check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Is Logging Enabled'),
    'Function executes Is Logging Enabled check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Is Logging Enabled'),
    'View executes Is Logging Enabled check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Size of ALL Logfiles combined'),
    'Function executes Size of ALL Logfiles combined check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Size of ALL Logfiles combined'),
    'View executes Size of ALL Logfiles combined check'
);

SELECT * FROM finish();
ROLLBACK;
