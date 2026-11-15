-- Session-level pgTAP teardown for Python harness
DROP SCHEMA IF EXISTS pgfirstaid_test CASCADE;
SET lock_timeout = '30s';
DROP VIEW IF EXISTS v_pgfirstaid;
RESET lock_timeout;
DROP FUNCTION IF EXISTS pg_firstAid();
DROP FUNCTION IF EXISTS _pg_firstaid_checkpoint_stats();
DROP FUNCTION IF EXISTS pgfirstaid_agent_prompt(text, text, text, text, text, text, text, text);
DROP FUNCTION IF EXISTS _pgfirstaid_install_view(regclass);
