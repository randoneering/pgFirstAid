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
    pg_version varchar(255) --current version of Postgres

BEGIN
    /* uptime health check*/
    select current_timestamp - pg_postmaster_start_time() into uptime;
    --https://www.postgresql.org/docs/current/functions-info.html

    /* postgres version check*/

    show server_version in pg_version

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

    /* tables without primary keys check*/

    select
        pc.oid as table_name,
        pg_table_size(pc.oid) as table_size
    from
        pg_catalog.pg_class pc
        inner join pg_catalog.pg_namespace nsp on nsp.oid = pc.relnamespace
    where
        pc.relkind in ('r', 'p') and
        pc.oid not in (
            select c.conrelid as table_oid
            from pg_catalog.pg_constraint c
            where c.contype = 'p'
        ) and
        nsp.nspname = 'public' --Need to add variable here for schema selection, or provide an option to select all
    order by table_name;
    /*
    Details for first section of the check-making sure we are grabing normal tables and partitioned tables
    https://www.postgresql.org/docs/current/catalog-pg-class.html
    r = ordinary table, i = index, S = sequence, t = TOAST table, v = view, m = materialized view, c = composite type, f = foreign table, p = partitioned table, I = partitioned index

    Details for subquery to ensure we are grabbing tables without primary key constraints
    https://www.postgresql.org/docs/current/catalog-pg-constraint.html
    c = check constraint, f = foreign key constraint, n = not-null constraint (domains only), p = primary key constraint, u = unique constraint, t = constraint trigger, x = exclusion constraint
    **/

    /* pg_extensions installed  */

    select * from pg_extension;


END


LANGUAGE SQL;
