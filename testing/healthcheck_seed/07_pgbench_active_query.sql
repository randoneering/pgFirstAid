-- Use with pgbench to create many active connections.
-- Example:
--   pgbench "$PGDATABASE" -n -c 55 -j 10 -T 120 -f testing/healthcheck_seed/07_pgbench_active_query.sql
--
-- Each pgbench client runs this script in a loop. pg_sleep(1) keeps each
-- session in state='active' long enough for pgFirstAid's connection and
-- active-session checks to observe the full -c concurrency.

SELECT pg_sleep(1);

