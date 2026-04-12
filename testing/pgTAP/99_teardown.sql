-- Session-level pgTAP teardown for Python harness
DROP SCHEMA IF EXISTS pgfirstaid_test CASCADE;
DROP FUNCTION IF EXISTS _pg_firstaid_checkpoint_stats();
