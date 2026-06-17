# pgFirstAid CI/CD Integration Workflows

This directory contains four non-overlapping GitHub Actions workflows for integrating pgFirstAid into your CI/CD pipeline. Each workflow has a distinct purpose and trigger, covering the full database health lifecycle: **PR feedback → migration safety → scheduled monitoring → cloud validation**.

```
┌─────────────────────────────────────────────────────────────────┐
│                    pgFirstAid Workflow Suite                     │
├──────────────┬──────────────┬──────────────┬────────────────────┤
│  PR Audit    │  Migration   │  Health      │  Managed DB        │
│  (per PR)    │  Safety      │  Monitoring  │  Validation        │
│              │  (per PR on  │  (daily      │  (manual,          │
│              │   migrations)│   cron)      │   per-provider)    │
├──────────────┼──────────────┼──────────────┼────────────────────┤
│ Quick dev    │ Gate         │ Trend        │ Cloud-specific     │
│ feedback     │ deployments  │ tracking     │ compatibility      │
└──────────────┴──────────────┴──────────────┴────────────────────┘
```

## Available Workflows

### 1. `pgfirstaid-pr-audit.yml` — **PR Developer Feedback**

Posts a pgFirstAid audit summary as a PR comment on every push. Gives developers immediate visibility into database health impact of their changes without leaving the PR.

**Use Case:** Add to your standard CI — every PR automatically learns about DB health.

**Triggers:** Pull request (opened, synchronize, reopened) + workflow_dispatch

**Key Features:**
- Runs pgFirstAid against your staging database
- Posts/updates a single PR comment with severity summary and full findings table
- Fails the job if findings meet the configured threshold (CRITICAL/HIGH/MEDIUM/LOW/NONE)
- Uses a standalone Python script — no postgres client setup required in CI

**Files to copy into your repo:**

| File | Destination |
|---|---|
| `pgfirstaid-pr-audit.yml` | `.github/workflows/pgfirstaid-pr-audit.yml` |
| `pgfirstaid_audit.py` | `.github/scripts/pgfirstaid_audit.py` |

**Setup:**

1. Copy the files:
```bash
mkdir -p .github/workflows .github/scripts
cp pgfirstaid-pr-audit.yml .github/workflows/
cp pgfirstaid_audit.py .github/scripts/
```

2. Add the database secret in **Settings → Secrets and variables → Actions**:

| Secret name | Value |
|---|---|
| `STAGING_DATABASE_URL` | `postgresql://user:password@host:5432/dbname` |

Any [libpq connection string](https://www.postgresql.org/docs/current/libpq-connect.html#LIBPQ-CONNSTRING) format works.

3. Configure the threshold in the workflow's `env` block:
```yaml
env:
  PGFIRSTAID_VERSION: v2.1.1   # Pin to a tag for stability
  PGFIRSTAID_FAIL_SEVERITY: HIGH  # CRITICAL | HIGH | MEDIUM | LOW | NONE
```

`NONE` posts results without ever failing the job — useful for teams that want visibility before enforcing a gate.

4. Database permissions — the database user needs `SELECT` on system catalogs. Most read-only users already have this. If you hit permission errors:
```sql
GRANT pg_monitor TO your_ci_user;
```
`pg_monitor` is a built-in PostgreSQL role (10+) that covers the catalog views pgFirstAid queries.

**Network access:** The GitHub-hosted runner needs a route to your staging database.
- **Public staging DB** — works out of the box. Restrict by IP using [GitHub's runner IP ranges](https://api.github.com/meta).
- **VPC / private network** — use [Tailscale GitHub Action](https://github.com/tailscale/github-action) to join the runner to your mesh, or a [self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners) inside your network.

**Manual runs:** The workflow includes `workflow_dispatch`, so you can trigger an audit from **Actions → pgFirstAid Staging Audit → Run workflow**. Without a PR, results print to the job log instead of posting a comment.

**Example PR comment output:**
```
### pgFirstAid Audit

| Severity | Count |
|---|---|
| CRITICAL | 1 |
| HIGH | 2 |
| MEDIUM | 3 |

<details>
<summary>Full results (6 findings)</summary>

| Severity | Category | Check | Object | Issue | Recommended Action |
...

</details>

> Job failed — findings at or above `HIGH` threshold were found.
```

---

### 2. `pre-post-migration-validate.yml` — **Migration Safety Gate**

Validates database health before and after migrations. This is the **only workflow that gates deployments** — it blocks if migrations introduce new critical issues.

**Use Case:** Essential for any project with database migrations. Add to your CI to prevent migration regressions.

**Triggers:** Pull requests changing `migrations/**`, `db/**`, or `pgFirstAid.sql` + workflow_dispatch

**Key Features:**
- Captures a baseline health snapshot before migrations
- Applies migrations (Flyway, Liquibase, or direct SQL)
- Compares post-migration health against the pre-migration baseline
- Detects new critical/high issues introduced by the migration
- Blocks the deployment pipeline if regressions are found

**Secrets required:**

| Secret | Value |
|---|---|
| `PGHOST` | Database hostname |
| `PGUSER` | Database user |
| `PGPASSWORD` | Database password |
| `PGDATABASE` | Database name |

**Example Integration:**
```yaml
jobs:
  validate-migration:
    uses: ./.github/workflows/pre-post-migration-validate.yml
    with:
      environment: staging
```

---

### 3. `db-health-checks.yml` — **Scheduled Health Monitoring**

Tracks database health trends over time via daily cron. Generates full reports and compares against previous baselines to detect degradation.

**Use Case:** Set up daily monitoring to catch slow-burn issues like bloat growth, connection creep, and missing maintenance.

**Triggers:** Daily schedule (2 AM UTC) + workflow_dispatch

**Available Jobs:**

| Job | Description | Trigger |
|-----|-------------|---------|
| `full-health-check` | Complete health report with CSV + JSON export | Schedule or manual |
| `baseline-comparison` | Compare with previous run to detect new issues | Daily schedule |

**Secrets required:**

| Secret | Value |
|---|---|
| `PGHOST` | Database hostname |
| `PGUSER` | Database user |
| `PGPASSWORD` | Database password |
| `PGDATABASE` | Database name |

**Scheduled Daily Health Check:**
```yaml
jobs:
  daily-health:
    uses: ./.github/workflows/db-health-checks.yml
```

---

### 4. `managed-db-validate.yml` — **Cloud Compatibility Validation**

Validates pgFirstAid against a specific cloud-managed PostgreSQL instance (AWS RDS, GCP Cloud SQL, or Azure).

**Use Case:** Test pgFirstAid compatibility with your managed PostgreSQL provider, or validate cloud-specific configuration.

**Triggers:** Manual dispatch only (choose provider + instance)

**Supported Providers:**
- AWS RDS (resolves endpoint via `describe-db-instances`)
- GCP Cloud SQL (resolves via `gcloud sql instances describe`)
- Azure Database for PostgreSQL Flexible Server (resolves via `az postgres flexible-server show`)

**Secrets required by provider:**

| Provider | Secrets |
|---|---|
| AWS RDS | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_RDS_USER`, `AWS_RDS_PASSWORD` |
| GCP Cloud SQL | `GCP_PROJECT_ID`, `GCP_CLOUD_SQL_USER`, `GCP_CLOUD_SQL_PASSWORD` |
| Azure | `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`, `AZURE_POSTGRESQL_USER`, `AZURE_POSTGRESQL_PASSWORD` |

**Manual Trigger:**
```yaml
# Via GitHub UI: Actions → Managed Database Validation → Run workflow
# Set cloud_provider, db_identifier, region (and resource_group for Azure)
```

## Understanding pgFirstAid Output

The `pg_firstAid()` function returns health issues organized by severity:

### Severity Levels

| Severity | Meaning | CI Action |
|----------|---------|-----------|
| `CRITICAL` | Must fix immediately | Block deployment |
| `HIGH` | Should fix soon | Warn, allow deployment |
| `MEDIUM` | Monitor and plan | Log only |
| `LOW` | Nice to have | Informational |
| `INFO` | General information | Informational |

### Common Health Checks

| Check Name | Description |
|------------|-------------|
| `Missing Primary Key` | Tables without primary keys |
| `Table Bloat` | Tables with excessive dead tuples |
| `Duplicate Index` | Redundant indexes |
| `Unused Large Index` | Large indexes with low usage |
| `Blocked and Blocking Queries` | Query lock waits |
| `Long Running Queries` | Queries exceeding threshold |

### Sample Output

```
 severity |     category      |      check_name      | object_name | issue_description | recommended_action
----------+-------------------+----------------------+-------------+-------------------+-------------------
 CRITICAL | Structural Health | Missing Primary Key  | users       | Table missing primary key | Add primary key to users table
 HIGH    | Structural Health | Missing Statistics   | orders      | Statistics not updated recently | Run ANALYZE on orders table
```

## Integrating with Migration Tools

### Flyway

```yaml
- name: Pre-Migration Health Check
  run: psql -c "SELECT count(*) FROM pg_firstAid() WHERE severity='CRITICAL';"
  
- name: Apply Migrations
  run: flyway migrate
  
- name: Post-Migration Health Check
  run: |
    psql -c "SELECT count(*) FROM pg_firstAid() WHERE severity='CRITICAL';"
```

### Liquibase

```yaml
- name: Pre-Migration Health Check
  run: psql -c "SELECT count(*) FROM pg_firstAid() WHERE severity='CRITICAL';"
  
- name: Apply Migrations
  run: mvn liquibase:update
  
- name: Post-Migration Health Check
  run: psql -c "SELECT count(*) FROM pg_firstAid() WHERE severity='CRITICAL';"
```

### ArgoCD (Helm with pgFirstAid)

```yaml
# values.yml
pgFirstAid:
  enabled: true
  functionFile: pgFirstAid.sql
  viewFile: view_pgFirstAid.sql
  
  healthCheck:
    enabled: true
    checkInterval: 60s
    severityThreshold: critical
```

## Troubleshooting

### pg_firstAid function not found

Make sure you've installed the function:
```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
\i pgFirstAid.sql
\i view_pgFirstAid.sql
```

### Permission errors

If you don't have superuser access, use the managed view:
```sql
\i view_pgFirstAid_managed.sql
```

This version works with limited privileges and doesn't require DROP privileges.

### Connection timeouts

For cloud databases, ensure you're using the correct connection parameters:
- AWS RDS: Use the endpoint from `describe-db-instances`
- GCP Cloud SQL: Use the IP from `gcloud sql instances describe`
- Azure: Use the `defaultHostName` from `az postgres flexible-server show`

## Best Practices

1. **Run health checks in staging before production**
2. **Block deployments on new CRITICAL issues**
3. **Review HIGH issues weekly**
4. **Track trends over time** (use baseline comparison)
5. **Document any known exceptions** (e.g., tables that intentionally lack primary keys)

## Security Considerations

- Store database credentials as secrets, never in workflow files
- Use pgFirstAid's managed view for limited-privilege users
- Regularly rotate database credentials
- Restrict workflow access to authorized personnel only

## License

This workflow is provided under the same license as pgFirstAid.
