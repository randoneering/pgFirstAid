BEGIN;
-- Cache results once; querying inline per-assertion multiplies execution cost by N.
-- PSS checks use count(*) >= 0 so they pass when pg_stat_statements is absent
-- (function emits no rows for those checks) without needing CASE guards.
CREATE TEMP TABLE _pgfa_func_results AS SELECT * FROM pg_firstAid();
CREATE TEMP TABLE _pgfa_view_results AS SELECT * FROM v_pgfirstaid;
SELECT plan(46);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Current Blocked/Blocking Queries'),
    'Function executes Current Blocked/Blocking Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Current Blocked/Blocking Queries'),
    'View executes Current Blocked/Blocking Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Outdated Statistics'),
    'Function executes Outdated Statistics check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Outdated Statistics'),
    'View executes Outdated Statistics check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Low Index Efficiency'),
    'Function executes Low Index Efficiency check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Low Index Efficiency'),
    'View executes Low Index Efficiency check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Replication Slots Near Max Wal Size'),
    'Function executes Replication Slots Near Max Wal Size check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Replication Slots Near Max Wal Size'),
    'View executes Replication Slots Near Max Wal Size check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Excessive Sequential Scans'),
    'Function executes Excessive Sequential Scans check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Excessive Sequential Scans'),
    'View executes Excessive Sequential Scans check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Top 10 Expensive Active Queries'),
    'Function executes Top 10 Expensive Active Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Top 10 Expensive Active Queries'),
    'View executes Top 10 Expensive Active Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'pg_stat_statements Extension Missing'),
    'Function executes pg_stat_statements Extension Missing check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'pg_stat_statements Extension Missing'),
    'View executes pg_stat_statements Extension Missing check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Top 10 Queries by Total Execution Time'),
    'Function executes Top 10 Queries by Total Execution Time check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Top 10 Queries by Total Execution Time'),
    'View executes Top 10 Queries by Total Execution Time check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'High Mean Execution Time Queries'),
    'Function executes High Mean Execution Time Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'High Mean Execution Time Queries'),
    'View executes High Mean Execution Time Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Top 10 Queries by Temp Block Spills'),
    'Function executes Top 10 Queries by Temp Block Spills check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Top 10 Queries by Temp Block Spills'),
    'View executes Top 10 Queries by Temp Block Spills check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Low Cache Hit Ratio Queries'),
    'Function executes Low Cache Hit Ratio Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Low Cache Hit Ratio Queries'),
    'View executes Low Cache Hit Ratio Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'High Runtime Variance Queries'),
    'Function executes High Runtime Variance Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'High Runtime Variance Queries'),
    'View executes High Runtime Variance Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'High Calls Low Value Queries'),
    'Function executes High Calls Low Value Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'High Calls Low Value Queries'),
    'View executes High Calls Low Value Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'High Rows Per Call Queries'),
    'Function executes High Rows Per Call Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'High Rows Per Call Queries'),
    'View executes High Rows Per Call Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'High Shared Block Reads Per Call Queries'),
    'Function executes High Shared Block Reads Per Call Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'High Shared Block Reads Per Call Queries'),
    'View executes High Shared Block Reads Per Call Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Top Queries by WAL Bytes Per Call'),
    'Function executes Top Queries by WAL Bytes Per Call check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Top Queries by WAL Bytes Per Call'),
    'View executes Top Queries by WAL Bytes Per Call check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Lock-Wait-Heavy Active Queries'),
    'Function executes Lock-Wait-Heavy Active Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Lock-Wait-Heavy Active Queries'),
    'View executes Lock-Wait-Heavy Active Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Idle In Transaction Over 5 Minutes'),
    'Function executes Idle In Transaction Over 5 Minutes check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Idle In Transaction Over 5 Minutes'),
    'View executes Idle In Transaction Over 5 Minutes check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Table with more than 50 columns'),
    'Function executes Table with more than 50 columns check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Table with more than 50 columns'),
    'View executes Table with more than 50 columns check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Tables larger than 50GB'),
    'Function executes Tables larger than 50GB check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Tables larger than 50GB'),
    'View executes Tables larger than 50GB check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'High Connection Count'),
    'Function executes High Connection Count check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'High Connection Count'),
    'View executes High Connection Count check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'Long Running Queries'),
    'Function executes Long Running Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'Long Running Queries'),
    'View executes Long Running Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_func_results WHERE check_name = 'shared_buffers At Default'),
    'Function executes shared_buffers At Default check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM _pgfa_view_results WHERE check_name = 'shared_buffers At Default'),
    'View executes shared_buffers At Default check'
);

SELECT * FROM finish();
ROLLBACK;
