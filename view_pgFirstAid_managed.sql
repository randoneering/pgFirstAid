-- Adding dropping of the view instead of replace because of conversion issues with new health checks.
-- This way we start with a fresh view.
drop view if exists v_pgfirstAid;

create view v_pgfirstAid as
-- CRITICAL: Tables without primary keys
    select
	'CRITICAL' as severity,
	'Table Health' as category,
	'Missing Primary Key' as check_name,
	quote_ident(pt.schemaname) || '.' || quote_ident(tablename) as object_name,
	'Table missing a primary key, which can cause replication issues and/or poor performance' as issue_description,
	'No primary key defined' as current_value,
	'Add a primary key or unique constraint with NOT NULL columns' as recommended_action,
	'https://www.postgresql.org/docs/current/ddl-constraints.html' as documentation_link,
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
    )
union all
-- CRITICAL: Unused indexes consuming significant space
	select
	'CRITICAL' as severity,
	'Table Health' as category,
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
	and pg_relation_size(psi.indexrelid) > 104857600
	-- 100MB
union all
-- HIGH: Inactive Replication slots
(with q as (
select
		slot_name,
		plugin,
		database,
		restart_lsn,
		case
			when active is true then 'active'
			else 'inactive'
		end as "status",
		pg_size_pretty(
        pg_wal_lsn_diff(
          pg_current_wal_lsn(), restart_lsn)) as "retained_wal",
		pg_size_pretty(safe_wal_size) as "safe_wal_size"
from
		pg_replication_slots
where
		active = false
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
	q)
union all
-- credit: https://www.morling.dev/blog/mastering-postgres-replication-slots/ -- Thank you Gunnar Morling!
-- HIGH: Tables with high bloat
(with q as (
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
	'Table Health' as category,
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
	quote_ident(tblname))
union all
--Credit: https://github.com/ioguix/pgsql-bloat-estimation -- Jehan-Guillaume (ioguix) de Rorthais!
-- HIGH: Tables never analyzed
    select
	'HIGH' as severity,
	'Table Health' as category,
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
	and n_tup_ins + n_tup_upd + n_tup_del > 1000
union all
-- HIGH: Tables larger than 100GB
(with ts as (
select
	table_schema,
	table_name,
	pg_relation_size('"' || table_schema || '"."' || table_name || '"') as size_bytes,
	pg_size_pretty(pg_relation_size('"' || table_schema || '"."' || table_name || '"')) as size_pretty
from
	information_schema.tables
where
	table_type = 'BASE TABLE'
	and pg_relation_size('"' || table_schema || '"."' || table_name || '"') > 107374182400
	-- 100GB in bytes
order by
	size_bytes desc)
select
	'HIGH' as severity,
	'Table Health' as category,
	'Tables larger than 100GB' as check_name,
	ts.table_schema || '"."' || ts.table_name as object_name,
	'The following table' as description,
	 ts.size_pretty as current_value,
	'I suggest looking into partitioning tables. Do you need all of this data? Can some of it be archived into something like S3?' as recommended_action,
	'https://www.heroku.com/blog/handling-very-large-tables-in-postgres-using-partitioning/' as documentation_link,
	2 as severity_order
from
	ts)
union all
-- HIGH: Duplicate or redundant indexes
    select
	'HIGH' as severity,
	'Table Health' as category,
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
	i1.schemaname not like all(array['information_schema', 'pg_catalog', 'pg_toast', 'pg_temp%'])
union all
-- HIGH: Table with more than 200 columns
(with cc as (
select
	table_schema,
	table_name,
	COUNT(*) as column_count
from
	information_schema.columns
where
	table_schema not in ('pg_catalog', 'information_schema')
group by
	table_schema,
	table_name
order by
	column_count desc)
select
	'HIGH' as severity,
	'Table Health' as category,
	'Table with more than 200 columns' as check_name,
	 cc.table_schema || '.' || cc.table_name as object_name,
	'Postgres has a hard 1600 column limit, but that also includes columns you have dropped. Continuing to widen your table can impact performance.' as issue_description,
	 cc.column_count::text as current_value,
	'Yikes-it is about time you put a hard stop on widing your tables and begin breaking this table into several tables. I once worked on a table with over 300 columns before.......' as recommended_action,
	'https://www.tigerdata.com/learn/designing-your-database-schema-wide-vs-narrow-postgres-tables \
	 https://nerderati.com/postgresql-tables-can-have-at-most-1600-columns \
     https://www.postgresql.org/docs/current/limits.html' as documentation_link,
	2 as severity_order
from
	cc
where
	cc.column_count > 200)
union all
-- MEDIUM: Blocked and Blocking Queries
(with bq as (
select
	blocked.pid as blocked_pid,
	blocked.query as blocked_query,
	blocking.pid as blocking_pid,
	blocking.query as blocking_query,
	now() - blocked.query_start as blocked_duration
from
	pg_locks blocked_locks
join pg_stat_activity blocked on
	blocked.pid = blocked_locks.pid
join pg_locks blocking_locks
on
	blocking_locks.transactionid = blocked_locks.transactionid
and blocking_locks.pid != blocked_locks.pid
join pg_stat_activity blocking on
	blocking.pid = blocking_locks.pid
where
	not blocked_locks.granted)
select
	'MEDIUM' as severity,
	'Query Health' as category,
	'Current Blocked/Blocking Queries' as check_name,
	'Blocked PID: ' || bq.blocked_pid || chr(10) ||
    'Blocked Query: ' || bq.blocked_query as object_name,
	'The following query is being blocked by an already running query' as issue_description,
	'Blocking PID: ' || bq.blocking_pid || chr(10) ||
	'Blocking Query: ' || bq.blocking_query as current_value,
	'Blocked queries are part of concurrency behavior. However, it is always recommended to monitor long running blocking queries. The Crunchy Data article recommended has an excellent walk through and suggested steps on how to tackle unnecessary blocking queries' as recommended_action,
	'https://www.postgresql.org/docs/current/explicit-locking.html' as documentation_link,
	3 as severity_order
from
	bq)
union all
-- MEDIUM: Tables with outdated statistics
(with s as (
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
	'Table Health' as category,
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
	'https://www.postgresql.org/docs/current/routine-vacuuming.html,
        https://www.depesz.com/2020/01/29/which-tables-should-be-auto-vacuumed-or-auto-analyzed/' as documentation_link,
	3 as severity_order
from
	tt
where
	n_dead_tup > v_threshold
or n_mod_since_analyze > a_threshold
order by
	nspname,
	relname)
union all
-- credit: https://www.depesz.com/2020/01/29/which-tables-should-be-auto-vacuumed-or-auto-analyzed -- Thanks depesz!
-- MEDIUM: Low index usage efficiency
    select
	'MEDIUM' as severity,
	'Table Health' as category,
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
	and idx_tup_read::numeric / nullif(idx_scan, 0) > 1000
union all
-- MEDIUM: Replication slots with high wal retation (90% of max wal)
(with q as (
select
		slot_name,
		plugin,
		database,
		restart_lsn,
		case
			when active is true then 'active'
			else 'inactive'
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
		q)
union all
-- MEDIUM: Large sequential scans
    select
	'MEDIUM' as severity,
	'Query Health' as category,
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
	and seq_tup_read > seq_scan * 10000
union all
-- MEDIUM: Table with more than 50 columns
(with cc as (
select
	table_schema,
	table_name,
	COUNT(*) as column_count
from
	information_schema.columns tc
where
	table_schema not in ('pg_catalog', 'information_schema')
group by
	table_schema,
	table_name
order by
	column_count desc)
select
	'MEDIUM' as severity,
	'Table Health' as category,
	'Table with more than 50 columns' as check_name,
	 cc.table_schema || '.' || cc.table_name as object_name,
	'Postgres has a hard 1600 column limit, but that also includes columns you have dropped. Continuing to widen your table can impact performance.' as issue_description,
	 cc.column_count::text as current_value,
	'The most straightforward recommendation is to split your table into more tables connected via foreign keys. However, your situation may very based on the type of data stored. Consider the documentation links to learn more.' as recommended_action,
	'https://www.tigerdata.com/learn/designing-your-database-schema-wide-vs-narrow-postgres-tables \
	 https://nerderati.com/postgresql-tables-can-have-at-most-1600-columns \
     https://www.postgresql.org/docs/current/limits.html' as documentation_link,
	3 as severity_order
from
	cc
where
	cc.column_count between 50 and 199)
union all
-- MEDIUM: Connection and lock monitoring
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
	COUNT(*) > 50
union all
-- MEDIUM: Tables larger than 50GB
(with ts as (
select
	table_schema,
	table_name,
	pg_relation_size('"' || table_schema || '"."' || table_name || '"') as size_bytes,
	pg_size_pretty(pg_relation_size('"' || table_schema || '"."' || table_name || '"')) as size_pretty
from
	information_schema.tables
where
	table_type = 'BASE TABLE'
	and pg_relation_size('"' || table_schema || '"."' || table_name || '"') between 53687091200 and 107374182400
order by
	size_bytes desc)
select
	'MEDIUM' as severity,
	'Table Health' as category,
	'Tables larger than 100GB' as check_name,
	ts.table_schema || '"."' || ts.table_name as object_name,
	'The following table' as description,
	 ts.size_pretty as current_value,
	'Tables larger than 50GB should be monitored and reviewed if a data archiving or removal process should be implemented. I suggest looking into partitioning tables, if possible.' as recommended_action,
	'https://www.heroku.com/blog/handling-very-large-tables-in-postgres-using-partitioning/' as documentation_link,
	3 as severity_order
from
	ts)
union all
-- MEDIUM: Queries running longer than 5 minutes
    select
	'MEDIUM' as severity,
	'Query Health' as category,
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
	'Review query using EXPLAIN ANALYZE to identify any bottlenecks, such as full table scans, missing indexes, etc' as recommended_action,
	'https://www.postgresql.org/docs/current/using-explain.html' as documentation_link,
	3 as severity_order
from
	pg_stat_activity pgs
where
	state = 'active'
	and now() - query_start > interval '5 minutes'
union all
-- LOW: Roles that have never logged in (with LOGIN rights)
(WITH ur AS (
    SELECT
        r.rolname AS role_name,
        r.rolcreaterole,
        r.rolcanlogin,
        r.rolsuper,
        r.rolvaliduntil,
        array_agg(m.rolname) FILTER (WHERE m.rolname IS NOT NULL) AS member_of
    FROM
        pg_roles r
    LEFT JOIN
        pg_auth_members am ON am.member = r.oid
    LEFT JOIN
        pg_roles m ON m.oid = am.roleid
    WHERE
        r.rolcanlogin = true
        AND r.rolname NOT LIKE 'pg_%'
        AND r.rolname NOT IN ('postgres', 'rds_superuser', 'rdsadmin', 'azure_superuser', 'cloudsqlsuperuser')
        AND NOT EXISTS (
            SELECT 1
            FROM pg_stat_activity psa
            WHERE psa.usename = r.rolname
        )
        AND (
            SELECT coalesce(max(backend_start), '1970-01-01')
            FROM pg_stat_activity
            WHERE usename = r.rolname
        ) = '1970-01-01'
    GROUP BY
        r.rolname, r.rolcreaterole, r.rolcanlogin, r.rolsuper, r.rolvaliduntil
)
SELECT
    'LOW' AS severity,
    'Security Health' AS category,
    'Role Never Logged In' AS check_name,
    ur.role_name AS object_name,
    'Role has LOGIN privilege but has never connected (since stats reset). ' ||
        CASE WHEN ur.rolsuper THEN 'WARNING: Has SUPERUSER privilege. ' ELSE '' END ||
        CASE WHEN ur.rolvaliduntil IS NOT NULL THEN 'Expires: ' || ur.rolvaliduntil::text ELSE 'No expiration set' END AS issue_description,
    'Member of: ' || coalesce(array_to_string(ur.member_of, ', '), 'none') AS current_value,
    'Review if this role is still needed. Consider removing LOGIN privilege or dropping the role if unused.' AS recommended_action,
    'https://www.postgresql.org/docs/current/sql-droprole.html' AS documentation_link,
    4 AS severity_order
FROM
    ur
ORDER BY
    ur.rolsuper DESC,
    ur.role_name)
union all
-- LOW: Missing indexes on foreign keys
    select
	'LOW' as severity,
	'Table Health' as category,
	'Missing FK Index' as check_name,
	n.nspname || '.' || t.relname || '.' || string_agg(a.attname, ', ') as object_name,
	'Foreign key constraint missing supporting index for efficient joins' as issue_description,
	'FK constraint without index' as current_value,
	'Consider adding index on foreign key columns for better join performance' as recommended_action,
	'https://www.postgresql.org/docs/current/ddl-constraints.html' as documentation_link,
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
	9
union all
-- LOW: Indexes with low usage
(WITH lui AS (
    SELECT
        quote_ident(schemaname) || '.' || quote_ident(indexrelname) AS index_name,
        quote_ident(schemaname) || '.' || quote_ident(relname) AS table_name,
        pg_size_pretty(pg_relation_size(indexrelid)) AS index_size,
        pg_relation_size(indexrelid) AS index_size_bytes,
        idx_scan,
        idx_tup_read,
        idx_tup_fetch
    FROM
        pg_stat_user_indexes
    WHERE
        idx_scan > 0
        AND idx_scan < 100
        AND pg_relation_size(indexrelid) > 1024 * 1024  -- > 1MB
)
SELECT
    'LOW' AS severity,
    'Index Health' AS category,
    'Index With Very Low Usage' AS check_name,
    lui.index_name AS object_name,
    'Index on ' || lui.table_name || ' has been scanned only ' || lui.idx_scan ||
        ' times since stats reset. May not be worth the maintenance overhead.' AS issue_description,
    'Scans: ' || lui.idx_scan || ', Tuples read: ' || lui.idx_tup_read ||
        ', Size: ' || lui.index_size AS current_value,
    'Monitor usage over a full business cycle before removing. Verify index is not used for constraints or infrequent but critical queries.' AS recommended_action,
    'https://www.postgresql.org/docs/current/monitoring-stats.html' AS documentation_link,
    4 AS severity_order
FROM
    lui
ORDER BY
    lui.index_size_bytes desc)
union all
-- LOW: Tables with no recent acitivty
(WITH it AS (
    SELECT
        schemaname || '.' || relname AS table_name,
        pg_size_pretty(pg_total_relation_size(relid)) AS table_size,
        pg_total_relation_size(relid) AS table_size_bytes,
        coalesce(seq_scan, 0) + coalesce(idx_scan, 0) AS total_scans,
        coalesce(n_tup_ins, 0) + coalesce(n_tup_upd, 0) + coalesce(n_tup_del, 0) AS total_writes,
        greatest(last_vacuum, last_autovacuum, last_analyze, last_autoanalyze) AS last_maintenance
    FROM
        pg_stat_user_tables
    WHERE
        coalesce(seq_scan, 0) + coalesce(idx_scan, 0) = 0
        AND coalesce(n_tup_ins, 0) + coalesce(n_tup_upd, 0) + coalesce(n_tup_del, 0) = 0
)
SELECT
    'LOW' AS severity,
    'Table Health' AS category,
    'Table With No Activity Since Stats Reset' AS check_name,
    quote_ident(it.table_name) AS object_name,
    'Table has had no reads or writes since stats were last reset. Last maintenance: ' ||
        coalesce(it.last_maintenance::text, 'never') AS issue_description,
    'Total scans: ' || it.total_scans || ', Total writes: ' || it.total_writes ||
        ', Size: ' || it.table_size AS current_value,
    'Review if this table is still needed. Check pg_stat_reset() history to determine stats age. Consider archiving or dropping if no longer in use.' AS recommended_action,
    'https://www.postgresql.org/docs/current/monitoring-stats.html' AS documentation_link,
    4 AS severity_order
FROM
    it
ORDER BY
    it.table_size_bytes DESC)
union all
-- LOW: Check for truely empty tables in the database
(WITH et AS (
    SELECT
        n.nspname || '.' || c.relname AS table_name,
        pg_size_pretty(pg_total_relation_size(c.oid)) AS table_size,
        pg_total_relation_size(c.oid) AS table_size_bytes,
        s.last_vacuum,
        s.last_analyze,
        c.reltuples::bigint AS estimated_rows
    FROM
        pg_class c
    JOIN
        pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN
        pg_stat_user_tables s ON s.relid = c.oid
    WHERE
        c.relkind = 'r'
        AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'pg_toast')
        AND c.reltuples = 0
        AND s.n_live_tup = 0
)
SELECT
    'LOW' AS severity,
    'Table Health' AS category,
    'Empty Table' AS check_name,
    et.table_name AS object_name,
    'Table contains no rows. Last vacuum: ' || coalesce(et.last_vacuum::text, 'never') ||
        ', Last analyze: ' || coalesce(et.last_analyze::text, 'never') AS issue_description,
    '0 rows, Size: ' || et.table_size AS current_value,
    'Review if this table is still needed. May be an abandoned table, pending migration, or staging table that was never cleaned up.' AS recommended_action,
    'https://www.postgresql.org/docs/current/routine-vacuuming.html' AS documentation_link,
    4 AS severity_order
FROM
    et
ORDER BY
    et.table_size_bytes desc)
union all
-- LOW: Tables with zero or only one column
(with sct as (
select
	pc.oid::regclass::text as table_name,
	pg_size_pretty(pg_table_size(pc.oid)) as table_size,
	pg_table_size(pc.oid) as table_size_bytes,
	count(a.attname) as column_count
from
	pg_catalog.pg_class pc
inner join
        pg_catalog.pg_namespace nsp on
	nsp.oid = pc.relnamespace
left join
        pg_catalog.pg_attribute a on
	a.attrelid = pc.oid
	and a.attnum > 0
	and not a.attisdropped
where
	pc.relkind in ('r', 'p')
	and not pc.relispartition
	and nsp.nspname not in ('pg_catalog', 'information_schema', 'pg_toast')
group by
	pc.oid
having
	count(a.attname) <= 1
)
select
	'LOW' as severity,
	'Table Health' as category,
	'Table With Single Or No Columns' as check_name,
	quote_ident(sct.table_name) as object_name,
	'Table has ' || sct.column_count || ' column(s). This may indicate an abandoned table, incomplete migration, or design issue.' as issue_description,
	sct.column_count || ' column(s), Size: ' || sct.table_size as current_value,
	'Review if this table is still needed. Consider removing if unused or completing the schema if it was left incomplete.' as recommended_action,
	'https://www.postgresql.org/docs/current/ddl.html /
https://github.com/mfvanek/pg-index-health-sql/blob/master/sql/tables_with_zero_or_one_column.sql' as documentation_link,
	4 as severity_order
from
	sct)
union all
-- LOW: Connections IDLE for 1 > hour
(with ic as (
select
	pid,
	usename,
	application_name,
	client_addr,
	state,
	state_change,
	now() - state_change as idle_duration
from
	pg_stat_activity
where
	state = 'idle'
	and state_change < now() - interval '1 hour'
	and pid <> pg_backend_pid()
)
select
	'LOW' as severity,
	'Connection Health' as category,
	'Idle Connections Over 1 Hour' as check_name,
	ic.usename || ' (PID: ' || ic.pid || ')' as object_name,
	'Connection has been idle for ' ||
        extract(epoch from ic.idle_duration)::int / 3600 || ' hours ' ||
        (extract(epoch from ic.idle_duration)::int % 3600) / 60 || ' minutes. ' ||
        'Application: ' || coalesce(ic.application_name, 'unknown') ||
        ', Client: ' || coalesce(ic.client_addr::text, 'local') as issue_description,
	ic.idle_duration::text as current_value,
	'Review if this connection is still needed. Consider implementing connection pooling (PgBouncer), setting idle_session_timeout, or terminating with pg_terminate_backend(' || ic.pid || ')' as recommended_action,
	'https://www.postgresql.org/docs/current/runtime-config-client.html' as documentation_link,
	4 as severity_order
from
	ic)
union all
-- INFO: Database size and growth
    select
	'INFO' as severity,
	'Database Health' as category,
	'Database Size' as check_name,
	current_database() as object_name,
	'Current database size information' as issue_description,
	pg_size_pretty(pg_database_size(current_database())) as current_value,
	'Monitor growth trends and plan capacity accordingly' as recommended_action,
	'https://www.postgresql.org/docs/current/diskusage.html' as documentation_link,
	5 as severity_order
union all
-- INFO: Version and configuration
    select
	'INFO' as severity,
	'System Info' as category,
	'PostgreSQL Version' as check_name,
	'System' as object_name,
	'Current PostgreSQL version and basic configuration' as issue_description,
	version() as current_value,
	'Keep PostgreSQL updated and review configuration settings' as recommended_action,
	'https://www.postgresql.org/docs/current/upgrading.html' as documentation_link,
	5 as severity_order
union all
-- INFO: Installed Extensions
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
	pg_extension pe
union all
-- INFO: Server Uptime
    select
	'INFO' as severity,
	'System Info' as category,
	'Server Uptime' as check_name,
	'System' as object_name,
	'Current Uptime of Server' as issue_description,
	(current_timestamp - pg_postmaster_start_time())::text as current_value,
	'No Recommendation - Informational' as recommended_action,
	'N/A' as documentation_link,
	5 as severity_order
union all
-- INFO: Log Directory
(with ld as (
select
	current_setting('log_directory') as log_directory
    )
select
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
from
	ld)
union all
-- INFO: Log File(s) Size(s)
select
	'INFO' as severity,
	'System Info' as category,
	'Size of ALL Logfiles combined' as check_name,
	'System' as object_name,
	'Most managed services do not allow access to pg_ls_dir. See documentation below for how to find your log files' as issue_description,
	'Cannot view log size-this is a managed service' as current_value,
	'Check your provider for further documentation on calculating log size' as recommended_action,
	'For AWS Aurora/RDS: https://docs.aws.amazon.com/cli/latest/reference/rds/describe-db-log-files.html  /
         For GCP Cloud SQL: https://docs.cloud.google.com/sql/docs/postgres/logging /
         For Azure Database for PostgreSQL: https://learn.microsoft.com/en-us/cli/azure/postgres/flexible-server/server-logs?view=azure-cli-latest
        ' as documentation_link,
	5 as severity_order;
