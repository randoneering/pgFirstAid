# pgFirstAid

Easy-to-deploy, open source PostgreSQL function (and view!) that provides a prioritized list of actions to improve database stability and performance.Inspired by Brent Ozar's [FirstResponderKit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) for SQL Server, **pgFirstAid** is designed for everyone to use—not just DBAs! Get actionable health insights from your PostgreSQL database in seconds.

## Features

- **Zero Dependencies** - Single SQL function, no external tools required
- **Detailed Checks** - built-in health checks covering critical performance and stability issues
- **Prioritized Results** - Issues ranked by severity (CRITICAL → HIGH → MEDIUM → LOW → INFO)
- **Actionable Recommendations** - Each issue includes specific remediation steps
- **Documentation Links** - Direct links to official PostgreSQL documentation for deeper learning

## Quick Start

### Installation

```sql
-- Copy and paste the function or view definition into your PostgreSQL database
-- Then run it:

--- function
SELECT * FROM pg_firstAid();

--- view
SELECT * FROM v_pgfirstAid;
```

That's it! No configuration needed. Deploy as a user with the highest possible priviledges (in your environment) to avoid issues.

### Example Output

| severity | category | check_name | object_name | issue_description | current_value | recommended_action | documentation_link |
|----------|----------|------------|-------------|-------------------|---------------|-------------------|-------------------|
| CRITICAL | Table Health| Missing Primary Key | public.users | Table missing a primary key... | No primary key defined | Add a primary key or unique constraint... | https://www.postgresql.org/... |
| HIGH | Table Health | Missing Statistics | public.orders | Table has never been analyzed... | Last analyze: Never | Run ANALYZE on this table... | https://www.postgresql.org/... |

## What Does It Check?

### CRITICAL Issues

- **Missing Primary Keys** - Tables without primary keys that can cause replication issues and poor performance
- **Unused Large Indexes** - Indexes consuming significant disk space but never used (>10MB, 0 scans)

### HIGH Priority Issues

- **Table Bloat** - Tables with >20% bloat affecting performance (tables >100MB)
- **Missing Statistics** - Tables never analyzed, leaving the query planner without statistics
- **Duplicate Indexes** - Multiple indexes with identical or overlapping column sets
- **Inactive Replication Slots** - Identifies replication slots that are inactive and can be removed if no longer needed
- **Tables Larger Than 100GB** - Identifies tables that are larger than 100GB
- **Tables With More Than 200 Columns** - List tables with more than 200 columns. You should probably look into those...

### MEDIUM Priority Issues

- **Outdated Statistics** - Table statistics older than 7 days with significant modifications
- **Low Index Efficiency** - Indexes with poor selectivity (scan-to-tuple ratio >1000)
- **Excessive Sequential Scans** - Tables with high sequential scan activity that may benefit from indexes
- **High Connection Count** - More than 50 active connections potentially impacting performance
- **Replication Slots With High WAL Retention** - Replication slots that have 90% of max wal setting
- **Long Running Queries** - Queries that have been running for 5 minutes or more
- **Blocked and Blocking Queries** - Queries that are currently blocked or blocking other queries at the time you run pg_firstAid
- **Tables With More Than 50 Columns** - List tables with more than 50 columns (but less than 200)
- **Tables Larger Than 50GB** - Identifies tables larger than 50GB (but less than 100GB)

### LOW Priority Issues

- **Missing Foreign Key Indexes** - Foreign key constraints without supporting indexes for efficient joins
- **Idle Connections For More Than 1 Hour** - Grabs connections that have been open and idle for more than 1 hour
- **Tables With Zero or Only One Column** - Identifies tables with one or zero columns
- **True Empty Table(s) in Database** - Searches for truly empty tables in the database. Checks if there are rows present and the last time vacuum and analyze was ran against the identified table
- **Tables With No Recent Activity** - Checks for zero activity since the last stats reset. This check works for all versions of Postgres. In 16+, we could use `last_*_timestamp` columns which could tell you WHEN the last activity was as well. However, this would break compatibility for anything older than 16.
- **Indexes With Low Usage** - Flags indxes with 1MB with 1-99 scans. Zero scans are already caught by the CRITICAL unused indexes check.
- **Roles That Have Never Logged In** - Excludes system role and managed services roles. This includes users with `LOGIN` rights.

### INFORMATIONAL

- **Database Size** - Current database size and growth monitoring
- **PostgreSQL Version** - Version information and configuration details
- **Installed Extensions** - Lists installed extensions on the Server
- **Server Uptime** - Server uptime since last restart
- **Log Directory** - Location of Log File(s). Results will vary for managed services like AWS RDS. (note: need access to AWS/Azure/GCP environments where I can test against!)
- **Log File Sizes** - The size of the log files. Again, this will vary for managed services. 

## Usage Tips

### Filter by Severity

```sql
-- Show only critical issues
SELECT * FROM pg_firstAid() WHERE severity = 'CRITICAL';

SELECT * FROM v_pgfirstAid WHERE severity = 'MEDIUM';

-- Show critical and high priority issues
SELECT * FROM pg_firstAid() WHERE severity IN ('CRITICAL', 'HIGH');

SELECT * FROM v_pgfirstAid WHERE severity IN ('CRITICAL', 'HIGH');
```

### Filter by Category

1. Table Health
2. Query Health
3. Replication Health
4. System Health
5. Database Health

```sql
-- Check table health   
SELECT * FROM v_pgfirstAid WHERE category = 'Table Health';
```

### Count Issues by Severity

```sql
SELECT severity, COUNT(*) as issue_count
FROM pg_firstAid()
GROUP BY severity
ORDER BY MIN(CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    WHEN 'LOW' THEN 4
    ELSE 5 END);
```

## When to Run

- **Daily** - Quick health check as part of morning routine
- **Before Deployment** - Catch potential issues before they impact production
- **After Major Changes** - Verify database health after schema modifications or data migrations
- **Performance Troubleshooting** - First step when investigating slow queries or system issues
- **Capacity Planning** - Regular monitoring to track database growth trends

## Important Notes

**Read Before Acting**
- Always review recommendations carefully before making changes. I have been supporting Postgres databases for close to a decade, but I learn something new each day
- Test in a non-production environment first
- Some operations (like VACUUM FULL) require maintenance windows
- Never drop an index without validating its usage patterns over time

**Permissions**
- Requires read access to system catalogs (`pg_catalog`)
- Works with standard user permissions for most checks
- Some checks may return fewer results for non-superuser accounts

## Performance Impact

pgFirstAid is designed to be lightweight and safe to run on production systems:
- Read-only operations (no modifications to your data or schema)
- Uses system catalog views that are already cached
- Typical execution time: <1 second on most databases
- No locking or blocking of user queries

## Compatibility

- **PostgreSQL 10+** - Fully supported, but only testing on 15+. This will change as versions are deprecated
- **PostgreSQL 9.x** - Most features work (minor syntax adjustments may be needed)
- Works with all PostgreSQL-compatible databases (Amazon RDS, Aurora, Azure Database, etc.)

## Contributing

Found a bug? Have an idea for a new health check? Let me know! I want this to grow to be a tool that is available for all, accidental DBA or not.

## License

GPLv3

## Credits

Inspired by [Brent Ozar's FirstResponderKit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)) for SQL Server. Thank you to the SQL Server community for pioneering accessible database health monitoring!

Dave-IYKYK

---

**Made with ☕ for the PostgreSQL and Open Source community**
