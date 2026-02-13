BEGIN;
SELECT plan(4);

SELECT ok((SELECT count(*) >= 0 FROM pg_firstAid()), 'pg_firstAid() executes');
SELECT ok((SELECT count(*) >= 0 FROM v_pgfirstaid), 'v_pgfirstaid executes');

SELECT ok(
    (SELECT count(*) >= 0 FROM pg_firstAid() WHERE check_name IS NOT NULL),
    'Function returns non-null check names'
);

SELECT ok(
    (SELECT count(*) >= 0 FROM v_pgfirstaid WHERE check_name IS NOT NULL),
    'View returns non-null check names'
);

SELECT * FROM finish();
ROLLBACK;
