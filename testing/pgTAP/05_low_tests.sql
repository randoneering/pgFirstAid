BEGIN;
SELECT plan(12);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Database Size'),
    'Function executes Database Size check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Database Size'),
    'View executes Database Size check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'PostgreSQL Version'),
    'Function executes PostgreSQL Version check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'PostgreSQL Version'),
    'View executes PostgreSQL Version check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Installed Extension'),
    'Function executes Installed Extension check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Installed Extension'),
    'View executes Installed Extension check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Server Uptime'),
    'Function executes Server Uptime check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Server Uptime'),
    'View executes Server Uptime check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Is Logging Enabled'),
    'Function executes Is Logging Enabled check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Is Logging Enabled'),
    'View executes Is Logging Enabled check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Size of ALL Logfiles combined'),
    'Function executes Size of ALL Logfiles combined check'
);
SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Size of ALL Logfiles combined'),
    'View executes Size of ALL Logfiles combined check'
);

SELECT * FROM finish();
ROLLBACK;
