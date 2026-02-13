BEGIN;
SELECT plan(16);

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
