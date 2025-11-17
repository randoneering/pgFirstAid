# pgFirstAid

Easy-to-deploy, open source PostgreSQL function that provides a prioritized list of actions to improve database stability and performance.Inspired by Brent Ozar's [FirstResponderKit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) for SQL Server, **pgFirstAid** is designed for everyone to use—not just DBAs! Get actionable health insights from your PostgreSQL database in seconds.

## Features

- **Zero Dependencies** - Single SQL function, no external tools required
- **Comprehensive Checks** - 12 (and growing!) built-in health checks covering critical performance and stability issues
- **Prioritized Results** - Issues ranked by severity (CRITICAL → HIGH → MEDIUM → LOW → INFO)
- **Actionable Recommendations** - Each issue includes specific remediation steps
- **Documentation Links** - Direct links to official PostgreSQL documentation for deeper learning

## Quick Start

### Installation

```sql
-- Copy and paste the function definition into your PostgreSQL database
-- Then run it:
SELECT * FROM pg_firstAid();
```

That's it! No configuration needed. Deploy as a user with the highest possible priviledges (in your environment) to avoid issues.

### Example Output

| severity | category | check_name | object_name | issue_description | current_value | recommended_action | documentation_link |
|----------|----------|------------|-------------|-------------------|---------------|-------------------|-------------------|
| CRITICAL | Table Structure | Missing Primary Key | public.users | Table missing a primary key... | No primary key defined | Add a primary key or unique constraint... | https://www.postgresql.org/... |
| HIGH | Statistics | Missing Statistics | public.orders | Table has never been analyzed... | Last analyze: Never | Run ANALYZE on this table... | https://www.postgresql.org/... |

## What Does It Check?

### CRITICAL Issues

1. **Missing Primary Keys** - Tables without primary keys that can cause replication issues and poor performance
2. **Unused Large Indexes** - Indexes consuming significant disk space but never used (>10MB, 0 scans)

### HIGH Priority Issues

3. **Table Bloat** - Tables with >20% bloat affecting performance (tables >100MB)
4. **Missing Statistics** - Tables never analyzed, leaving the query planner without statistics
5. **Duplicate Indexes** - Multiple indexes with identical or overlapping column sets

### MEDIUM Priority Issues

6. **Outdated Statistics** - Table statistics older than 7 days with significant modifications
7. **Low Index Efficiency** - Indexes with poor selectivity (scan-to-tuple ratio >1000)
8. **Excessive Sequential Scans** - Tables with high sequential scan activity that may benefit from indexes
9. **High Connection Count** - More than 50 active connections potentially impacting performance

### LOW Priority Issues

10. **Missing Foreign Key Indexes** - Foreign key constraints without supporting indexes for efficient joins

### INFORMATIONAL

11. **Database Size** - Current database size and growth monitoring
12. **PostgreSQL Version** - Version information and configuration details

## Usage Tips

### Filter by Severity

```sql
-- Show only critical issues
SELECT * FROM pg_firstAid() WHERE severity = 'CRITICAL';

-- Show critical and high priority issues
SELECT * FROM pg_firstAid() WHERE severity IN ('CRITICAL', 'HIGH');
```

### Filter by Category

```sql
-- Focus on index-related issues
SELECT * FROM pg_firstAid() WHERE category LIKE '%Index%';

-- Check table maintenance issues
SELECT * FROM pg_firstAid() WHERE category = 'Table Maintenance';
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

Inspired by [Brent Ozar's FirstResponderKit](https://github.com/BrentOzarUK/SQL-Server-First-Responder-Kit) for SQL Server. Thank you to the SQL Server community for pioneering accessible database health monitoring!

Dave-IYKYK

---

**Made with ☕ for the PostgreSQL and Open Source community**
