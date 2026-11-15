<p align="center">
  <img alt="pgFirstAid Logo" src="docs/images/logo-transparent.png" width="500">
</p>


# pgFirstAid

Easy-to-deploy, open source PostgreSQL function (and view!) that provides a prioritized list of actions to improve database stability and performance.Inspired by Brent Ozar's [FirstResponderKit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) for SQL Server, **pgFirstAid** is designed for everyone to use - not just DBAs! Get actionable health insights from your PostgreSQL database in seconds.


## Quick Thank You To Our Sponsors

This project is supported by:

<a href="https://get.neon.com/5HwTAdh">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/neon-logo-dark-color.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/neon-logo-light-color.png">
    <img alt="Neon Sponsorship" src="docs/images/neon-logo-light-color.png" width="200">
  </picture>
</a>

Neon gives you serverless PostgreSQL that scales to zero when you're not using it. You get Git-like branching for your database; fork it for testing, preview environments, whatever. Plus, it's just Postgres. All your tools and extensions just work. This project uses Neon for testing pgFirstAid for compatibility, which means you can use it too! Click the Neon image to get started building your next project.

<a href="https://osuosl.org/">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/osllogo-white_dark.png">
    <source media="(prefers-color-scheme: light)" srcset="docs/images/osllogo-web_light.png">
    <img alt="OSU Sponsorship" src="docs/images/osllogo-web_light.png" width="200">
  </picture>
</a>

Thank you OSUOSL for providing hosting for our testing infrastructure and CI/CD pipelines! OSU Open Source Lab (osuosl.org) is a nonprofit at Oregon State University that supports the open source community by providing hosting, infrastructure, and systems engineering services for open source projects.

## Features

- **Zero Dependencies** - Single SQL function, no external tools required
- **Detailed Checks** - built-in health checks covering critical performance and stability issues
- **Prioritized Results** - Issues ranked by severity (CRITICAL → HIGH → MEDIUM → LOW → INFO)
- **Actionable Recommendations** - Each issue includes specific remediation steps
- **Copyable Agent Prompts** - Every non-INFO finding includes check-specific guidance with its actual objects and observed values
- **Documentation Links** - Direct links to official PostgreSQL documentation for deeper learning
- **Optional `pg_stat_statements` Checks** - Runs additional query workload checks when `pg_stat_statements` is installed

## Quick Start

### Install or upgrade

Run the complete matching SQL file as the installation owner or a database administrator.
Use the same file for new installations and upgrades; no manual `DROP` is needed.

| Installation | SQL file | Query afterward |
|---|---|---|
| Function | [`pgFirstAid.sql`](pgFirstAid.sql) | `SELECT * FROM pg_firstAid();` |
| Self-hosted view | [`view_pgFirstAid.sql`](view_pgFirstAid.sql) | `SELECT * FROM v_pgfirstaid;` |
| Managed view | [`view_pgFirstAid_managed.sql`](view_pgFirstAid_managed.sql) | `SELECT * FROM v_pgfirstaid;` |

In a SQL editor, execute the entire file as a script with stop-on-error enabled.
For the function, the equivalent psql command is:

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 --single-transaction -f pgFirstAid.sql
```

The installer preserves existing ownership, grants, and comments.
Unsupported custom definitions or blocking dependencies stop safely instead of being discarded.
See the [short upgrade guide](docs/health-checks/agent-prompts.md#upgrade-an-existing-installation) for view commands and troubleshooting.

### Example Output

| severity | category | check_name | object_name | issue_description | current_value | recommended_action | documentation_link |
|----------|----------|------------|-------------|-------------------|---------------|-------------------|-------------------|
| CRITICAL | Table Health| Missing Primary Key | public.users | Table missing a primary key... | No primary key defined | Add a primary key or unique constraint... | https://www.postgresql.org/... |
| HIGH | Table Health | Missing Statistics | public.orders | Table has never been analyzed... | Last analyze: Never | Run ANALYZE on this table... | https://www.postgresql.org/... |

The `agent_prompt` column is omitted from this compact example.
View results also include `severity_order` before `agent_prompt`.

## What Does It Check?

See the full list of checks, grouped by severity, in [`docs/health-checks/README.md`](docs/health-checks/README.md).

## Copy a Remediation Prompt

Each non-INFO result includes an `agent_prompt` tailored to that finding's affected objects and measured values.
Copy the complete cell into your agent to start with read-only diagnosis and an approval-gated remediation plan.

```sql
SELECT severity, check_name, object_name, agent_prompt
FROM pg_firstAid()
WHERE severity <> 'INFO';
```

Use `FROM v_pgfirstaid` for either view installation.
INFO rows return `NULL` for `agent_prompt`.
Review prompts for sensitive object names or captured SQL before sharing them externally.
See [agent prompts and upgrades](docs/health-checks/agent-prompts.md) for details.

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

**Optional: Enable pg_stat_statements For Deeper Query Checks**
- pgFirstAid keeps running without this extension and reports a setup action when it is missing.
- Self-hosted PostgreSQL: set `shared_preload_libraries = 'pg_stat_statements'`, restart PostgreSQL, then run `CREATE EXTENSION pg_stat_statements;`
- AWS RDS for PostgreSQL: add `pg_stat_statements` to the DB parameter group `shared_preload_libraries`, reboot, then run `CREATE EXTENSION pg_stat_statements;`
- GCP Cloud SQL for PostgreSQL: enable `cloudsql.enable_pg_stat_statements`, restart if required, then run `CREATE EXTENSION pg_stat_statements;`
- Azure Database for PostgreSQL: add `pg_stat_statements` to `shared_preload_libraries`, restart, then run `CREATE EXTENSION pg_stat_statements;`

## Performance Impact

pgFirstAid is designed to be lightweight and safe to run on production systems:
- Read-only operations (no modifications to your data or schema)
- Uses system catalog views that are already cached
- Typical execution time: <1 second on most databases
- No locking or blocking of user queries

## CI/CD Integration

Drop-in GitHub Actions workflows in [`workflows/`](workflows/) for integrating pgFirstAid into your pipeline:

| Workflow | Purpose |
|----------|---------|
| [`pgfirstaid-pr-audit.yml`](workflows/pgfirstaid-pr-audit.yml) | Posts a health audit on every PR |
| [`pre-post-migration-validate.yml`](workflows/pre-post-migration-validate.yml) | Gates deployments on migration safety |
| [`neon-before-after-validate.yml`](workflows/neon-before-after-validate.yml) | Isolated before/after checks via Neon branching |
| [`db-health-checks.yml`](workflows/db-health-checks.yml) | Scheduled daily health monitoring |
| [`managed-db-validate.yml`](workflows/managed-db-validate.yml) | Cloud-specific compatibility validation |

Copy any workflow file to `.github/workflows/` in your repo. See [`workflows/README.md`](workflows/README.md) for setup and configuration.

## Testing

- Query and health-check coverage is validated with pgTAP assertions grouped by severity.
- Integration tests cover live runtime behavior, function/view parity, and checks that need concurrent sessions or timing control.
- A coverage guard ensures every `check_name` in `pgFirstAid.sql` is referenced by at least one pgTAP assertion.
- The GitHub Actions validation workflows also run `testing/seed_and_validate.py --managed` against live database targets to confirm the seeded checks actually fire end-to-end.
- Managed database validation is exercised through the reusable workflow in `.github/workflows/managed-db-validate.yml`.
- Function-upgrade tests cover the normal SQL file on fresh and existing installations, including grant preservation, dependency protection, and rollback.

> **Important:** We currently validate managed-database testing against AWS, but we do not have the funding or credits needed to keep Azure and GCP test environments running. If you have access to Azure Database for PostgreSQL or GCP Cloud SQL and want to help validate pgFirstAid there, we would be happy to have the help.

## Compatibility

- **PostgreSQL 10+** - Supported, with active automated validation focused on PostgreSQL 15-18
- **PostgreSQL 9.x** - Most features work (minor syntax adjustments may be needed)
- Works with PostgreSQL-compatible databases, including Amazon RDS, Aurora, Azure Database for PostgreSQL, GCP Cloud SQL, and self-hosted PostgreSQL
- Automated managed-database validation is active for AWS today. Azure and GCP support is best-effort until we can fund those test environments.

## Contributing

Prompt and function/view migration helpers each have one maintained source under `data/`.
Edit the canonical helper, then run `uv run python tools/sync_sql_helpers.py` to refresh the standalone installers.
PR Safe Checks rejects embedded copies that differ from their canonical source.
See [SQL helper generation](tools/README.md#edit-shared-sql-helpers) for details.

Found a bug? Have an idea for a new health check? Let me know! I want this to grow to be a tool that is available for all, accidental DBA or not.

## License

GPLv3

## Credits

Logo designed and created by: [@sheeryy.bsky.social](https://bsky.app/profile/sheeryy.bsky.social)

Inspired by [Brent Ozar's FirstResponderKit](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit)) for SQL Server. Thank you to the SQL Server community for pioneering accessible database health monitoring!

Dave-IYKYK

---

**Made with ☕ for the PostgreSQL and Open Source community**
