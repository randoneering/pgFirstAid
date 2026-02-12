BEGIN;
SELECT plan(7);

SELECT ok((SELECT count(*) >= 0 FROM pg_firstAid()), 'pg_firstAid() executes');
SELECT has_view('public', 'v_pgfirstaid', 'v_pgfirstaid exists');

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Missing Primary Key'),
    'Function executes Missing Primary Key check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name = 'Unused Large Index'),
    'Function executes Unused Large Index check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Missing Primary Key'),
    'View executes Missing Primary Key check'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name = 'Unused Large Index'),
    'View executes Unused Large Index check'
);

SELECT ok(
    (SELECT count(*) > 0 FROM pg_firstAid() WHERE severity = 'INFO'),
    'Function returns INFO checks'
);

SELECT * FROM finish();
ROLLBACK;
