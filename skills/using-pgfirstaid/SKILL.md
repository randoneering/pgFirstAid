---
name: using-pgfirstaid
description: Use when diagnosing PostgreSQL health, performance, or stability issues, or when asked to run a database health check, audit, or triage on a Postgres instance. Triggers on requests like "check the database", "is the db healthy", "find slow queries", "what's wrong with Postgres", "run pgFirstAid", or pre/post-deployment validation.
---

# Using pgFirstAid

## Overview

`pg_firstAid()` returns prioritized health issues (CRITICAL → INFO) from a single Postgres function. Works on self-hosted Postgres, RDS, Aurora, Cloud SQL, Neon, Supabase, and other managed services. Results vary by environment: managed services restrict access to some system catalogs and parameter settings, so a few checks return reduced output. Run as the highest-privilege role available.

## Quick Start

Self-hosted (install `pgFirstAid.sql`):

```sql
SELECT * FROM pg_firstAid();
```

Managed services (install `view_pgFirstAid_managed.sql`):

```sql
SELECT * FROM v_pgfirstAid;
```

The managed SQL creates the view, not the function, so managed callers must use the view. The view does not run `pg_stat_statements` checks.

## Output Schema

| Column | Meaning |
|---|---|
| `severity` | CRITICAL → INFO |
| `category` | Table Health, Query Health, Index Health, Replication Health, Database Health, Connection Health, Security Health, System Health, System Info |
| `check_name` | Label |
| `object_name` | Schema-qualified object, or `System` |

`issue_description` explains the problem, `current_value` shows the measured state, `recommended_action` suggests a fix, `documentation_link` points to the Postgres docs.

## Severity Workflow

| Severity | Action |
|---|---|
| CRITICAL | Follow the `documentation_link`, propose a fix or SQL, run the Verify Before Applying steps, then apply |
| HIGH | Follow the `documentation_link`, propose the SQL, include in the plan for this week |
| MEDIUM / LOW | Batch and review. Trust the `recommended_action` summary |
| INFO | Skip. Not action items |

Stop at the first rung with nothing to do. Always propose SQL as a draft the user signs off on, never auto-apply.

## Verify Before Applying

For any proposed SQL, before signing off:

1. **Dry-run transactional commands in a transaction** with `BEGIN; ... ROLLBACK;`. Non-transactional operations (`pg_terminate_backend`, `VACUUM FULL`, `REINDEX`, `CREATE INDEX CONCURRENTLY`) cannot be wrapped this way and need isolation on a staging copy instead.
2. **Test on a staging copy first.** Never apply CRITICAL or HIGH fixes to production untested.
3. **EXPLAIN to see the plan.** Plain `EXPLAIN` does not execute. Add `ANALYZE` only inside a transaction with rollback so DML runs but does not commit. On read replicas, `EXPLAIN` only (no write permission needed).
4. **Confirm affected rows** with `SELECT COUNT(*)` using the same `WHERE` before any DELETE or UPDATE.
5. **Backup before destructive ops.** `pg_dump` the affected table before DROP, TRUNCATE, or major ALTER.

## Common Patterns

```sql
-- Critical only
SELECT * FROM pg_firstAid() WHERE severity = 'CRITICAL';
```

## Common Mistakes

- Missing PK → drop table, or unused index → `DROP INDEX`. No, add a PK or unique constraint. Validate index usage over a representative window first.
- Skipping the `documentation_link`. For CRITICAL/HIGH, follow it before proposing a fix. The `recommended_action` is a summary; the doc has version-specific edge cases the summary omits.
- Skipping before/after snapshots. Capture `pg_firstAid()` output to CSV before and after the change; compare to confirm the fix removed the finding.

## When NOT to Use

- Automated fixes. pgFirstAid only reports, never modifies.
- Hot-loop monitoring. Run on a schedule, not per query.
- Cluster-wide audits. Function is per-database; loop over databases if needed.
