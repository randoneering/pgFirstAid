CREATE OR REPLACE FUNCTION pg_firstAid ()
    RETURNS TABLE (
        severity text,
        category text,
        check_name text,
        object_name text,
        issue_description text,
        current_value text,
        recommended_action text,
        documentation_link text
    )
    AS $$
BEGIN
    -- Create temporary table to collect all health check results
    CREATE temp TABLE health_results (
        severity text,
        category text,
        check_name text,
        object_name text,
        issue_description text,
        current_value text,
        recommended_action text,
        documentation_link text,
        severity_order integer
    );
    -- CRITICAL: Tables without primary keys
    INSERT INTO health_results
    SELECT
        'CRITICAL' AS severity,
        'Table Health' AS category,
        'Missing Primary Key' AS check_name,
        quote_ident(pt.schemaname) || '.' || quote_ident(tablename) AS object_name,
        'Table missing a primary key, which can cause replication issues and/or poor performance' AS issue_description,
        'No primary key defined' AS current_value,
        'Add a primary key or unique constraint with NOT NULL columns' AS recommended_action,
        'https://www.postgresql.org/docs/current/ddl-constraints.html#DDL-CONSTRAINTS-PRIMARY-KEYS' AS documentation_link,
        1 AS severity_order
    FROM
        pg_tables pt
    WHERE
        pt.schemaname NOT LIKE ALL (ARRAY['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
        AND NOT EXISTS (
            SELECT
                1
            FROM
                pg_constraint pc
                JOIN pg_class c ON pc.conrelid = c.oid
                JOIN pg_namespace n ON c.relnamespace = n.oid
            WHERE
                pc.contype = 'p'
                AND n.nspname = pt.schemaname
                AND c.relname = pt.tablename);
    -- CRITICAL: Unused indexes consuming significant space
    INSERT INTO health_results
    SELECT
        'CRITICAL' AS severity,
        'Table Health' AS category,
        'Unused Large Index' AS check_name,
        quote_ident(psi.schemaname) || '.' || quote_ident(psio.indexrelname) AS object_name,
        'Large unused index consuming disk space and potentially impacting write performance' AS issue_description,
        pg_size_pretty(pg_relation_size(psi.indexrelid)) || ' (0 scans)' AS current_value,
        'Consider dropping this index if truly unused after monitoring usage patterns. Never drop an index without validating usage!' AS recommended_action,
        'https://www.postgresql.org/docs/current/sql-dropindex.html' AS documentation_link,
        1 AS severity_order
    FROM
        pg_stat_user_indexes psi
        JOIN pg_statio_user_indexes psio ON psi.indexrelid = psio.indexrelid
    WHERE
        idx_scan = 0
        AND pg_relation_size(psi.indexrelid) > 104857600;
    -- 100MB
    -- HIGH: Inactive Replication slots
    INSERT INTO health_results WITH q AS (
        SELECT
            slot_name,
            plugin,
            DATABASE,
            restart_lsn,
            CASE WHEN 'invalidation_reason' IS NOT NULL THEN
                'invalid'
            ELSE
                CASE WHEN active IS TRUE THEN
                    'active'
                ELSE
                    'inactive'
            END
            END AS "status",
            pg_size_pretty(pg_wal_lsn_diff (pg_current_wal_lsn (), restart_lsn)) AS "retained_wal",
            pg_size_pretty(safe_wal_size) AS "safe_wal_size"
        FROM
            pg_replication_slots
        WHERE
            'status' = 'inactive'
)
    SELECT
        'HIGH' AS severity,
        'Replication Health' AS category,
        'Inactive Replication Slots' AS check_name,
        'Slot name:' || slot_name AS object_name,
        'Target replication slot is inactive' AS issue_description,
        'Retained wal:' || retained_wal || ' database:' || DATABASE AS current_value,
        'If the replication slot is no longer needed, drop the slot' AS recommended_action,
        'https://www.morling.dev/blog/mastering-postgres-replication-slots' AS documentation_link,
        2 AS severity_order
    FROM
        q
    ORDER BY
        slot_name;
    -- credit: https://www.morling.dev/blog/mastering-postgres-replication-slots/ -- Thank you Gunnar Morling!
    -- HIGH: Tables with high bloat
    INSERT INTO health_results WITH q AS (
        SELECT
            current_database(),
            schemaname,
            tblname,
            bs * tblpages AS real_size,
            (tblpages - est_tblpages) * bs AS extra_size,
            CASE WHEN tblpages > 0
                AND tblpages - est_tblpages > 0 THEN
                100 * (tblpages - est_tblpages) / tblpages::float
            ELSE
                0
            END AS extra_pct,
            fillfactor,
            CASE WHEN tblpages - est_tblpages_ff > 0 THEN
                (tblpages - est_tblpages_ff) * bs
            ELSE
                0
            END AS bloat_size,
            CASE WHEN tblpages > 0
                AND tblpages - est_tblpages_ff > 0 THEN
                100 * (tblpages - est_tblpages_ff) / tblpages::float
            ELSE
                0
            END AS bloat_pct,
            is_na
        FROM (
            SELECT
                ceil(reltuples / ((bs - page_hdr) / tpl_size)) + ceil(toasttuples / 4) AS est_tblpages,
                ceil(reltuples / ((bs - page_hdr) * fillfactor / (tpl_size * 100))) + ceil(toasttuples / 4) AS est_tblpages_ff,
                tblpages,
                fillfactor,
                bs,
                tblid,
                schemaname,
                tblname,
                heappages,
                toastpages,
                is_na
            FROM (
                SELECT
                    (4 + tpl_hdr_size + tpl_data_size + (2 * ma) - CASE WHEN tpl_hdr_size % ma = 0 THEN
                            ma
                        ELSE
                            tpl_hdr_size % ma
                        END - CASE WHEN ceil(tpl_data_size)::int % ma = 0 THEN
                            ma
                        ELSE
                            ceil(tpl_data_size)::int % ma
                        END) AS tpl_size,
                    bs - page_hdr AS size_per_block,
                    (heappages + toastpages) AS tblpages,
                    heappages,
                    toastpages,
                    reltuples,
                    toasttuples,
                    bs,
                    page_hdr,
                    tblid,
                    schemaname,
                    tblname,
                    fillfactor,
                    is_na
                FROM (
                    SELECT
                        tbl.oid AS tblid,
                        ns.nspname AS schemaname,
                        tbl.relname AS tblname,
                        tbl.reltuples,
                        tbl.relpages AS heappages,
                        coalesce(toast.relpages, 0) AS toastpages,
                        coalesce(toast.reltuples, 0) AS toasttuples,
                        coalesce(substring(array_to_string(tbl.reloptions, ' ')
                            FROM 'fillfactor=([0-9]+)')::smallint, 100) AS fillfactor,
                        current_setting('block_size')::numeric AS bs,
                        CASE WHEN version() ~ 'mingw32'
                            OR version() ~ '64-bit|x86_64|ppc64|ia64|amd64' THEN
                            8
                        ELSE
                            4
                        END AS ma,
                        24 AS page_hdr,
                        23 + CASE WHEN MAX(coalesce(s.null_frac, 0)) > 0 THEN
                            (7 + count(s.attname)) / 8
                        ELSE
                            0::int
                        END + CASE WHEN bool_or(att.attname = 'oid'
                            AND att.attnum < 0) THEN
                            4
                        ELSE
                            0
                        END AS tpl_hdr_size,
                        sum((1 - coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0)) AS tpl_data_size,
                        bool_or(att.atttypid = 'pg_catalog.name'::regtype)
                        OR sum(
                            CASE WHEN att.attnum > 0 THEN
                                1
                            ELSE
                                0
                            END) <> count(s.attname) AS is_na
                    FROM
                        pg_attribute AS att
                        JOIN pg_class AS tbl ON att.attrelid = tbl.oid
                        JOIN pg_namespace AS ns ON ns.oid = tbl.relnamespace
                        LEFT JOIN pg_stats AS s ON s.schemaname = ns.nspname
                            AND s.tablename = tbl.relname
                            AND s.inherited = FALSE
                            AND s.attname = att.attname
                    LEFT JOIN pg_class AS toast ON tbl.reltoastrelid = toast.oid
                WHERE
                    NOT att.attisdropped
                    AND tbl.relkind IN ('r', 'm')
                GROUP BY
                    1,
                    2,
                    3,
                    4,
                    5,
                    6,
                    7,
                    8,
                    9,
                    10
                ORDER BY
                    2,
                    3) AS s) AS s2) AS s3
)
SELECT
    'HIGH' AS severity,
    'Table Health' AS category,
    'Table Bloat (Detailed)' AS check_name,
    quote_ident(schemaname) || '.' || quote_ident(tblname) AS object_name,
    'Table has significant bloat (>50%) affecting performance and storage' AS issue_description,
    'Real size: ' || pg_size_pretty(real_size::bigint) || ', Bloat: ' || pg_size_pretty(bloat_size::bigint) || ' (' || ROUND(bloat_pct::numeric, 2) || '%)' AS current_value,
    'Run VACUUM FULL to reclaim space' AS recommended_action,
    'https://www.postgresql.org/docs/current/sql-vacuum.html,
    https://github.com/ioguix/pgsql-bloat-estimation/' AS documentation_link,
    2 AS severity_order
FROM
    q
WHERE
    bloat_pct > 50.0
    AND schemaname NOT LIKE ALL (ARRAY['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
ORDER BY
    quote_ident(schemaname),
    quote_ident(tblname);
    --Credit: https://github.com/ioguix/pgsql-bloat-estimation -- Jehan-Guillaume (ioguix) de Rorthais!
    -- HIGH: Tables never analyzed
    INSERT INTO health_results
    SELECT
        'HIGH' AS severity,
        'Table Health' AS category,
        'Missing Statistics' AS check_name,
        quote_ident(schemaname) || '.' || quote_ident(relname) AS object_name,
        'Table has never been analyzed, query planner missing statistics' AS issue_description,
        'Last analyze: Never' AS current_value,
        'Run ANALYZE on this table or enable auto-analyze' AS recommended_action,
        'https://www.postgresql.org/docs/current/sql-analyze.html' AS documentation_link,
        2 AS severity_order
    FROM
        pg_stat_user_tables pt
    WHERE
        last_analyze IS NULL
        AND last_autoanalyze IS NULL
        AND n_tup_ins + n_tup_upd + n_tup_del > 1000;
    -- HIGH: Tables larger than 100GB
    WITH ts AS (
        SELECT
            table_schema,
            table_name,
            pg_relation_size('"' || table_schema || '"."' || table_name || '"') AS size_bytes,
            pg_size_pretty(pg_relation_size('"' || table_schema || '"."' || table_name || '"')) AS size_pretty
        FROM
            information_schema.tables
        WHERE
            table_type = 'BASE TABLE'
            AND pg_relation_size('"' || table_schema || '"."' || table_name || '"') > 107374182400
            -- 100GB in bytes
        ORDER BY
            size_bytes DESC)
    INSERT INTO health_results
    SELECT
        'HIGH' AS severity,
        'Table Health' AS category,
        'Tables larger than 100GB' AS check_name,
        ts.table_schema || '"."' || ts.table_name AS object_name,
        'The following table' AS description,
        ts.size_pretty AS current_value,
        'I suggest looking into partitioning tables. Do you need all of this data? Can some of it be archived into something like S3?' AS recommended_action,
        'https://www.heroku.com/blog/handling-very-large-tables-in-postgres-using-partitioning/' AS documentation_link,
        2 AS severity_order
    FROM
        ts;
    -- HIGH: Duplicate or redundant indexes
    INSERT INTO health_results
    SELECT
        'HIGH' AS severity,
        'Table Health' AS category,
        'Duplicate Index' AS check_name,
        quote_ident(i1.schemaname) || '.' || i1.indexname || ' & ' || i2.indexname AS object_name,
        'Multiple indexes with identical or overlapping column sets' AS issue_description,
        'Indexes: ' || i1.indexname || ', ' || i2.indexname AS current_value,
        'Review and consolidate duplicate indexes and focus on keeping the most efficient one' AS recommended_action,
        'https://www.postgresql.org/docs/current/indexes-multicolumn.html' AS documentation_link,
        2 AS severity_order
    FROM
        pg_indexes i1
        JOIN pg_indexes i2 ON i1.schemaname = i2.schemaname
            AND i1.tablename = i2.tablename
            AND i1.indexname < i2.indexname
            AND i1.indexdef = i2.indexdef
    WHERE
        i1.schemaname NOT LIKE ALL (ARRAY['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%']);
    -- HIGH: Table with more than 200 columns
    WITH cc AS (
        SELECT
            table_schema,
            table_name,
            COUNT(*) AS column_count
        FROM
            information_schema.columns
        WHERE
            table_schema NOT IN ('pg_catalog', 'information_schema')
        GROUP BY
            table_schema,
            table_name
        ORDER BY
            column_count DESC)
    INSERT INTO health_results
    SELECT
        'HIGH' AS severity,
        'Table Health' AS category,
        'Table with more than 200 columns' AS check_name,
        cc.table_schema || '.' || cc.table_name AS object_name,
        'Postgres has a hard 1600 column limit, but that also includes columns you have dropped. Continuing to widen your table can impact performance.' AS issue_description,
        cc.column_count AS current_value,
        'Yikes-it is about time you put a hard stop on widing your tables and begin breaking this table into several tables. I once worked on a table with over 300 columns before.......' AS recommended_action,
        'https://www.tigerdata.com/learn/designing-your-database-schema-wide-vs-narrow-postgres-tables \
	 https://nerderati.com/postgresql-tables-can-have-at-most-1600-columns \
     https://www.postgresql.org/docs/current/limits.html' AS documentation_link,
        2 AS severity_order
    FROM
        cc
    WHERE
        cc.column_count > 200;
    -- MEDIUM: Blocked and Blocking Queries
    WITH bq AS (
        SELECT
            blocked.pid AS blocked_pid,
            blocked.query AS blocked_query,
            blocking.pid AS blocking_pid,
            blocking.query AS blocking_query,
            now() - blocked.query_start AS blocked_duration
        FROM
            pg_locks blocked_locks
            JOIN pg_stat_activity blocked ON blocked.pid = blocked_locks.pid
            JOIN pg_locks blocking_locks ON blocking_locks.transactionid = blocked_locks.transactionid
                AND blocking_locks.pid != blocked_locks.pid
            JOIN pg_stat_activity blocking ON blocking.pid = blocking_locks.pid
        WHERE
            NOT blocked_locks.granted)
    INSERT INTO health_results
    SELECT
        'MEDIUM' AS severity,
        'Query Health' AS category,
        'Current Blocked/Blocking Queries' AS check_name,
        'Blocked PID: ' || bq.blocked_pid || chr(10) || 'Blocked Query: ' || bq.blocked_query AS object_name,
        'The following query is being blocked by an already running query' AS issue_description,
        'Blocking PID: ' || bq.blocking_pid || chr(10) || 'Blocking Query: ' || bq.blocking_query AS current_value,
        'Blocked queries are part of concurrency behavior. However, it is always recommended to monitor long running blocking queries. The Crunchy Data article recommended has an excellent walk through and suggested steps on how to tackle unnecessary blocking queries' AS recommended_action,
        'https://www.postgresql.org/docs/current/explicit-locking.html' AS documentation_link,
        3 AS severity_order
    FROM
        bq;
    -- MEDIUM: Tables with outdated statistics
    INSERT INTO health_results WITH s AS (
        SELECT
            current_setting('autovacuum_analyze_scale_factor')::float8 AS analyze_factor,
            current_setting('autovacuum_analyze_threshold')::float8 AS analyze_threshold,
            current_setting('autovacuum_vacuum_scale_factor')::float8 AS vacuum_factor,
            current_setting('autovacuum_vacuum_threshold')::float8 AS vacuum_threshold
),
tt AS (
    SELECT
        n.nspname,
        c.relname,
        c.oid AS relid,
        t.n_dead_tup,
        t.n_mod_since_analyze,
        c.reltuples * s.vacuum_factor + s.vacuum_threshold AS v_threshold,
        c.reltuples * s.analyze_factor + s.analyze_threshold AS a_threshold
    FROM
        s,
        pg_class c
        JOIN pg_namespace n ON c.relnamespace = n.oid
        JOIN pg_stat_all_tables t ON c.oid = t.relid
    WHERE
        c.relkind = 'r'
        AND n.nspname NOT LIKE ALL (ARRAY['information_schema',
            'pg_catalog',
            'pg_toast',
            'pg_temp%']))
SELECT
    'MEDIUM' AS severity,
    'Table Health' AS category,
    'Outdated Statistics' AS check_name,
    quote_ident(nspname) || '.' || quote_ident(relname) AS object_name,
    'Table statistics are outdated, which can lead to poor query plans' AS issue_description,
    'Dead tuples: ' || n_dead_tup || ' (threshold: ' || round(v_threshold) || '), ' || 'Modifications since analyze: ' || n_mod_since_analyze || ' (threshold: ' || round(a_threshold) || ')' AS current_value,
    CASE WHEN n_dead_tup > v_threshold
        AND n_mod_since_analyze > a_threshold THEN
        'Run VACUUM ANALYZE'
    WHEN n_dead_tup > v_threshold THEN
        'Run VACUUM'
    WHEN n_mod_since_analyze > a_threshold THEN
        'Run ANALYZE'
    END AS recommended_action,
    'https://www.postgresql.org/docs/current/routine-vacuuming.html#AUTOVACUUM,
        https://www.depesz.com/2020/01/29/which-tables-should-be-auto-vacuumed-or-auto-analyzed/' AS documentation_link,
    3 AS severity_order
FROM
    tt
WHERE
    n_dead_tup > v_threshold
    OR n_mod_since_analyze > a_threshold
ORDER BY
    nspname,
    relname;
    -- credit: https://www.depesz.com/2020/01/29/which-tables-should-be-auto-vacuumed-or-auto-analyzed -- Thanks depesz!
    -- MEDIUM: Low index usage efficiency
    INSERT INTO health_results
    SELECT
        'MEDIUM' AS severity,
        'Table Health' AS category,
        'Low Index Efficiency' AS check_name,
        quote_ident(schemaname) || '.' || quote_ident(indexrelname) AS object_name,
        'Index has low scan to tuple read ratio indicating poor selectivity' AS issue_description,
        'Scans: ' || idx_scan || ', Tuples: ' || idx_tup_read || ' (Ratio: ' || ROUND(idx_tup_read::numeric / nullif (idx_scan, 0), 2) || ')' AS current_value,
        'Review index definition and query patterns, consider partial indexes' AS recommended_action,
        'https://www.postgresql.org/docs/current/indexes-partial.html' AS documentation_link,
        3 AS severity_order
    FROM
        pg_stat_user_indexes psi
    WHERE
        idx_scan > 100
        AND idx_tup_read::numeric / nullif (idx_scan, 0) > 1000;
    -- MEDIUM: Replication slots with high wal retation (90% of max wal)
    INSERT INTO health_results WITH q AS (
        SELECT
            slot_name,
            plugin,
            DATABASE,
            restart_lsn,
            CASE WHEN 'invalidation_reason' IS NOT NULL THEN
                'invalid'
            ELSE
                CASE WHEN active IS TRUE THEN
                    'active'
                ELSE
                    'inactive'
            END
            END AS "status",
            pg_size_pretty(pg_wal_lsn_diff (pg_current_wal_lsn (), restart_lsn)) AS "retained_wal",
            pg_size_pretty(safe_wal_size) AS "safe_wal_size"
        FROM
            pg_replication_slots
        WHERE
            pg_wal_lsn_diff (pg_current_wal_lsn (), restart_lsn) >= (safe_wal_size * 0.9))
    SELECT
        'MEDIUM' AS severity,
        'Replication Health' AS category,
        'Replication Slots Near Max Wal Size' AS check_name,
        'Slot name:' || slot_name AS object_name,
        'Target replication slot has retained close to 90% of the max wal size' AS issue_description,
        'Retained wal:' || retained_wal || ' safe_wal_size:' || safe_wal_size AS current_value,
        'Consider implementing a heartbeat table or using pg_logical_emit_message()' AS recommended_action,
        'https://www.morling.dev/blog/mastering-postgres-replication-slots' AS documentation_link,
        3 AS severity_order
    FROM
        q
    ORDER BY
        slot_name;
    -- MEDIUM: Large sequential scans
    INSERT INTO health_results
    SELECT
        'MEDIUM' AS severity,
        'Query Health' AS category,
        'Excessive Sequential Scans' AS check_name,
        quote_ident(schemaname) || '.' || quote_ident(relname) AS object_name,
        'Table has high sequential scan activity, may benefit from additional indexes' AS issue_description,
        'Sequential scans: ' || seq_scan || ', Tuples read: ' || seq_tup_read AS current_value,
        'Analyze query patterns and consider adding appropriate indexes' AS recommended_action,
        'https://www.postgresql.org/docs/current/using-explain.html' AS documentation_link,
        3 AS severity_order
    FROM
        pg_stat_user_tables
    WHERE
        seq_scan > 1000
        AND seq_tup_read > seq_scan * 10000;
    -- MEDIUM: Table with more than 50 columns
    WITH cc AS (
        SELECT
            table_schema,
            table_name,
            COUNT(*) AS column_count
        FROM
            information_schema.columns tc
        WHERE
            table_schema NOT IN ('pg_catalog', 'information_schema')
        GROUP BY
            table_schema,
            table_name
        ORDER BY
            column_count DESC)
    INSERT INTO health_results
    SELECT
        'MEDIUM' AS severity,
        'Table Health' AS category,
        'Table with more than 50 columns' AS check_name,
        cc.table_schema || '.' || cc.table_name AS object_name,
        'Postgres has a hard 1600 column limit, but that also includes columns you have dropped. Continuing to widen your table can impact performance.' AS issue_description,
        cc.column_count AS current_value,
        'The most straightforward recommendation is to split your table into more tables connected via foreign keys. However, your situation may very based on the type of data stored. Consider the documentation links to learn more.' AS recommended_action,
        'https://www.tigerdata.com/learn/designing-your-database-schema-wide-vs-narrow-postgres-tables \
	 https://nerderati.com/postgresql-tables-can-have-at-most-1600-columns \
     https://www.postgresql.org/docs/current/limits.html' AS documentation_link,
        3 AS severity_order
    FROM
        cc
    WHERE
        cc.column_count BETWEEN 50 AND 199;
    -- MEDIUM: Connection and lock monitoring
    INSERT INTO health_results
    SELECT
        'MEDIUM' AS severity,
        'System Health' AS category,
        'High Connection Count' AS check_name,
        'Database Connections' AS object_name,
        'High number of active connections may impact performance' AS issue_description,
        COUNT(*)::text || ' active connections' AS current_value,
        'Monitor connection pooling and consider adjusting max_connections' AS recommended_action,
        'https://www.postgresql.org/docs/current/runtime-config-connection.html' AS documentation_link,
        3 AS severity_order
    FROM
        pg_stat_activity
    WHERE
        state = 'active'
    GROUP BY
        1,
        2,
        3,
        4,
        5,
        7,
        8,
        9
    HAVING
        COUNT(*) > 50;
    -- MEDIUM: Tables larger than 50GB
    WITH ts AS (
        SELECT
            table_schema,
            table_name,
            pg_relation_size('"' || table_schema || '"."' || table_name || '"') AS size_bytes,
            pg_size_pretty(pg_relation_size('"' || table_schema || '"."' || table_name || '"')) AS size_pretty
        FROM
            information_schema.tables
        WHERE
            table_type = 'BASE TABLE'
            AND pg_relation_size('"' || table_schema || '"."' || table_name || '"') BETWEEN 53687091200 AND 107374182400
        ORDER BY
            size_bytes DESC)
    INSERT INTO health_results
    SELECT
        'MEDIUM' AS severity,
        'Table Health' AS category,
        'Tables larger than 100GB' AS check_name,
        ts.table_schema || '"."' || ts.table_name AS object_name,
        'The following table' AS description,
        ts.size_pretty AS current_value,
        'Tables larger than 50GB should be monitored and reviewed if a data archiving or removal process should be implemented. I suggest looking into partitioning tables, if possible.' AS recommended_action,
        'https://www.heroku.com/blog/handling-very-large-tables-in-postgres-using-partitioning/' AS documentation_link,
        3 AS severity_order
    FROM
        ts;
    -- MEDIUM: Queries running longer than 5 minutes
    INSERT INTO health_results
    SELECT
        'MEDIUM' AS severity,
        'Query Health' AS category,
        'Long Running Queries' AS check_name,
        concat_ws(' | ', 'pid: ' || pgs.pid::text, 'usename: ' || pgs.usename, 'datname: ' || pgs.datname, 'client_address: ' || pgs.client_addr::text, 'state: ' || pgs.state, 'duration: ' || to_char(now() - query_start, 'HH24:MI:SS')) AS object_name,
        'The following query has been running for more than 5 minutes. Might be helpful to see if this is expected behavior' AS issue_description,
        query AS current_value,
        'Review query using EXPLAIN ANALYZE to identify any bottlenecks, such as full table scans, missing indexes, etc' AS recommendation_action,
        'https://www.postgresql.org/docs/current/using-explain.html#USING-EXPLAIN-ANALYZE' AS documentation_link
    FROM
        pg_stat_activity pgs
    WHERE
        state = 'active'
        AND now() - query_start > interval '5 minutes'
    ORDER BY
        (now() - query_start) DESC;
    -- LOW: Missing indexes on foreign keys
    INSERT INTO health_results
    SELECT
        'LOW' AS severity,
        'Table Health' AS category,
        'Missing FK Index' AS check_name,
        n.nspname || '.' || t.relname || '.' || string_agg(a.attname, ', ') AS object_name,
        'Foreign key constraint missing supporting index for efficient joins' AS issue_description,
        'FK constraint without index' AS current_value,
        'Consider adding index on foreign key columns for better join performance' AS recommended_action,
        'https://www.postgresql.org/docs/current/ddl-constraints.html#DDL-CONSTRAINTS-FK' AS documentation_link,
        4 AS severity_order
    FROM
        pg_constraint c
        JOIN pg_class t ON c.conrelid = t.oid
        JOIN pg_namespace n ON t.relnamespace = n.oid
        JOIN pg_attribute a ON a.attrelid = t.oid
            AND a.attnum = ANY (c.conkey)
    WHERE
        c.contype = 'f'
        AND n.nspname NOT LIKE ALL (ARRAY['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
        AND NOT EXISTS (
            SELECT
                1
            FROM
                pg_index i
            WHERE
                i.indrelid = c.conrelid
                AND i.indkey::int2[] @> c.conkey::int2[])
    GROUP BY
        n.nspname,
        t.relname,
        c.conname,
        1,
        2,
        3,
        5,
        6,
        7,
        8,
        9;
    -- INFO: Database size and growth
    INSERT INTO health_results
    SELECT
        'INFO' AS severity,
        'Database Health' AS category,
        'Database Size' AS check_name,
        current_database() AS object_name,
        'Current database size information' AS issue_description,
        pg_size_pretty(pg_database_size(current_database())) AS current_value,
        'Monitor growth trends and plan capacity accordingly' AS recommended_action,
        'https://www.postgresql.org/docs/current/diskusage.html' AS documentation_link,
        5 AS severity_order;
    -- INFO: Version and configuration
    INSERT INTO health_results
    SELECT
        'INFO' AS severity,
        'System Info' AS category,
        'PostgreSQL Version' AS check_name,
        'System' AS object_name,
        'Current PostgreSQL version and basic configuration' AS issue_description,
        version() AS current_value,
        'Keep PostgreSQL updated and review configuration settings' AS recommended_action,
        'https://www.postgresql.org/docs/current/upgrading.html' AS documentation_link,
        5 AS severity_order;
    -- INFO: Installed Extensions
    INSERT INTO health_results
    SELECT
        'INFO' AS severity,
        'System Info' AS category,
        'Installed Extension' AS check_name,
        'System' AS object_name,
        'Installed Postgres Extension' AS issue_description,
        pe.extname || ':' || pe.extversion AS current_value,
        'Before updating to the latest minor/major version of PG, verify extension compatability' AS recommended_action,
        'https://youtu.be/mpEdQm3TpE0?si=VMcHBo1VnDfGZvtI&t=937' AS documentation_link,
        --Link is from a fantastic talk from SCALE 22x on bugging pg_extension maintainers!
        5 AS severity_order
    FROM
        pg_extension pe;
    -- INFO: Server Uptime
    INSERT INTO health_results
    SELECT
        'INFO' AS severity,
        'System Info' AS category,
        'Server Uptime' AS check_name,
        'System' AS object_name,
        'Current Uptime of Server' AS issue_description,
        CURRENT_TIMESTAMP - pg_postmaster_start_time() AS current_value,
        'No Recommendation - Informational' AS recommended_action,
        'N/A' AS documentation_link,
        5 AS severity_order;
    -- INFO: Log Directory
    WITH ld AS (
        SELECT
            current_setting('log_directory') AS log_directory)
    INSERT INTO health_results
    SELECT
        'INFO' AS severity,
        'System Info' AS category,
        'Is Logging Enabled' AS check_name,
        'System' AS object_name,
        'If no log file is present, this indicates logging is not enabled' AS issue_description,
        ld.log_directory AS current_value,
        'Logging enabled will assist with troubleshooting future issues. Dont you like logs?' AS recommended_action,
        'For self-hosting: https://www.postgresql.org/docs/current/runtime-config-logging.html /
         For AWS Aurora/RDS: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.overview.parameter-groups.html  /
         For GCP Cloud SQL: https://docs.cloud.google.com/sql/docs/postgres/flags /
         For Azure Database for PostgreSQL: https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-server-parameters
        ' AS documentation_link,
        5 AS severity_order
    FROM
        ld;
    -- INFO: Log File(s) Size(s)
    WITH ls AS (
        SELECT
            ROUND(sum(stat.size) / (1024.0 * 1024.0), 2) || ' MB' AS size_mb
        FROM
            pg_ls_dir(current_setting('log_directory')) AS logs
        CROSS JOIN LATERAL pg_stat_file(current_setting('log_directory') || '/' || logs) AS stat)
INSERT INTO health_results
SELECT
    'INFO' AS severity,
    'System Info' AS category,
    'Size of ALL Logfiles combined' AS check_name,
    'System' AS object_name,
    'Monitoring your logfile size will prevent from filling up storage (or expanding your storage in cloud managed). This can also lead to the server cashing when the logfile cannot be saved.' AS issue_description,
    ls.size_mb AS current_value,
    'Set log_rotation_age and size for proper rotation of log files. This will prevent runaway log sizes.' AS recommended_action,
    'For self-hosting:https://www.postgresql.org/docs/current/runtime-config-logging.html /
         For AWS Aurora/RDS: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.overview.parameter-groups.html  /
         For GCP Cloud SQL: https://docs.cloud.google.com/sql/docs/postgres/flags /
         For Azure Database for PostgreSQL: https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-server-parameters
        ' AS documentation_link,
    5 AS severity_order
FROM
    ls;
    -- INFO: Location of Data Directory
    WITH dd AS (
        SELECT
            name,
            setting
        FROM
            pg_settings
        WHERE
            category = 'File Locations'
            AND name = 'data_directory')
    INSERT INTO health_results
    SELECT
        'INFO' AS severity,
        'System Info' AS category,
        'Location of data_dir' AS check_name,
        dd.name AS object_name,
        'Mainly relevant to self-hosted/self-managed instances.' AS issue_description,
        dd.setting AS current_value,
        'When possible, setting your data directory to a seperate mounted drive dedicated to storing the database file is best practice. This is more of an informational systems check' AS recommended_action,
        'For how to move to a seperate drive: https://www.digitalocean.com/community/tutorials/how-to-move-a-postgresql-data-directory-to-a-new-location-on-ubuntu-22-04' AS documentation_link,
        5 AS severity_order
    FROM
        dd;
    -- Return results ordered by severity
    RETURN QUERY
    SELECT
        hr.severity,
        hr.category,
        hr.check_name,
        hr.object_name,
        hr.issue_description,
        hr.current_value,
        hr.recommended_action,
        hr.documentation_link
    FROM
        health_results hr
    ORDER BY
        hr.severity_order,
        hr.category,
        hr.check_name;
    -- Clean up
    DROP TABLE health_results;
END;
$$
LANGUAGE plpgsql;
