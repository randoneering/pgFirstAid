BEGIN;
SELECT plan(6);

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

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_firstAid() WHERE check_name = 'shared_buffers Setting'),
    'Function executes shared_buffers Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM v_pgfirstaid WHERE check_name = 'shared_buffers Setting'),
    'View executes shared_buffers Setting check'
);

SELECT * FROM finish();
ROLLBACK;
