create or replace
function pg_firstAid()
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
-- Create temporary table to collect all health check results
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
-- CRITICAL: Tables without primary keys
    insert
	into
	health_results
    select
	'CRITICAL' as severity,
	'Table Structure' as category,
	'Missing Primary Key' as check_name,
	quote_ident(pt.schemaname) || '.' || quote_ident(tablename) as object_name,
	'Table missing a primary key, which can cause replication issues and/or poor performance' as issue_description,
	'No primary key defined' as current_value,
	'Add a primary key or unique constraint with NOT NULL columns' as recommended_action,
	'https://www.postgresql.org/docs/current/ddl-constraints.html#DDL-CONSTRAINTS-PRIMARY-KEYS' as documentation_link,
	1 as severity_order
from
	pg_tables pt
where
	pt.schemaname not like all(array['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
	and not exists (
	select
		1
	from
		pg_constraint pc
	join pg_class c on
		pc.conrelid = c.oid
	join pg_namespace n on
		c.relnamespace = n.oid
	where
		pc.contype = 'p'
		and n.nspname = pt.schemaname
		and c.relname = pt.tablename
    );
-- CRITICAL: Unused indexes consuming significant space
    insert
	into
	health_results
	select
	'CRITICAL' as severity,
	'Index Management' as category,
	'Unused Large Index' as check_name,
	quote_ident(psi.schemaname) || '.' || quote_ident(psio.indexrelname) as object_name,
	'Large unused index consuming disk space and potentially impacting write performance' as issue_description,
	pg_size_pretty(pg_relation_size(psi.indexrelid)) || ' (0 scans)' as current_value,
	'Consider dropping this index if truly unused after monitoring usage patterns. Never drop an index without validating usage!' as recommended_action,
	'https://www.postgresql.org/docs/current/sql-dropindex.html' as documentation_link,
	1 as severity_order
from
	pg_stat_user_indexes psi
join pg_statio_user_indexes psio on
	psi.indexrelid = psio.indexrelid
where
	idx_scan = 0
	and pg_relation_size(psi.indexrelid) > 104857600;
-- 100MB
-- HIGH: Inactive Replication slots
    insert
	into
	health_results
with q as (
	select
		slot_name,
		plugin,
		database,
		restart_lsn,
		case
			when 'invalidation_reason' is not null then 'invalid'
			else
          case
				when active is true then 'active'
				else 'inactive'
			end
		end as "status",
		pg_size_pretty(
        pg_wal_lsn_diff(
          pg_current_wal_lsn(), restart_lsn)) as "retained_wal",
		pg_size_pretty(safe_wal_size) as "safe_wal_size"
	from
		pg_replication_slots
	where
		'status' = 'inactive'
    )
    select
	'HIGH' as severity,
	'Replication Health' as category,
	'Inactive Replication Slots' as check_name,
	'Slot name:' || slot_name as object_name,
	'Target replication slot is inactive' as issue_description,
	'Retained wal:' || retained_wal || ' database:' || database as current_value,
	'If the replication slot is no longer needed, drop the slot' as recommended_action,
	'https://www.morling.dev/blog/mastering-postgres-replication-slots' as documentation_link,
	2 as severity_order
from
	q
order by
	slot_name;
-- credit: https://www.morling.dev/blog/mastering-postgres-replication-slots/ -- Thank you Gunnar Morling!
-- HIGH: Tables with high bloat
insert
	into
	health_results
with q as (
	select
		current_database(),
		schemaname,
		tblname,
		bs * tblpages as real_size,
		(tblpages-est_tblpages)* bs as extra_size,
		case
			when tblpages > 0
				and tblpages - est_tblpages > 0
    then 100 * (tblpages - est_tblpages)/ tblpages::float
				else 0
			end as extra_pct,
			fillfactor,
			case
				when tblpages - est_tblpages_ff > 0
    then (tblpages-est_tblpages_ff)* bs
				else 0
			end as bloat_size,
			case
				when tblpages > 0
					and tblpages - est_tblpages_ff > 0
    then 100 * (tblpages - est_tblpages_ff)/ tblpages::float
					else 0
				end as bloat_pct,
				is_na
			from
				(
				select
					ceil( reltuples / ( (bs-page_hdr)/ tpl_size ) ) + ceil( toasttuples / 4 ) as est_tblpages,
					ceil( reltuples / ( (bs-page_hdr)* fillfactor /(tpl_size * 100) ) ) + ceil( toasttuples / 4 ) as est_tblpages_ff,
					tblpages,
					fillfactor,
					bs,
					tblid,
					schemaname,
					tblname,
					heappages,
					toastpages,
					is_na
				from
					(
					select
						( 4 + tpl_hdr_size + tpl_data_size + (2 * ma)
        - case
							when tpl_hdr_size%ma = 0 then ma
							else tpl_hdr_size%ma
						end
        - case
							when ceil(tpl_data_size)::int%ma = 0 then ma
							else ceil(tpl_data_size)::int%ma
						end
      ) as tpl_size,
						bs - page_hdr as size_per_block,
						(heappages + toastpages) as tblpages,
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
					from
						(
						select
							tbl.oid as tblid,
							ns.nspname as schemaname,
							tbl.relname as tblname,
							tbl.reltuples,
							tbl.relpages as heappages,
							coalesce(toast.relpages, 0) as toastpages,
							coalesce(toast.reltuples, 0) as toasttuples,
							coalesce(substring(
          array_to_string(tbl.reloptions, ' ')
          from 'fillfactor=([0-9]+)')::smallint, 100) as fillfactor,
							current_setting('block_size')::numeric as bs,
							case
								when version()~ 'mingw32'
									or version()~ '64-bit|x86_64|ppc64|ia64|amd64' then 8
									else 4
								end as ma,
								24 as page_hdr,
								23 + case
									when MAX(coalesce(s.null_frac, 0)) > 0 then ( 7 + count(s.attname) ) / 8
									else 0::int
								end
           + case
									when bool_or(att.attname = 'oid' and att.attnum < 0) then 4
									else 0
								end as tpl_hdr_size,
								sum( (1-coalesce(s.null_frac, 0)) * coalesce(s.avg_width, 0) ) as tpl_data_size,
								bool_or(att.atttypid = 'pg_catalog.name'::regtype)
									or sum(case when att.attnum > 0 then 1 else 0 end) <> count(s.attname) as is_na
								from
									pg_attribute as att
								join pg_class as tbl on
									att.attrelid = tbl.oid
								join pg_namespace as ns on
									ns.oid = tbl.relnamespace
								left join pg_stats as s on
									s.schemaname = ns.nspname
									and s.tablename = tbl.relname
									and s.inherited = false
									and s.attname = att.attname
								left join pg_class as toast on
									tbl.reltoastrelid = toast.oid
								where
									not att.attisdropped
									and tbl.relkind in ('r', 'm')
								group by
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
								order by
									2,
									3
    ) as s
  ) as s2
) as s3)
select
	'HIGH' as severity,
	'Table Maintenance' as category,
	'Table Bloat (Detailed)' as check_name,
	quote_ident(schemaname) || '.' || quote_ident(tblname) as object_name,
	'Table has significant bloat (>50%) affecting performance and storage' as issue_description,
	'Real size: ' || pg_size_pretty(real_size::bigint) ||
    ', Bloat: ' || pg_size_pretty(bloat_size::bigint) ||
    ' (' || ROUND(bloat_pct::numeric, 2) || '%)' as current_value,
	'Run VACUUM FULL to reclaim space' as recommended_action,
	'https://www.postgresql.org/docs/current/sql-vacuum.html,
    https://github.com/ioguix/pgsql-bloat-estimation/' as documentation_link,
	2 as severity_order
from
	q
where
	bloat_pct > 50.0
    and schemaname not like all(array['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
order by
	quote_ident(schemaname),
	quote_ident(tblname);
--Credit: https://github.com/ioguix/pgsql-bloat-estimation -- Jehan-Guillaume (ioguix) de Rorthais!
-- HIGH: Tables never analyzed
    insert
	into
	health_results
    select
	'HIGH' as severity,
	'Statistics' as category,
	'Missing Statistics' as check_name,
	quote_ident(schemaname) || '.' || quote_ident(relname) as object_name,
	'Table has never been analyzed, query planner missing statistics' as issue_description,
	'Last analyze: Never' as current_value,
	'Run ANALYZE on this table or enable auto-analyze' as recommended_action,
	'https://www.postgresql.org/docs/current/sql-analyze.html' as documentation_link,
	2 as severity_order
from
	pg_stat_user_tables pt
where
	last_analyze is null
	and last_autoanalyze is null
	and n_tup_ins + n_tup_upd + n_tup_del > 1000;
-- HIGH: Duplicate or redundant indexes
    insert
	into
	health_results
    select
	'HIGH' as severity,
	'Index Optimization' as category,
	'Duplicate Index' as check_name,
	quote_ident(i1.schemaname) || '.' || i1.indexname || ' & ' || i2.indexname as object_name,
	'Multiple indexes with identical or overlapping column sets' as issue_description,
	'Indexes: ' || i1.indexname || ', ' || i2.indexname as current_value,
	'Review and consolidate duplicate indexes and focus on keeping the most efficient one' as recommended_action,
	'https://www.postgresql.org/docs/current/indexes-multicolumn.html' as documentation_link,
	2 as severity_order
from
	pg_indexes i1
join pg_indexes i2 on
	i1.schemaname = i2.schemaname
	and i1.tablename = i2.tablename
	and i1.indexname < i2.indexname
	and i1.indexdef = i2.indexdef
where
	i1.schemaname not like all(array['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%']);
-- MEDIUM: Tables with outdated statistics
    insert
	into
	health_results
	with s as (
	select
		current_setting('autovacuum_analyze_scale_factor')::float8 as analyze_factor,
		current_setting('autovacuum_analyze_threshold')::float8 as analyze_threshold,
		current_setting('autovacuum_vacuum_scale_factor')::float8 as vacuum_factor,
		current_setting('autovacuum_vacuum_threshold')::float8 as vacuum_threshold
    ),
	tt as (
	select
		n.nspname,
		c.relname,
		c.oid as relid,
		t.n_dead_tup,
		t.n_mod_since_analyze,
		c.reltuples * s.vacuum_factor + s.vacuum_threshold as v_threshold,
		c.reltuples * s.analyze_factor + s.analyze_threshold as a_threshold
	from
		s,
		pg_class c
	join pg_namespace n on
		c.relnamespace = n.oid
	join pg_stat_all_tables t on
		c.oid = t.relid
	where
		c.relkind = 'r'
		and n.nspname not like all(array['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
    )
    select
	'MEDIUM' as severity,
	'Statistics' as category,
	'Outdated Statistics' as check_name,
	quote_ident(nspname) || '.' || quote_ident(relname) as object_name,
	'Table statistics are outdated, which can lead to poor query plans' as issue_description,
	'Dead tuples: ' || n_dead_tup || ' (threshold: ' || round(v_threshold) || '), ' ||
        'Modifications since analyze: ' || n_mod_since_analyze || ' (threshold: ' || round(a_threshold) || ')' as current_value,
	case
		when n_dead_tup > v_threshold
		and n_mod_since_analyze > a_threshold then 'Run VACUUM ANALYZE'
		when n_dead_tup > v_threshold then 'Run VACUUM'
		when n_mod_since_analyze > a_threshold then 'Run ANALYZE'
	end as recommended_action,
	'https://www.postgresql.org/docs/current/routine-vacuuming.html#AUTOVACUUM,
        https://www.depesz.com/2020/01/29/which-tables-should-be-auto-vacuumed-or-auto-analyzed/' as documentation_link,
	3 as severity_order
from
	tt
where
	n_dead_tup > v_threshold
	or n_mod_since_analyze > a_threshold
order by
	nspname,
	relname;
-- credit: https://www.depesz.com/2020/01/29/which-tables-should-be-auto-vacuumed-or-auto-analyzed -- Thanks depesz!
-- MEDIUM: Low index usage efficiency
    insert
	into
	health_results
    select
	'MEDIUM' as severity,
	'Index Performance' as category,
	'Low Index Efficiency' as check_name,
	quote_ident(schemaname) || '.' || quote_ident(indexrelname) as object_name,
	'Index has low scan to tuple read ratio indicating poor selectivity' as issue_description,
	'Scans: ' || idx_scan || ', Tuples: ' || idx_tup_read ||
        ' (Ratio: ' || ROUND(idx_tup_read::numeric / nullif(idx_scan, 0), 2) || ')' as current_value,
	'Review index definition and query patterns, consider partial indexes' as recommended_action,
	'https://www.postgresql.org/docs/current/indexes-partial.html' as documentation_link,
	3 as severity_order
from
	pg_stat_user_indexes psi
where
	idx_scan > 100
	and idx_tup_read::numeric / nullif(idx_scan, 0) > 1000;
-- MEDIUM: Replication slots with high wal retation (90% of max wal)
insert
	into
	health_results
with q as (
	select
		slot_name,
		plugin,
		database,
		restart_lsn,
		case
			when 'invalidation_reason' is not null then 'invalid'
			else
      case
				when active is true then 'active'
				else 'inactive'
			end
		end as "status",
		pg_size_pretty(
    pg_wal_lsn_diff(
      pg_current_wal_lsn(), restart_lsn)) as "retained_wal",
		pg_size_pretty(safe_wal_size) as "safe_wal_size"
	from
		pg_replication_slots
	where
		pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) >= (safe_wal_size * 0.9)
)
select
		'MEDIUM' as severity,
		'Replication Health' as category,
		'Replication Slots Near Max Wal Size' as check_name,
		'Slot name:' || slot_name as object_name,
		'Target replication slot has retained close to 90% of the max wal size' as issue_description,
		'Retained wal:' || retained_wal || ' safe_wal_size:' || safe_wal_size as current_value,
		'Consider implementing a heartbeat table or using pg_logical_emit_message()' as recommended_action,
		'https://www.morling.dev/blog/mastering-postgres-replication-slots' as documentation_link,
		3 as severity_order
from
		q
order by
		slot_name;
-- MEDIUM: Large sequential scans
    insert
	into
	health_results
    select
	'MEDIUM' as severity,
	'Query Performance' as category,
	'Excessive Sequential Scans' as check_name,
	quote_ident(schemaname) || '.' || quote_ident(relname) as object_name,
	'Table has high sequential scan activity, may benefit from additional indexes' as issue_description,
	'Sequential scans: ' || seq_scan || ', Tuples read: ' || seq_tup_read as current_value,
	'Analyze query patterns and consider adding appropriate indexes' as recommended_action,
	'https://www.postgresql.org/docs/current/using-explain.html' as documentation_link,
	3 as severity_order
from
	pg_stat_user_tables
where
	seq_scan > 1000
	and seq_tup_read > seq_scan * 10000;
-- MEDIUM: Connection and lock monitoring
    insert
	into
	health_results
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
from
	pg_stat_activity
where
	state = 'active'
group by
	1,
	2,
	3,
	4,
	5,
	7,
	8,
	9
having
	COUNT(*) > 50;
-- MEDIUM: Queries running longer than 5 minutes
    insert
	into
	health_results
    select
	'MEDIUM' as severity,
	'Query Performance' as category,
	'Long Running Queries' as check_name,
	concat_ws(' | ',
            'pid: ' || pgs.pid::text,
            'usename: ' || pgs.usename,
            'datname: ' || pgs.datname,
            'client_address: ' || pgs.client_addr::text,
            'state: ' || pgs.state,
            'duration: ' || to_char(now() - query_start, 'HH24:MI:SS')
        ) as object_name,
	'The following query has been running for more than 5 minutes. Might be helpful to see if this is expected behavior' as issue_description,
	query as current_value,
	'Review query using EXPLAIN ANALYZE to identify any bottlenecks, such as full table scans, missing indexes, etc' as recommendation_action,
	'https://www.postgresql.org/docs/current/using-explain.html#USING-EXPLAIN-ANALYZE' as documentation_link
from
	pg_stat_activity pgs
where
	state = 'active'
	and now() - query_start > interval '5 minutes'
order by
	(now() - query_start) desc;
-- LOW: Missing indexes on foreign keys
    insert
	into
	health_results
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
from
	pg_constraint c
join pg_class t on
	c.conrelid = t.oid
join pg_namespace n on
	t.relnamespace = n.oid
join pg_attribute a on
	a.attrelid = t.oid
	and a.attnum = any(c.conkey)
where
	c.contype = 'f'
	and n.nspname not like all(array['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
	and not exists (
	select
		1
	from
		pg_index i
	where
		i.indrelid = c.conrelid
		and i.indkey::int2[] @> c.conkey::int2[]
    )
group by
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
    insert
	into
	health_results
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
-- INFO: Version and configuration
    insert
	into
	health_results
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
-- INFO: Installed Extensions
   insert
	into
	health_results
   select
	'INFO' as severity,
	'System Info' as category,
	'Installed Extension' as check_name,
	'System' as object_name,
	'Installed Postgres Extension' as issue_description,
	 pe.extname || ':' || pe.extversion as current_value,
	'Before updating to the latest minor/major version of PG, verify extension compatability' as recommended_action,
	'https://youtu.be/mpEdQm3TpE0?si=VMcHBo1VnDfGZvtI&t=937' as documentation_link,
	--Link is from a fantastic talk from SCALE 22x on bugging pg_extension maintainers!
	5 as severity_order
from
	pg_extension pe;
-- INFO: Server Uptime
    insert
	into
	health_results
    select
	'INFO' as severity,
	'System Info' as category,
	'Server Uptime' as check_name,
	'System' as object_name,
	'Current Uptime of Server' as issue_description,
	 current_timestamp - pg_postmaster_start_time() as current_value,
	'No Recommendation - Informational' as recommended_action,
	'N/A' as documentation_link,
	5 as severity_order;
-- INFO: Log Directory
    WITH ld AS (
        SELECT current_setting('log_directory') as log_directory
    )
    SELECT
        'INFO' as severity,
        'System Info' as category,
        'Is Logging Enabled' as check_name,
        'System' as object_name,
        'If no log file is present, this indicates logging is not enabled' as issue_description,
        ld.log_directory as current_value,
        'Logging enabled will assist with troubleshooting future issues. Dont you like logs?' as recommended_action,
        'For self-hosting: https://www.postgresql.org/docs/current/runtime-config-logging.html /
         For AWS Aurora/RDS: https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.Concepts.PostgreSQL.overview.parameter-groups.html  /
         For GCP Cloud SQL: https://docs.cloud.google.com/sql/docs/postgres/flags /
         For Azure Database for PostgreSQL: https://learn.microsoft.com/en-us/azure/postgresql/flexible-server/concepts-server-parameters
        ' as documentation_link,
        5 as severity_order
    FROM ld;
-- Return results ordered by severity
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
from
	health_results hr
order by
	hr.severity_order,
	hr.category,
	hr.check_name;
-- Clean up
    drop table health_results;
end;

$$ language plpgsql;
