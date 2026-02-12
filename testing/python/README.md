# Python Integration Harness for pgFirstAid

This test harness runs pgFirstAid integration tests with `pytest`.
It combines:

- Python-driven integration tests (`psycopg`) for live runtime behavior
- Python-driven execution of the pgTAP SQL suite

## What this covers

- pgTAP assertions grouped by severity (`testing/pgTAP/01_*.sql` to `06_*.sql`)
- Python integration scenarios that need concurrent sessions and timing control
- Function/view parity assertions
- A coverage guard test that ensures every `check_name` in `pgFirstAid.sql` is
  referenced by at least one pgTAP assertion

## Prerequisites

- Python 3.11+
- `uv`
- A PostgreSQL test database with:
  - `pg_firstAid()` loaded
  - `v_pgfirstaid` loaded
  - permissions to create schema/table/extensions used in `testing/pgTAP/00_setup.sql`

## Configure connection

Set standard PostgreSQL environment variables before running tests:

```bash
export PGHOST=your-host
export PGPORT=5432
export PGUSER=your-user
export PGPASSWORD=your-password
export PGDATABASE=your-database
```

Optional tuning variables:

```bash
export PGFA_TEST_ACTIVE_CONN_TARGET=52
export PGFA_TEST_ACTIVE_CONN_SLEEP_SECONDS=20
export PGFA_TEST_WAIT_TIMEOUT_SECONDS=45
```

## Run tests

```bash
uv sync
uv run pytest tests/integration -m integration
```

Skip the slow connection test:

```bash
uv run pytest tests/integration -m "integration and not slow"
```

Run only pgTAP-driven tests:

```bash
uv run pytest tests/integration/test_pgtap_suite.py -m integration
```
