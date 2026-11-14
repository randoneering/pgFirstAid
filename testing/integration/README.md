# Python Integration/Validation Tests for pgFirstAid

This test harness runs pgFirstAid integration tests with `pytest`. One of the things I wanted to make sure this project does is validate each health check. While these tests might not be perfect, but the aim is to reduce the chances of a health check making its way into `main` and it fails to do its job.


It uses:

- Integration tests using (`psycopg`) for live runtime behavior(for checks looking for active connections)
- Execution of the pgTAP SQL suite sing Python
- The `testing/seed_and_validate.py` harness in CI for end-to-end seeded validation against live database targets

## What is covered

- pgTAP assertions grouped by severity (`testing/pgTAP/01_*.sql` to `06_*.sql`)
- Python integration scenarios that need concurrent sessions and timing control
- End-to-end seeded validation via `testing/seed_and_validate.py --managed` in the managed CI workflows
- Function/view parity assertions
- Per-finding agent prompts, quoted targets, all curated check branches, and function/view upgrades (`testing/test_agent_prompts.py`)
- A coverage guard test that ensures every `check_name` in `pgFirstAid.sql` is
  referenced by at least one pgTAP assertion

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

## Agent prompt tests

From the repository root, run against a disposable database using the standard `PG*` variables above:

```bash
uv run pytest testing/test_agent_prompts.py
```

`PGFA_PROMPT_TEST_DSN` can override the standard connection variables.
The tests install each SQL variant inside a transaction and roll back the fixture afterward.
They cover exact object evidence, every curated prompt, INFO omission, severity order, view grants/dependencies, explicit function recreation, and helper grants for restricted monitoring roles.
The self-hosted variants require access to the configured PostgreSQL log directory, even when it is empty.
