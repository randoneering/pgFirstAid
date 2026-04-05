BEGIN;
SELECT plan(46);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Current Blocked/Blocking Queries'),
    'Function executes Current Blocked/Blocking Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Current Blocked/Blocking Queries'),
    'View executes Current Blocked/Blocking Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Outdated Statistics'),
    'Function executes Outdated Statistics check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Outdated Statistics'),
    'View executes Outdated Statistics check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Low Index Efficiency'),
    'Function executes Low Index Efficiency check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Low Index Efficiency'),
    'View executes Low Index Efficiency check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Replication Slots Near Max Wal Size'),
    'Function executes Replication Slots Near Max Wal Size check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Replication Slots Near Max Wal Size'),
    'View executes Replication Slots Near Max Wal Size check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Excessive Sequential Scans'),
    'Function executes Excessive Sequential Scans check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Excessive Sequential Scans'),
    'View executes Excessive Sequential Scans check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Top 10 Expensive Active Queries'),
    'Function executes Top 10 Expensive Active Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Top 10 Expensive Active Queries'),
    'View executes Top 10 Expensive Active Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'pg_stat_statements Extension Missing'),
    'Function executes pg_stat_statements Extension Missing check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'pg_stat_statements Extension Missing'),
    'View executes pg_stat_statements Extension Missing check'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Top 10 Queries by Total Execution Time') ELSE true END),
    'Function executes Top 10 Queries by Total Execution Time check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Top 10 Queries by Total Execution Time') ELSE true END),
    'View executes Top 10 Queries by Total Execution Time check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Mean Execution Time Queries') ELSE true END),
    'Function executes High Mean Execution Time Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Mean Execution Time Queries') ELSE true END),
    'View executes High Mean Execution Time Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Top 10 Queries by Temp Block Spills') ELSE true END),
    'Function executes Top 10 Queries by Temp Block Spills check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Top 10 Queries by Temp Block Spills') ELSE true END),
    'View executes Top 10 Queries by Temp Block Spills check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Low Cache Hit Ratio Queries') ELSE true END),
    'Function executes Low Cache Hit Ratio Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Low Cache Hit Ratio Queries') ELSE true END),
    'View executes Low Cache Hit Ratio Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Runtime Variance Queries') ELSE true END),
    'Function executes High Runtime Variance Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Runtime Variance Queries') ELSE true END),
    'View executes High Runtime Variance Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Calls Low Value Queries') ELSE true END),
    'Function executes High Calls Low Value Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Calls Low Value Queries') ELSE true END),
    'View executes High Calls Low Value Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Rows Per Call Queries') ELSE true END),
    'Function executes High Rows Per Call Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Rows Per Call Queries') ELSE true END),
    'View executes High Rows Per Call Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Shared Block Reads Per Call Queries') ELSE true END),
    'Function executes High Shared Block Reads Per Call Queries check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Shared Block Reads Per Call Queries') ELSE true END),
    'View executes High Shared Block Reads Per Call Queries check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Top Queries by WAL Bytes Per Call') ELSE true END),
    'Function executes Top Queries by WAL Bytes Per Call check when pg_stat_statements is installed'
);
SELECT ok(
    (SELECT CASE WHEN EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_stat_statements') THEN (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Top Queries by WAL Bytes Per Call') ELSE true END),
    'View executes Top Queries by WAL Bytes Per Call check when pg_stat_statements is installed'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Lock-Wait-Heavy Active Queries'),
    'Function executes Lock-Wait-Heavy Active Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Lock-Wait-Heavy Active Queries'),
    'View executes Lock-Wait-Heavy Active Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Idle In Transaction Over 5 Minutes'),
    'Function executes Idle In Transaction Over 5 Minutes check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Idle In Transaction Over 5 Minutes'),
    'View executes Idle In Transaction Over 5 Minutes check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Table with more than 50 columns'),
    'Function executes Table with more than 50 columns check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Table with more than 50 columns'),
    'View executes Table with more than 50 columns check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Tables larger than 50GB'),
    'Function executes Tables larger than 50GB check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Tables larger than 50GB'),
    'View executes Tables larger than 50GB check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Connection Count'),
    'Function executes High Connection Count check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Connection Count'),
    'View executes High Connection Count check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Long Running Queries'),
    'Function executes Long Running Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Long Running Queries'),
    'View executes Long Running Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'shared_buffers At Default'),
    'Function executes shared_buffers At Default check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'shared_buffers At Default'),
    'View executes shared_buffers At Default check'
);

SELECT * FROM finish();
ROLLBACK;
