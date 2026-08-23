# Health Checks

The full list of checks pgFirstAid runs, grouped by severity.

A check only fires when its conditions are met, so an empty result for any check is a pass. Checks tagged *(pg_stat_statements)* require that extension to be installed.

## CRITICAL Issues

- **Missing Primary Keys** - Tables without primary keys that can cause replication issues and poor performance
- **Unused Large Indexes** - Indexes consuming significant disk space but never used (>10MB, 0 scans)

## HIGH Priority Issues

- **Table Bloat** - Tables with >20% bloat affecting performance (tables >100MB)
- **Missing Statistics** - Tables never analyzed, leaving the query planner without statistics
- **Duplicate Indexes** - Indexes with the same structure, including predicates and expressions
- **Inactive Replication Slots** - Identifies replication slots that are inactive and can be removed if no longer needed
- **Tables Larger Than 100GB** - Identifies tables that are larger than 100GB
- **Tables With More Than 200 Columns** - List tables with more than 200 columns. You should probably look into those...
- **Autovacuum Disabled On Table** - User tables with `autovacuum_enabled = false`. Bloat, XID wraparound risk, and stale stats accumulate silently
- **listen_addresses Wildcard** - `listen_addresses = '*'` exposes PostgreSQL on every network interface; bind to specific IPs only
- **Timestamp Without Time Zone** - User columns typed `timestamp without time zone`. PostgreSQL silently strips TZ info; cross-region and DST reads can produce wrong results
- **Known CVE Affecting Your Version** - Curated CVEs from the PostgreSQL security index matching your running version. One row per CVE that affects a version range containing `server_version_num`; upgrade to the first fixed minor to remediate. Covers PG 15-18.

## MEDIUM Priority Issues

- **Outdated Statistics** - Table statistics older than 7 days with significant modifications
- **Low Index Efficiency** - Indexes with poor selectivity (scan-to-tuple ratio >1000)
- **Excessive Sequential Scans** - Tables with high sequential scan activity that may benefit from indexes
- **High Connection Count** - More than 50 active connections potentially impacting performance
- **Replication Slots With High WAL Retention** - Replication slots that have 90% of max wal setting
- **Long Running Queries** - Queries that have been running for 5 minutes or more
- **Blocked and Blocking Queries** - Queries that are currently blocked or blocking other queries at the time you run pg_firstAid
- **Top 10 Expensive Active Queries** - Active queries running longer than 30 seconds, ordered by runtime
- **Lock-Wait-Heavy Active Queries** - Active queries waiting on locks for more than 30 seconds
- **Idle In Transaction Over 5 Minutes** - Sessions left idle in transaction for over 5 minutes
- **pg_stat_statements Extension Missing** - Reports when extension-based workload checks are unavailable and points to setup steps
- **Top 10 Queries by Total Execution Time** *(pg_stat_statements)*
- **High Mean Execution Time Queries** *(pg_stat_statements)*
- **Top 10 Queries by Temp Block Spills** *(pg_stat_statements)*
- **Low Cache Hit Ratio Queries** *(pg_stat_statements)*
- **High Runtime Variance Queries** *(pg_stat_statements)*
- **High Calls Low Value Queries** *(pg_stat_statements)*
- **High Rows Per Call Queries** *(pg_stat_statements)*
- **High Shared Block Reads Per Call Queries** *(pg_stat_statements)*
- **Top Queries by WAL Bytes Per Call** *(pg_stat_statements)*
- **Tables With More Than 50 Columns** - List tables with more than 50 columns (but less than 200)
- **Tables Larger Than 50GB** - Identifies tables larger than 50GB (but less than 100GB)
- **Query Duration Logging Disabled** - `log_min_duration_statement = -1` so slow queries never get logged
- **Known Bug Affecting Your Version** - Notable non-CVE bugs from PostgreSQL release notes that match your running version (data integrity, replication, vacuum). Covers PG 15-18.

## LOW Priority Issues

- **Missing Foreign Key Indexes** - Foreign key constraints without supporting indexes for efficient joins
- **Idle Connections For More Than 1 Hour** - Grabs connections that have been open and idle for more than 1 hour
- **Tables With Zero or Only One Column** - Identifies tables with one or zero columns
- **True Empty Table(s) in Database** - Searches for truly empty tables in the database. Checks if there are rows present and the last time vacuum and analyze was ran against the identified table
- **Tables With No Recent Activity** - Checks for zero activity since the last stats reset. This check works for all versions of Postgres. In 16+, we could use `last_*_timestamp` columns which could tell you WHEN the last activity was as well. However, this would break compatibility for anything older than 16.
- **Indexes With Low Usage** - Flags indexes with 1MB with 1-99 scans. Zero scans are already caught by the CRITICAL unused indexes check.
- **Roles That Have Never Logged In** - Excludes system role and managed services roles. This includes users with `LOGIN` rights.
- **Varchar With Length Limit** - Columns declared `varchar(n)`. The book recommends `text` when in doubt; length limits can cause silent truncation
- **Serial Column Legacy** - Columns with `nextval()` defaults instead of `GENERATED AS IDENTITY`. Migrate when convenient
- **Rules On Tables** - Non-view rules on tables. Prefer triggers — rules on tables are an old mechanism
- **Not In With Subquery** *(pg_stat_statements)* - Queries using `NOT IN (SELECT ...)`. SQL NULL semantics trap returns zero rows if the subquery contains any NULL

## INFORMATIONAL

- **Database Size** - Current database size and growth monitoring
- **PostgreSQL Version** - Version information and configuration details
- **Installed Extensions** - Lists installed extensions on the Server
- **Server Uptime** - Server uptime since last restart
- **Log Directory** - Current log directory when the platform exposes it
- **Log File Sizes** - Current log file sizes when the platform exposes them
