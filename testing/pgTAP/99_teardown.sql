-- 99_teardown.sql: Clean up all test fixtures and extensions
-- Run this after all tests to restore the database to a clean state

-- Drop test schema and all objects within it
DROP SCHEMA IF EXISTS pgfirstaid_test CASCADE;

-- Clean up any lingering replication slots created during tests
DO $$
DECLARE
    slot_record RECORD;
BEGIN
    FOR slot_record IN
        SELECT slot_name FROM pg_replication_slots
        WHERE slot_name LIKE 'pgfirstaid_test_%'
    LOOP
        PERFORM pg_drop_replication_slot(slot_record.slot_name);
        RAISE NOTICE 'Dropped replication slot: %', slot_record.slot_name;
    END LOOP;
END $$;

-- Terminate any lingering dblink connections
DO $$
DECLARE
    conn_name text;
    i integer;
BEGIN
    -- Clean up numbered connections from high connection count test
    FOR i IN 1..60 LOOP
        conn_name := 'conn_' || i;
        BEGIN
            PERFORM dblink_disconnect(conn_name);
        EXCEPTION WHEN OTHERS THEN
            NULL;
        END;
    END LOOP;

    -- Clean up named connections
    BEGIN
        PERFORM dblink_disconnect('test_conn');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;

    BEGIN
        PERFORM dblink_disconnect('long_query_conn');
    EXCEPTION WHEN OTHERS THEN NULL;
    END;
END $$;

DO $$
BEGIN
    RAISE NOTICE 'Teardown complete. Test schema and fixtures removed.';
END $$;
