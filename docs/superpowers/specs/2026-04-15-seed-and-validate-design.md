# pgFirstAid Seed & Validation Script — Design Spec

**Date:** 2026-04-15  
**Branch:** feature/load_testing  
**Status:** Approved

---

## Goal

A Python script that creates a throwaway PostgreSQL database, seeds it with data that triggers every health check in `pgFirstAid.sql`, runs the function, and reports which checks fired vs. which were missing. Exit code 0 = all expected checks fired; exit code 1 = gaps found.

---

## Entry Point

**`testing/seed_and_validate.py`**

Single script. No third-party dependencies beyond `psycopg` (psycopg3). Invoked as:

```bash
python testing/seed_and_validate.py [--host localhost] [--port 5432] [--user postgres]
```

Connection parameters default to standard env vars (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`) with CLI overrides.

---

## Database Lifecycle

1. Connect to `postgres` (maintenance database) as superuser
2. Drop `pgfirstaid_test` if it exists
3. Create `pgfirstaid_test`
4. Run all seeding against `pgfirstaid_test`
5. Drop `pgfirstaid_test` on exit (success or failure) via a `finally` block

---

## Threshold Patching

`pgFirstAid.sql` contains thresholds that are impractical in a test environment. The script reads the file, applies regex substitutions in memory, and installs the patched function into the test DB. The original file is never modified.

| Check | Original threshold | Test threshold |
|---|---|---|
| Unused Large Index | `> 104857600` (100MB) | `> 8192` (8KB) |
| Tables larger than 100GB | `> 107374182400` | `> 1048576` (1MB) |
| Tables larger than 50GB | `between 53687091200 and 107374182400` | `between 524288 and 1048576` |

---

## SQL Seed Files

Located in `testing/healthcheck_seed/`. Each file is idempotent and targets the `pgfirstaid_seed` schema.

### `01_seed_static_checks.sql`

Seeds all structural checks that fire from schema state alone:

| Check triggered | Seeded object |
|---|---|
| Missing Primary Key (CRITICAL) | Table with no PK |
| Unused Large Index (CRITICAL) | Index on a table that is never scanned, sized above 8KB threshold |
| Duplicate Index (HIGH) | Two identical indexes on the same table and columns |
| Table with more than 200 columns (HIGH) | Table with 201 columns |
| Missing Statistics (HIGH) | Table with >1000 inserts, never analyzed |
| Outdated Statistics (MEDIUM) | Table with dead tuples exceeding autovacuum threshold |
| Table with more than 50 columns (MEDIUM) | Table with 60 columns |
| Low Index Efficiency (MEDIUM) | Non-selective index scanned >100 times; each scan reads many tuples (seeded via a loop of 110 queries using a predicate that matches most rows) |
| Excessive Sequential Scans (MEDIUM) | Table with >1000 seq scans produced by a seeding loop of sequential scans against a large table |
| Missing FK Index (LOW) | Table with FK constraint and no supporting index |
| Table With Single Or No Columns (LOW) | Table with 1 column |
| Table With No Activity Since Stats Reset (LOW) | Table created but never read or written |
| Role Never Logged In (LOW) | Role with LOGIN created but never connected |
| Empty Table (LOW) | Table with 0 rows |
| Index With Very Low Usage (LOW) | Index with 1–99 scans and size > 1MB — seeded via a loop that scans the index a small number of times |

> **Note:** Low Index Efficiency requires `idx_scan > 100` and `idx_tup_read / idx_scan > 1000`. The seed loop runs 110 queries using a predicate that hits the indexed column but matches a large fraction of rows, so each scan reads thousands of tuples.

### `02_seed_pg_stat_statements.sql`

Existing file. Seeds all pg_stat_statements checks. No changes needed.

---

## Live Session Strategy

Three background threads open `psycopg3` connections and hold them for the duration of the validation window.

| Thread | What it does | Checks triggered |
|---|---|---|
| **Blocker** | Opens `BEGIN`, runs `UPDATE` on a row, calls `pg_sleep(600)`, then `ROLLBACK` | Current Blocked/Blocking Queries, Lock-Wait-Heavy Active Queries |
| **Blocked** | Waits for blocker to establish, then attempts `UPDATE` on the same row | Current Blocked/Blocking Queries, Lock-Wait-Heavy Active Queries |
| **Idle-in-transaction** | Opens `BEGIN`, runs `SELECT 1`, then sleeps in Python for 6 minutes (transaction stays open) | Idle In Transaction Over 5 Minutes |
| **Long query** | Runs `SELECT pg_sleep(360)` | Long Running Queries (>5 min), Top 10 Expensive Active Queries (>30 sec) |

### Startup sequencing

1. Start Blocker thread; wait until its lock is confirmed held (poll `pg_locks`)
2. Start Blocked thread; wait until it appears in `pg_stat_activity` with `wait_event_type = 'Lock'`
3. Start Idle-in-transaction thread; wait until it appears in `pg_stat_activity` with `state = 'idle in transaction'`
4. Start Long query thread; wait until it appears in `pg_stat_activity` with runtime > 30 seconds
5. Proceed to validation

All threads are daemon threads. They are cancelled via `pg_terminate_backend()` during cleanup if they haven't exited naturally.

---

## Replication Slot Guard

```python
try:
    # Requires wal_level = logical and superuser
    conn.execute("SELECT pg_create_logical_replication_slot('pgfirstaid_test_slot', 'test_decoding')")
    # Slot is inactive by definition (no consumer attached)
    # Triggers: Inactive Replication Slots (HIGH)
    replication_slot_created = True
except psycopg.errors.ObjectNotInPrerequisiteState:
    print("SKIP: wal_level != logical — replication slot checks not seeded")
    replication_slot_created = False
except psycopg.errors.InsufficientPrivilege:
    print("SKIP: insufficient privilege to create replication slot")
    replication_slot_created = False
```

The slot is dropped during cleanup if it was created.

---

## Checks Not Seeded

| Check | Reason |
|---|---|
| High Connection Count (>50 active) | Requires 50+ concurrent connections — out of scope for a seed script; pgbench covers this (existing `07_pgbench_active_query.sql`) |
| Inactive Replication Slots Near Max WAL | Requires sustained WAL generation to push retained WAL near `safe_wal_size` — not deterministic in a test environment |
| shared_buffers At Default / work_mem At Default | These fire based on server config, not seeded data — always present on a default-configured server |
| Server Role (standby) | Always fires as INFO, content depends on actual server role |
| INFO checks (version, uptime, extensions, log size, etc.) | Always fire — no seeding needed |

---

## Validation

After the 6-minute idle-in-transaction window is established, run:

```sql
SELECT check_name, count(*) AS findings
FROM pg_firstAid()
GROUP BY check_name
ORDER BY check_name;
```

Compare results against an expected set defined in the script. Print a table:

```
PASS  Missing Primary Key
PASS  Duplicate Index
PASS  Idle In Transaction Over 5 Minutes
FAIL  Replication Slots Near Max Wal Size  (skipped — wal_level)
...
```

Exit 0 if all non-skipped checks fired. Exit 1 if any non-skipped check produced 0 rows.

---

## File Layout

```
testing/
  seed_and_validate.py          ← new: orchestrator
  healthcheck_seed/
    01_seed_static_checks.sql   ← rewrite: full structural seed
    02_seed_pg_stat_statements.sql  ← existing, unchanged
    03_session_blocker.sql      ← kept for manual use
    04_session_blocked.sql      ← kept for manual use
    05_session_idle_in_transaction.sql  ← kept for manual use
    06_session_long_running_query.sql   ← kept for manual use
    07_pgbench_active_query.sql ← kept for manual use
    99_validate_seed_results.sql ← kept for manual use
```

---

## Dependencies

- Python 3.11+
- `psycopg` (psycopg3): `pip install psycopg[binary]`
- PostgreSQL superuser access to the target server
