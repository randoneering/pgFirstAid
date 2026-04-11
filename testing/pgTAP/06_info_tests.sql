BEGIN;
SELECT plan(12);

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

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_firstAid() WHERE check_name = 'work_mem Setting'),
    'Function executes work_mem Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM v_pgfirstaid WHERE check_name = 'work_mem Setting'),
    'View executes work_mem Setting check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_firstAid() WHERE check_name = 'effective_cache_size Setting'),
    'Function executes effective_cache_size Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM v_pgfirstaid WHERE check_name = 'effective_cache_size Setting'),
    'View executes effective_cache_size Setting check'
);

SELECT ok(
    (SELECT count(*) >= 1 FROM pg_firstAid() WHERE check_name = 'maintenance_work_mem Setting'),
    'Function executes maintenance_work_mem Setting check'
);
SELECT ok(
    (SELECT count(*) >= 1 FROM v_pgfirstaid WHERE check_name = 'maintenance_work_mem Setting'),
    'View executes maintenance_work_mem Setting check'
);

SELECT * FROM finish();
ROLLBACK;
