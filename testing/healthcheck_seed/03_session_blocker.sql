-- Session A (blocker)
-- Keep this transaction open while running Session B.

BEGIN;

CREATE SCHEMA IF NOT EXISTS pgfirstaid_seed;
CREATE TABLE IF NOT EXISTS pgfirstaid_seed.lock_target (
    id int PRIMARY KEY,
    payload text
);

INSERT INTO pgfirstaid_seed.lock_target (id, payload)
VALUES (1, 'seed')
ON CONFLICT (id) DO NOTHING;

UPDATE pgfirstaid_seed.lock_target
SET payload = 'locked_by_session_a'
WHERE id = 1;

-- Hold lock long enough for pg_firstAid checks.
SELECT pg_sleep(600);

ROLLBACK;
