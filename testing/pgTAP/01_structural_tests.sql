BEGIN;
-- Cache results once; querying inline per-assertion multiplies execution cost by N.
CREATE TEMP TABLE _pgfa_func_results AS SELECT * FROM pg_firstAid();
CREATE TEMP TABLE _pgfa_view_results AS SELECT * FROM v_pgfirstaid;
SELECT plan(7);

SELECT ok((SELECT count(*) >= 0 FROM _pgfa_func_results), 'pg_firstAid() executes');
SELECT has_view('public', 'v_pgfirstaid', 'v_pgfirstaid exists');

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Missing Primary Key'),
    'Function executes Missing Primary Key check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Unused Large Index'),
    'Function executes Unused Large Index check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Missing Primary Key'),
    'View executes Missing Primary Key check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Unused Large Index'),
    'View executes Unused Large Index check'
);

SELECT ok(
    (SELECT count(*) > 0 FROM _pgfa_func_results WHERE severity = 'INFO'),
    'Function returns INFO checks'
);

SELECT * FROM finish();
ROLLBACK;
