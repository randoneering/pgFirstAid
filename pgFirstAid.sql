create or replace function pg_firstAid()
returns table (
    severity TEXT,
    category TEXT,
    check_name TEXT,
    object_name TEXT,
    issue_description TEXT,
    current_value TEXT,
    recommended_action TEXT,
    documentation_link TEXT
) as $$
begin
    create temp table health_results (
        severity TEXT,
        category TEXT,
        check_name TEXT,
        object_name TEXT,
        issue_description TEXT,
        current_value TEXT,
        recommended_action TEXT,
        documentation_link TEXT,
        severity_order INTEGER
    );

    -- 1. CRITICAL: Tables without primary keys
    insert into health_results
    select
        'CRITICAL' as severity,
        'Table Structure' as category,
        'Missing Primary Key' as check_name,
        pt.schemaname || '.' || pt.tablename as object_name,
        'Table missing a primary key, which can cause replication issues and/or poor performance' as issue_description,
        'No primary key defined' as current_value,
        'Add a primary key or unique constraint with NOT NULL columns' as recommended_action,
        'https://www.postgresql.org/docs/current/ddl-constraints.html#DDL-CONSTRAINTS-PRIMARY-KEYS' as documentation_link,
        1 as severity_order
    from pg_tables pt
    where pt.schemaname not in ('information_schema', 'pg_catalog', 'pg_toast')
    and not exists (
        select 1
        from pg_constraint pc
        join pg_class c on pc.conrelid = c.oid
        join pg_namespace n on c.relnamespace = n.oid
        where pc.contype = 'p'
        and n.nspname = pt.schemaname
        and c.relname = pt.tablename
    );

    -- 2. CRITICAL: Unused indexes consuming significant space
    insert into health_results
    select
        'CRITICAL' as severity,
        'Index Management' as category,
        'Unused Large Index' as check_name,
        psi.schemaname || '.' || psio.indexrelname as object_name,
        'Large unused index consuming disk space and potentially impacting write performance' as issue_description,
        pg_size_pretty(pg_relation_size(quote_ident(psi.schemaname) || '.' || quote_ident(psio.indexrelname))) || ' (0 scans)' as current_value,
        'Consider dropping this index if truly unused after monitoring usage patterns. Never drop an index without validating usage!' as recommended_action,
        'https://www.postgresql.org/docs/current/sql-dropindex.html' as documentation_link,
        1 as severity_order
    from pg_stat_user_indexes psi
    join pg_statio_user_indexes psio on psi.indexrelid = psio.indexrelid
    where idx_scan = 0
    and pg_relation_size(quote_ident(psi.schemaname) || '.' || quote_ident(psi.relname)) > 10485760;

    -- 3. HIGH: Tables with high bloat
    insert into health_results
    select
        'HIGH' as severity,
        'Table Maintenance' as category,
        'Table Bloat' as check_name,
        pt.schemaname || '.' || pt.tablename as object_name,
        'Table has significant bloat affecting performance and storage' as issue_description,
        'Estimated bloat: ' || ROUND(
            case when pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename)) > 0
            then (pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename)) - 
                  pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename), 'main')) * 100.0 / 
                  pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename))
            else 0 end, 2
        ) || '%' as current_value,
        'Run VACUUM FULL to reclaim space' as recommended_action,
        'https://www.postgresql.org/docs/current/sql-vacuum.html' as documentation_link,
        2 as severity_order
    from pg_tables pt
    where pt.schemaname not in ('information_schema', 'pg_catalog', 'pg_toast')
    and pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename)) > 104857600
    and (pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename)) - 
         pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename), 'main')) * 100.0 / 
         nullif(pg_relation_size(quote_ident(pt.schemaname) || '.' || quote_ident(pt.tablename)), 0) > 20;

    -- 4. HIGH: Tables never analyzed
    insert into health_results
    select
        'HIGH' as severity,
        'Statistics' as category,
        'Missing Statistics' as check_name,
        schemaname || '.' || relname as object_name,
        'Table has never been analyzed, query planner missing statistics' as issue_description,
        'Last analyze: Never' as current_value,
        'Run ANALYZE on this table or enable auto-analyze' as recommended_action,
        'https://www.postgresql.org/docs/current/sql-analyze.html' as documentation_link,
        2 as severity_order
    from pg_stat_user_tables pt
    where last_analyze is null
    and last_autoanalyze is null
    and n_tup_ins + n_tup_upd + n_tup_del > 1000;

    -- 5. HIGH: Duplicate or redundant indexes
    insert into health_results
    select
        'HIGH' as severity,
        'Index Optimization' as category,
        'Duplicate Index' as check_name,
        i1.schemaname || '.' || i1.indexname || ' & ' || i2.indexname as object_name,
        'Multiple indexes with identical or overlapping column sets' as issue_description,
        'Indexes: ' || i1.indexname || ', ' || i2.indexname as current_value,
        'Review and consolidate duplicate indexes and focus on keeping the most efficient one' as recommended_action,
        'https://www.postgresql.org/docs/current/indexes-multicolumn.html' as documentation_link,
        2 as severity_order
    from pg_indexes i1
    join pg_indexes i2 on i1.schemaname = i2.schemaname
        and i1.tablename = i2.tablename
        and i1.indexname < i2.indexname
        and i1.indexdef = i2.indexdef
    where i1.schemaname not in ('information_schema', 'pg_catalog');

    -- 6. MEDIUM: Tables with outdated statistics
    insert into health_results
    select
        'MEDIUM' as severity,
        'Statistics' as category,
        'Outdated Statistics' as check_name,
        schemaname || '.' || relname as object_name,
        'Table statistics are outdated, which can lead to poor query plans' as issue_description,
        'Last analyze: ' || coalesce(last_analyze::text, 'Never') ||
        ' (modifications: ' || n_tup_ins + n_tup_upd + n_tup_del || ')' as current_value,
        'Run ANALYZE or increase autovacuum_analyze_scale_factor' as recommended_action,
        'https://www.postgresql.org/docs/current/routine-vacuuming.html#AUTOVACUUM' as documentation_link,
        3 as severity_order
    from pg_stat_user_tables
    where (last_analyze < NOW() - interval '7 days' or last_autoanalyze < NOW() - interval '7 days')
    and n_tup_ins + n_tup_upd + n_tup_del > n_tup_ins * 0.1;

    -- 7. MEDIUM: Low index usage efficiency
    insert into health_results
    select
        'MEDIUM' as severity,
        'Index Performance' as category,
        'Low Index Efficiency' as check_name,
        schemaname || '.' || indexrelname as object_name,
        'Index has low scan to tuple read ratio indicating poor selectivity' as issue_description,
        'Scans: ' || idx_scan || ', Tuples: ' || idx_tup_read ||
        ' (Ratio: ' || ROUND(idx_tup_read::numeric / nullif(idx_scan, 0), 2) || ')' as current_value,
        'Review index definition and query patterns, consider partial indexes' as recommended_action,
        'https://www.postgresql.org/docs/current/indexes-partial.html' as documentation_link,
        3 as severity_order
    from pg_stat_user_indexes psi
    where idx_scan > 100
    and idx_tup_read::numeric / nullif(idx_scan, 0) > 1000;

    -- 8. MEDIUM: Large sequential scans
    insert into health_results
    select
        'MEDIUM' as severity,
        'Query Performance' as category,
        'Excessive Sequential Scans' as check_name,
        schemaname || '.' || relname as object_name,
        'Table has high sequential scan activity, may benefit from additional indexes' as issue_description,
        'Sequential scans: ' || seq_scan || ', Tuples read: ' || seq_tup_read as current_value,
        'Analyze query patterns and consider adding appropriate indexes' as recommended_action,
        'https://www.postgresql.org/docs/current/using-explain.html' as documentation_link,
        3 as severity_order
    from pg_stat_user_tables
    where seq_scan > 1000
    and seq_tup_read > seq_scan * 10000;

    -- 9. MEDIUM: Connection and lock monitoring
    insert into health_results
    select
        'MEDIUM' as severity,
        'System Health' as category,
        'High Connection Count' as check_name,
        'Database Connections' as object_name,
        'High number of active connections may impact performance' as issue_description,
        COUNT(*)::text || ' active connections' as current_value,
        'Monitor connection pooling and consider adjusting max_connections' as recommended_action,
        'https://www.postgresql.org/docs/current/runtime-config-connection.html' as documentation_link,
        3 as severity_order
    from pg_stat_activity
    where state = 'active'
    group by 1, 2, 3, 4, 5, 7, 8, 9
    having COUNT(*) > 50;

    -- 10. LOW: Missing indexes on foreign keys
    insert into health_results
    select
        'LOW' as severity,
        'Index Recommendations' as category,
        'Missing FK Index' as check_name,
        n.nspname || '.' || t.relname || '.' || string_agg(a.attname, ', ') as object_name,
        'Foreign key constraint missing supporting index for efficient joins' as issue_description,
        'FK constraint without index' as current_value,
        'Consider adding index on foreign key columns for better join performance' as recommended_action,
        'https://www.postgresql.org/docs/current/ddl-constraints.html#DDL-CONSTRAINTS-FK' as documentation_link,
        4 as severity_order
    from pg_constraint c
    join pg_class t on c.conrelid = t.oid
    join pg_namespace n on t.relnamespace = n.oid
    join pg_attribute a on a.attrelid = t.oid and a.attnum = any(c.conkey)
    where c.contype = 'f'
    and n.nspname not in ('information_schema', 'pg_catalog')
    and not exists (
        select 1
        from pg_index i
        where i.indrelid = c.conrelid
        and i.indkey::int2[] @> c.conkey::int2[]
    )
    group by n.nspname, t.relname, c.conname, 1, 2, 3, 5, 6, 7, 8, 9;

    -- 11. INFO: Database size and growth
    insert into health_results
    select
        'INFO' as severity,
        'Database Health' as category,
        'Database Size' as check_name,
        current_database() as object_name,
        'Current database size information' as issue_description,
        pg_size_pretty(pg_database_size(current_database())) as current_value,
        'Monitor growth trends and plan capacity accordingly' as recommended_action,
        'https://www.postgresql.org/docs/current/diskusage.html' as documentation_link,
        5 as severity_order;

    -- 12. INFO: Version and configuration
    insert into health_results
    select
        'INFO' as severity,
        'System Info' as category,
        'PostgreSQL Version' as check_name,
        'System' as object_name,
        'Current PostgreSQL version and basic configuration' as issue_description,
        version() as current_value,
        'Keep PostgreSQL updated and review configuration settings' as recommended_action,
        'https://www.postgresql.org/docs/current/upgrading.html' as documentation_link,
        5 as severity_order;

    return QUERY
    select
        hr.severity,
        hr.category,
        hr.check_name,
        hr.object_name,
        hr.issue_description,
        hr.current_value,
        hr.recommended_action,
        hr.documentation_link
    from health_results hr
    order by hr.severity_order, hr.category, hr.check_name;

    drop table health_results;
end;
$$ language plpgsql;
