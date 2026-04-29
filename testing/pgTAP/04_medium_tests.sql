BEGIN;
-- Cache results once; querying inline per-assertion multiplies execution cost by N.
CREATE TEMP TABLE _pgfa_func_results AS SELECT * FROM pg_firstAid();
CREATE TEMP TABLE _pgfa_view_results AS SELECT * FROM v_pgfirstaid;
SELECT plan(16);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Missing FK Index'),
    'Function executes Missing FK Index check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Missing FK Index'),
    'View executes Missing FK Index check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Idle Connections Over 1 Hour'),
    'Function executes Idle Connections Over 1 Hour check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Idle Connections Over 1 Hour'),
    'View executes Idle Connections Over 1 Hour check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Table With Single Or No Columns'),
    'Function executes Table With Single Or No Columns check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Table With Single Or No Columns'),
    'View executes Table With Single Or No Columns check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Table With No Activity Since Stats Reset'),
    'Function executes Table With No Activity Since Stats Reset check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Table With No Activity Since Stats Reset'),
    'View executes Table With No Activity Since Stats Reset check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Role Never Logged In'),
    'Function executes Role Never Logged In check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Role Never Logged In'),
    'View executes Role Never Logged In check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Index With Very Low Usage'),
    'Function executes Index With Very Low Usage check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Index With Very Low Usage'),
    'View executes Index With Very Low Usage check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Empty Table'),
    'Function executes Empty Table check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Empty Table'),
    'View executes Empty Table check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'work_mem At Default'),
    'Function executes work_mem At Default check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'work_mem At Default'),
    'View executes work_mem At Default check'
);

SELECT * FROM finish();
ROLLBACK;
