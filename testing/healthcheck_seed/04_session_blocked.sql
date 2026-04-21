-- Session B (blocked)
-- Run in a separate psql session AFTER Session A (03_session_blocker.sql)
-- has taken its row lock on pgfirstaid_seed.lock_target(id=1).
--
-- This UPDATE will block waiting on Session A's lock, producing the
-- blocking/blocked pair that pgFirstAid's lock checks detect.
-- Keep this session open until validation completes; it will unblock
-- automatically once Session A rolls back, then this session rolls back.

BEGIN;

UPDATE pgfirstaid_seed.lock_target
SET payload = 'blocked_by_session_b'
WHERE id = 1;

ROLLBACK;
