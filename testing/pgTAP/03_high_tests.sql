BEGIN;
SELECT plan(30);

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
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Top 10 Queries by Total Execution Time'),
    'Function executes Top 10 Queries by Total Execution Time check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Top 10 Queries by Total Execution Time'),
    'View executes Top 10 Queries by Total Execution Time check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Mean Execution Time Queries'),
    'Function executes High Mean Execution Time Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Mean Execution Time Queries'),
    'View executes High Mean Execution Time Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Top 10 Queries by Temp Block Spills'),
    'Function executes Top 10 Queries by Temp Block Spills check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Top 10 Queries by Temp Block Spills'),
    'View executes Top 10 Queries by Temp Block Spills check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Low Cache Hit Ratio Queries'),
    'Function executes Low Cache Hit Ratio Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Low Cache Hit Ratio Queries'),
    'View executes Low Cache Hit Ratio Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'High Runtime Variance Queries'),
    'Function executes High Runtime Variance Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'High Runtime Variance Queries'),
    'View executes High Runtime Variance Queries check'
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
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Table with more than 50 columns'),
    'Function executes Table with more than 50 columns check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Table with more than 50 columns'),
    'View executes Table with more than 50 columns check'
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

SELECT * FROM finish();
ROLLBACK;
