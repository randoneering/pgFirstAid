BEGIN;
SELECT plan(22);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Current Blocked/Blocking Queries'),
    'Function executes Current Blocked/Blocking Queries check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Current Blocked/Blocking Queries'),
    'View executes Current Blocked/Blocking Queries check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Deadlocks Since Stats Reset'),
    'Function executes Deadlocks Since Stats Reset check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Deadlocks Since Stats Reset'),
    'View executes Deadlocks Since Stats Reset check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Deadlock Rate Per Hour'),
    'Function executes Deadlock Rate Per Hour check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Deadlock Rate Per Hour'),
    'View executes Deadlock Rate Per Hour check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Deadlocks as Percent of Transactions'),
    'Function executes Deadlocks as Percent of Transactions check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Deadlocks as Percent of Transactions'),
    'View executes Deadlocks as Percent of Transactions check'
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
