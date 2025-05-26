CREATE FUNCTION pgfirstaid () RETURNS TABLE (
    id int, --Reference ID/Primary Key
    priority int, --Ordered by lowest number being highest priority
    check_name varchar(255), --Name of check
    check_value text, --Server/Database value for target check_name
    description text, --Description of check_name
    treatment text, --Suggested step(s), if any, on the check_value
    aid text, --Links to documentation or troubleshooting guides to assist with treatment
    dattime_of_diagnosis timestamptz --Timestamp (with timezone) when pgfirstaid was administered
)
DECLARE --declaring values and names for our checks
    uptime text --time since last reboot
    unused_indexes varchar(255) --list of indexes that are left unused
    schema_size varchar(255) --size of each schema
    tables_without_pkeys (255) --list of tables without primary keys
    database_size varchar(255) --list of databases and their size (binary)

BEGIN
    /* uptime health check*/
    select current_timestamp - pg_postmaster_start_time() into uptime
    --https://www.postgresql.org/docs/current/functions-info.html


    /* unused_indexes check */
    SELECT s.schemaname,
        s.relname AS tablename,
        s.indexrelname AS indexname,
        s.last_idx_scan as last_scan,
        pg_relation_size(s.indexrelid) AS index_size
    FROM pg_catalog.pg_stat_user_indexes s
    JOIN pg_catalog.pg_index i ON s.indexrelid = i.indexrelid
    WHERE s.idx_scan = 0  or last_idx_scan < now() - interval '60 days'
    AND 0 <> ALL (i.indkey)
    AND NOT i.indisunique
    AND NOT EXISTS
            (SELECT 1 FROM pg_catalog.pg_constraint c
            WHERE c.conindid = s.indexrelid)
    AND NOT EXISTS
            (SELECT 1 FROM pg_catalog.pg_inherits AS inh
            WHERE inh.inhrelid = s.indexrelid)
    ORDER BY pg_relation_size(s.indexrelid) DESC;
        --https://www.rockdata.net/tutorial/check-unused-indexes/
        --https://pgdash.io/blog/finding-unused-indexes-in-postgresql.htmls
END


LANGUAGE SQL;
