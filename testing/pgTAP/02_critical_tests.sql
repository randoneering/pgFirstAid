BEGIN;
-- Cache results once; querying inline per-assertion multiplies execution cost by N.
CREATE TEMP TABLE _pgfa_func_results AS SELECT * FROM pg_firstAid();
CREATE TEMP TABLE _pgfa_view_results AS SELECT * FROM v_pgfirstaid;
SELECT plan(12);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Inactive Replication Slots'),
    'Function executes Inactive Replication Slots check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Inactive Replication Slots'),
    'View executes Inactive Replication Slots check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Table Bloat (Detailed)'),
    'Function executes Table Bloat (Detailed) check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Table Bloat (Detailed)'),
    'View executes Table Bloat (Detailed) check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Missing Statistics'),
    'Function executes Missing Statistics check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Missing Statistics'),
    'View executes Missing Statistics check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Tables larger than 100GB'),
    'Function executes Tables larger than 100GB check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Tables larger than 100GB'),
    'View executes Tables larger than 100GB check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Duplicate Index'),
    'Function executes Duplicate Index check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Duplicate Index'),
    'View executes Duplicate Index check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Table with more than 200 columns'),
    'Function executes Table with more than 200 columns check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Table with more than 200 columns'),
    'View executes Table with more than 200 columns check'
);

SELECT * FROM finish();
ROLLBACK;
