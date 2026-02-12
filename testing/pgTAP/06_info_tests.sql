BEGIN;
SELECT plan(4);

SELECT ok((SELECT count(*) >= 0 FROM pg_firstAid()), 'pg_firstAid() executes');
SELECT ok((SELECT count(*) >= 0 FROM v_pgfirstaid), 'v_pgfirstaid executes');

SELECT is(
    (SELECT count(*) FROM (
        SELECT check_name FROM pg_firstAid()
        EXCEPT
        SELECT check_name FROM v_pgfirstaid
    ) q),
    0::bigint,
    'No check_name missing from view'
);

SELECT is(
    (SELECT count(*) FROM (
        SELECT check_name FROM v_pgfirstaid
        EXCEPT
        SELECT check_name FROM pg_firstAid()
    ) q),
    0::bigint,
    'No extra check_name in view'
);

SELECT * FROM finish();
ROLLBACK;
