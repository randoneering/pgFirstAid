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

## Existing CI installations

Dedicated CI databases can opt into the return-type upgrade with `PGFA_TEST_ALLOW_LEGACY_UPGRADE=1`.
The integration fixture and local workflow scripts then use `testing/ci_install.py` instead of bypassing the normal installer's guard.
The helper upgrades only the known eight-column function, in one transaction, preserving its owner, EXECUTE grants/grantors/options, and comment.
It refuses dependent objects with `RESTRICT` and rolls back on any error.
Unknown shapes and unsupported custom metadata require the manual upgrade procedure.
Use this opt-in only for dedicated test databases or disposable branches.

```bash
uv run python testing/ci_install.py --allow-legacy-upgrade
# Read a branch DSN from the named environment variable, not command arguments.
uv run python testing/ci_install.py --allow-legacy-upgrade --dsn-env DB_URL
```

Run these commands from the repository root.
`PG*` variables configure the first command.
The normal SQL installer remains guarded; production upgrades still need explicit review.
Regression tests for this helper use `PGFA_CI_INSTALL_TEST_DSN` and run with `uv run pytest testing/test_ci_install.py`.
`testing/test_ci_wiring.py` checks opt-in routing without database access and runs in PR Safe Checks.
Set `PGFA_TEST_NIX_PYTHON` to a Nix Python interpreter to also run the real binary-driver import regression in a fresh uv environment without `LD_LIBRARY_PATH`.

`pull_request_target` loads workflow definitions from the base branch.
When a PR changes those definitions, dispatch the workflow with the PR branch as its ref to validate the updated configuration before merging.

## Run tests

```bash
uv sync
uv run pytest tests/integration -m integration
```

## SQL helper generation

Edit `data/agent_prompt.sql` or `data/view_installer.sql`, then run `uv run python tools/sync_sql_helpers.py`.
`uv run python tools/sync_sql_helpers.py --check` validates the embedded copies without writing files.
Generator regression tests live in `tools/tests/test_sync_sql_helpers.py` and run in PR Safe Checks.

## Agent prompt tests

From the repository root, run against a disposable database using the standard `PG*` variables above:

```bash
uv run pytest testing/test_agent_prompts.py testing/test_query_context.py testing/test_audit_workflows.py testing/test_view_installation.py
```

`PGFA_PROMPT_TEST_DSN` can override the standard connection variables.
The tests install each SQL variant inside a transaction and roll back the fixture afterward.
They cover exact object evidence, every curated prompt, INFO omission, severity order, view grants/dependencies, explicit function recreation, and helper grants for restricted monitoring roles.
Query-context fixtures use schema-local catalog doubles inside rollback-only transactions to test colliding query IDs and sessions from other databases without creating live blockers.
They use ordinary tables so the permanent report view can safely reference them.
View-installation tests cover column-layout recovery, metadata preservation, dependency refusal, bounded locks, and rollback.
Workflow tests run the shipped psql installation commands against injected SQL failures and check handled Python audit errors without posting PR comments.
The self-hosted variants require access to the configured PostgreSQL log directory, even when it is empty.
