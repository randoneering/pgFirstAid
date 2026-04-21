# pgFirstAid Health-Check Seed Kit

This folder contains SQL scripts to populate a database with data/workload patterns that trigger pgFirstAid checks.

The checks are a mix of:

- static metadata/data patterns (tables, indexes, stats)
- runtime/session behavior (locks, long-running queries, idle-in-transaction, active sessions)
- optional `pg_stat_statements` workload patterns

## Run Order

1. Load pgFirstAid (`pgFirstAid.sql` and optional view SQL).
2. Run `testing/healthcheck_seed/01_seed_static_checks.sql`.
3. Optional: run `testing/healthcheck_seed/02_seed_pg_stat_statements.sql` (run with `psql`, uses `\gexec`).
4. In separate terminals, run runtime scripts together:
   - session A: `03_session_blocker.sql`
   - session B: `04_session_blocked.sql`
   - session C: `05_session_idle_in_transaction.sql`
   - session D: `06_session_long_running_query.sql`
   - optional high-connection burst (55 active sessions):

```bash
pgbench "$PGDATABASE" -n -c 55 -j 10 -T 120 -f testing/healthcheck_seed/07_pgbench_active_query.sql
```
5. While runtime scripts are still open/running, execute:

```sql
SELECT severity, check_name, count(*) AS findings
FROM pg_firstAid()
GROUP BY severity, check_name
ORDER BY severity, check_name;
```

Or run `testing/healthcheck_seed/99_validate_seed_results.sql`.

## Notes / Constraints

- Some checks require elevated privileges (for example replication-slot checks and role creation).
- The 50GB/100GB table-size checks are intentionally not created by default in this kit. Creating truly large tables is usually too expensive for local/dev environments.
- `Unused Large Index` is generated and may take time/disk depending on your environment.
- `pg_stat_statements` checks only appear when the extension is installed and enabled.
