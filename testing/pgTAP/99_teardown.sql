-- Session-level pgTAP teardown for Python harness
DROP SCHEMA IF EXISTS pgfirstaid_test CASCADE;
DROP VIEW IF EXISTS v_pgfirstaid;
DROP FUNCTION IF EXISTS pg_firstAid();
DROP FUNCTION IF EXISTS _pg_firstaid_checkpoint_stats();
