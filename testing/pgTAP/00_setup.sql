-- 00_setup.sql: Install extensions and load pgFirstAid
-- Run this ONCE before executing test files

-- Install pgTAP for testing assertions
CREATE EXTENSION IF NOT EXISTS pgtap;

-- Install dblink for runtime simulation (background sessions)
CREATE EXTENSION IF NOT EXISTS dblink;

-- Create test schema for all fixtures
CREATE SCHEMA IF NOT EXISTS pgfirstaid_test;

-- Load pgFirstAid function (run from repo root)
-- The function and view should already be loaded via:
--   psql -f pgFirstAid.sql
--   psql -f view_pgFirstAid.sql
-- This script just verifies they exist

DO $$
BEGIN
    -- Verify function exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_proc
        WHERE proname = 'pg_firstaid'
    ) THEN
        RAISE EXCEPTION 'pg_firstAid() function not found. Run: psql -f pgFirstAid.sql';
    END IF;

    -- Verify view exists
    IF NOT EXISTS (
        SELECT 1 FROM pg_views
        WHERE viewname = 'v_pgfirstaid'
          AND schemaname = 'public'
    ) THEN
        RAISE EXCEPTION 'v_pgfirstaid view not found. Run: psql -f view_pgFirstAid.sql';
    END IF;

    RAISE NOTICE 'Setup complete: pgTAP, dblink, pgfirstaid_test schema, pg_firstAid function and view verified.';
END $$;
