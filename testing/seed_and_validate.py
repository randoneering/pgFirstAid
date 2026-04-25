#!/usr/bin/env python3
"""pgFirstAid seed and validation orchestrator.

Creates a throwaway PostgreSQL database, seeds data that triggers every
pgFirstAid health check, runs live-session background threads, then
validates that all expected checks fire.

Usage:
    python testing/seed_and_validate.py [--host H] [--port P] [--user U] [--password W]

Connection parameters default to PGHOST/PGPORT/PGUSER/PGPASSWORD env vars.
Requires superuser or CREATEDB + CREATE ROLE privileges.

Dependency:
    pip install psycopg2-binary
"""

import argparse
import os
import re
import subprocess
import sys
import threading
import time
from typing import Any
from pathlib import Path

import psycopg2
from psycopg2 import Error, errors
from psycopg2.extensions import connection as PgConnection

SEED_DIR = Path(__file__).resolve().parent / "healthcheck_seed"
PG_FIRSTAID_SQL = Path(__file__).resolve().parent.parent / "pgFirstAid.sql"
PG_FIRSTAID_MANAGED_SQL = Path(__file__).resolve().parent.parent / "view_pgFirstAid_managed.sql"
TEST_DB = "pgfirstaid_test"

# Each tuple is (pattern, replacement). Applied in order.
_THRESHOLD_PATCHES: list[tuple[str, str]] = [
    # Unused Large Index: 100MB -> 8KB
    (r"> 104857600", "> 8192"),
    # Tables larger than 100GB -> 1MB
    (r"> 107374182400", "> 1048576"),
    # Tables larger than 50-100GB -> 512KB-1MB
    (r"between 53687091200 and 107374182400", "between 524288 and 1048576"),
]


def patch_thresholds(sql: str) -> str:
    """Return sql with size thresholds replaced by test-friendly values.

    The original pgFirstAid.sql file is never modified; callers receive
    the patched text and install it directly into the test database.
    """
    for pattern, replacement in _THRESHOLD_PATCHES:
        sql = re.sub(pattern, replacement, sql)
    return sql


def get_conn_params(args: argparse.Namespace) -> dict:
    """Build psycopg2 connection kwargs from CLI args and env vars.

    CLI args take precedence over env vars; env vars over built-in defaults.
    The returned dict always contains dbname='postgres' (maintenance db).
    """
    return {
        "host": args.host or os.environ.get("PGHOST", "localhost"),
        "port": int(args.port or os.environ.get("PGPORT", 5432)),
        "user": args.user or os.environ.get("PGUSER", "postgres"),
        "password": args.password or os.environ.get("PGPASSWORD", ""),
        "sslmode": os.environ.get("PGSSLMODE", "prefer"),
        "dbname": "postgres",
    }


def _connect(params: dict[str, Any], *, autocommit: bool) -> PgConnection:
    conn = psycopg2.connect(**params)
    conn.autocommit = autocommit
    return conn


def _execute(
    conn: Any,
    query: str,
    params: tuple[Any, ...] | None = None,
) -> None:
    if not hasattr(conn, "cursor"):
        if params is None:
            conn.execute(query)
        else:
            conn.execute(query, params)
        return

    with conn.cursor() as cur:
        cur.execute(query, params)


def _fetchone(
    conn: Any,
    query: str,
    params: tuple[Any, ...] | None = None,
) -> tuple[Any, ...] | None:
    if not hasattr(conn, "cursor"):
        if params is None:
            result = conn.execute(query)
        else:
            result = conn.execute(query, params)
        return result.fetchone()

    with conn.cursor() as cur:
        cur.execute(query, params)
        return cur.fetchone()


def _fetchall(
    conn: Any,
    query: str,
    params: tuple[Any, ...] | None = None,
) -> list[tuple[Any, ...]]:
    if not hasattr(conn, "cursor"):
        if params is None:
            result = conn.execute(query)
        else:
            result = conn.execute(query, params)
        return result.fetchall()

    with conn.cursor() as cur:
        cur.execute(query, params)
        return cur.fetchall()


def connect_admin(params: dict[str, Any]) -> PgConnection:
    """Connect to the maintenance database with autocommit (for CREATE/DROP DATABASE)."""
    return _connect(params, autocommit=True)


def connect_test(params: dict[str, Any]) -> PgConnection:
    """Connect to the test database with autocommit for DDL."""
    test_params = {**params, "dbname": TEST_DB}
    return _connect(test_params, autocommit=True)


def create_test_db(admin_conn: PgConnection) -> None:
    """Drop and recreate the test database from scratch."""
    # Terminate any existing connections to the test db before dropping.
    _execute(
        admin_conn,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        "WHERE datname = %s AND pid <> pg_backend_pid()",
        (TEST_DB,),
    )
    _execute(admin_conn, f"DROP DATABASE IF EXISTS {TEST_DB}")
    _execute(admin_conn, f"CREATE DATABASE {TEST_DB}")


def drop_test_db(admin_conn: PgConnection) -> None:
    """Terminate all connections to the test database and drop it."""
    _execute(
        admin_conn,
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        "WHERE datname = %s AND pid <> pg_backend_pid()",
        (TEST_DB,),
    )
    _execute(admin_conn, f"DROP DATABASE IF EXISTS {TEST_DB}")


def drop_seed_role(admin_conn: PgConnection) -> None:
    """Drop the cluster-level seed role left behind after test DB is dropped."""
    try:
        _execute(admin_conn, "DROP ROLE IF EXISTS pgfirstaid_seed_role")
    except Exception as exc:
        print(f"  WARNING: failed to drop pgfirstaid_seed_role: {exc}")


def install_function(test_conn: PgConnection, managed: bool = False) -> None:
    """Read and install pgFirstAid SQL into the test DB, patching thresholds.

    When managed=True, installs view_pgFirstAid_managed.sql (view-based, no
    superuser-only queries) instead of the default function-based pgFirstAid.sql.
    """
    sql_file = PG_FIRSTAID_MANAGED_SQL if managed else PG_FIRSTAID_SQL
    sql = sql_file.read_text()
    patched = patch_thresholds(sql)
    _execute(test_conn, patched)


def run_sql_file(test_conn: PgConnection, path: Path) -> None:
    """Execute a plain SQL file against the test connection."""
    _execute(test_conn, path.read_text())


def run_psql_file(params: dict, path: Path) -> bool:
    """Run a SQL file via psql subprocess (required for \\gexec support).

    Returns True on success, False if psql is unavailable or the file errors.
    """
    env = {**os.environ, "PGPASSWORD": params.get("password", "")}
    cmd = [
        "psql",
        f"--host={params['host']}",
        f"--port={params['port']}",
        f"--username={params['user']}",
        f"--dbname={TEST_DB}",
        f"--file={path}",
        "--no-psqlrc",
        "-v",
        "ON_ERROR_STOP=1",
    ]
    try:
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    except FileNotFoundError:
        print("  SKIP: psql not found — pg_stat_statements seed skipped")
        return False
    if result.returncode != 0:
        print(f"  WARNING: psql exited {result.returncode}:\n{result.stderr[:500]}")
        return False
    if result.stdout.strip():
        print(f"  psql output:\n{result.stdout[:1000]}")
    return True


def is_pss_queryable(test_conn: PgConnection) -> bool:
    """Return True only if the pg_stat_statements view is actually accessible.

    The extension may be installed (in pg_extension) but still crash at query
    time when pg_stat_statements is absent from shared_preload_libraries.
    """
    try:
        _execute(test_conn, "SELECT 1 FROM pg_stat_statements LIMIT 0")
        return True
    except Error:
        return False


def is_extension_installed(test_conn: PgConnection, extension_name: str) -> bool:
    """Return True if the named extension exists in pg_extension."""
    row = _fetchone(
        test_conn,
        "SELECT 1 FROM pg_extension WHERE extname = %s",
        (extension_name,),
    )
    return row is not None


def classify_pss_state(
    test_conn: PgConnection, psql_seed_succeeded: bool
) -> tuple[bool, bool]:
    """Return whether pg_stat_statements is installed and fully seedable."""
    installed = is_extension_installed(test_conn, "pg_stat_statements")
    seeded = psql_seed_succeeded and installed and is_pss_queryable(test_conn)
    return installed, seeded


def try_create_replication_slot(test_conn: PgConnection) -> bool:
    """Create a logical replication slot to trigger the inactive-slot check.

    Returns True if the slot was created, False if skipped due to
    wal_level != logical or insufficient privilege.
    """
    try:
        _execute(
            test_conn,
            "SELECT pg_create_logical_replication_slot("
            "    'pgfirstaid_test_slot', 'test_decoding')",
        )
        return True
    except errors.ObjectNotInPrerequisiteState:
        print(
            "  SKIP: wal_level != logical — Inactive Replication Slots check not seeded"
        )
        return False
    except errors.InsufficientPrivilege:
        print(
            "  SKIP: insufficient privilege — Inactive Replication Slots check not seeded"
        )
        return False
    except Error as error:
        message = str(error).lower()
        if "test_decoding" in message and (
            "does not exist" in message or "could not access file" in message
        ):
            print(
                "  SKIP: test_decoding unavailable — "
                "Inactive Replication Slots check not seeded"
            )
            return False
        raise


def drop_replication_slot(test_conn: PgConnection) -> None:
    """Drop the test replication slot if it exists."""
    try:
        _execute(test_conn, "SELECT pg_drop_replication_slot('pgfirstaid_test_slot')")
    except Exception:
        pass


def verify_seed_sizes(test_conn: PgConnection) -> None:
    """Warn if size-seeded tables are outside expected ranges after patching."""
    row = _fetchone(
        test_conn,
        """
        SELECT
            pg_relation_size('pgfirstaid_seed.large_table')  AS large_bytes,
            pg_relation_size('pgfirstaid_seed.medium_table') AS medium_bytes
    """,
    )
    large_bytes, medium_bytes = row
    if large_bytes <= 1_048_576:
        print(
            f"  WARNING: large_table is {large_bytes} bytes — may not trigger >1MB check"
        )
    if not (524_288 <= medium_bytes <= 1_048_576):
        print(
            f"  WARNING: medium_table is {medium_bytes} bytes — "
            f"expected 524288–1048576 for 50GB patched check"
        )


def seed_low_usage_index_scans(test_conn: PgConnection) -> None:
    """Run low-cardinality index lookups as separate statements so stats record them."""
    for value in range(1, 6):
        _execute(
            test_conn,
            "SELECT id FROM pgfirstaid_seed.low_usage_idx_table "
            "WHERE search_key = md5(%s::text) LIMIT 1",
            (str(value),),
        )


def wait_for_index_scan_count(
    test_conn: PgConnection,
    index_name: str,
    min_scans: int = 1,
    timeout: int = 5,
) -> bool:
    """Wait for pg_stat_user_indexes to reflect recent scans for an index."""
    for _ in range(timeout):
        row = _fetchone(
            test_conn,
            "SELECT idx_scan FROM pg_stat_user_indexes WHERE indexrelname = %s",
            (index_name,),
        )
        if row and row[0] >= min_scans:
            return True
        time.sleep(1.0)
    return False


# ---------------------------------------------------------------------------
# Live session threads
# Each thread opens its own psycopg2 connection and holds it open to trigger
# session-based health checks. All threads are daemon threads so they are
# automatically killed when the main process exits.
# ---------------------------------------------------------------------------


def _blocker_thread(
    params: dict, ready: threading.Event, stop: threading.Event
) -> None:
    """Hold an UPDATE lock on lock_target row 1 for the duration of the test."""
    conn = psycopg2.connect(**{**params, "dbname": TEST_DB})
    conn.autocommit = False
    _execute(
        conn,
        "UPDATE pgfirstaid_seed.lock_target SET payload = 'locked_by_blocker' WHERE id = 1",
    )
    ready.set()
    stop.wait(timeout=700)
    try:
        conn.rollback()
    except Exception:
        pass
    conn.close()


def _blocked_thread(params: dict, blocker_ready: threading.Event) -> None:
    """Attempt to UPDATE the same row as the blocker — will wait on the lock."""
    blocker_ready.wait()
    time.sleep(0.5)  # Ensure blocker's lock is fully held before we attempt.
    conn = psycopg2.connect(**{**params, "dbname": TEST_DB})
    conn.autocommit = False
    try:
        _execute(
            conn,
            "UPDATE pgfirstaid_seed.lock_target SET payload = 'blocked' WHERE id = 1",
        )
    except Exception:
        pass
    finally:
        try:
            conn.rollback()
        except Exception:
            pass
        conn.close()


def _idle_in_txn_thread(
    params: dict, ready: threading.Event, stop: threading.Event
) -> None:
    """Open a transaction and remain idle — triggers Idle In Transaction checks."""
    conn = psycopg2.connect(**{**params, "dbname": TEST_DB})
    conn.autocommit = False
    _execute(conn, "SELECT 1")  # Starts the transaction; connection is now idle in txn.
    ready.set()
    stop.wait(timeout=700)
    try:
        conn.rollback()
    except Exception:
        pass
    conn.close()


def _long_query_thread(params: dict) -> None:
    """Run a long-sleeping query — triggers Long Running Queries checks.

    pg_sleep blocks psycopg2 query execution until the backend is terminated, so this
    thread has no cooperative stop signal; drop_test_db() issues
    pg_terminate_backend against the test DB which unblocks the sleep and
    lets the thread exit.
    """
    conn = psycopg2.connect(**{**params, "dbname": TEST_DB})
    try:
        _execute(conn, "SELECT pg_sleep(700)")
    except Exception:
        pass
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Wait helpers — poll pg_stat_activity / pg_locks from the admin connection
# ---------------------------------------------------------------------------


def _wait_for_blocked(admin_conn: PgConnection, timeout: int = 30) -> bool:
    """Wait until at least one session is waiting on a lock in TEST_DB."""
    for _ in range(timeout):
        row = _fetchone(
            admin_conn,
            "SELECT 1 FROM pg_locks l "
            "JOIN pg_stat_activity a ON l.pid = a.pid "
            "WHERE NOT l.granted AND a.datname = %s",
            (TEST_DB,),
        )
        if row:
            return True
        time.sleep(1)
    return False


def _wait_for_state(admin_conn: PgConnection, state: str, timeout: int = 30) -> bool:
    """Wait until at least one session in TEST_DB has the given state."""
    for _ in range(timeout):
        row = _fetchone(
            admin_conn,
            "SELECT 1 FROM pg_stat_activity "
            "WHERE state = %s AND datname = %s AND pid <> pg_backend_pid()",
            (state, TEST_DB),
        )
        if row:
            return True
        time.sleep(1)
    return False


def _wait_for_active_query(
    admin_conn: PgConnection, min_seconds: int = 35, timeout: int = 60
) -> bool:
    """Wait until a session in TEST_DB has been active for at least min_seconds."""
    for _ in range(timeout):
        row = _fetchone(
            admin_conn,
            "SELECT 1 FROM pg_stat_activity "
            "WHERE state = 'active' AND datname = %s "
            "AND now() - query_start > make_interval(secs => %s) "
            "AND pid <> pg_backend_pid()",
            (TEST_DB, min_seconds),
        )
        if row:
            return True
        time.sleep(1)
    return False


def start_session_threads(
    params: dict[str, Any], admin_conn: PgConnection
) -> tuple[list[threading.Thread], threading.Event]:
    """Start all live-session daemon threads and wait for each to establish.

    Returns the list of threads and a stop event. Set the stop event to
    signal threads to clean up before the database is dropped.
    """
    stop = threading.Event()
    blocker_ready = threading.Event()
    idle_ready = threading.Event()

    threads = [
        threading.Thread(
            target=_blocker_thread, args=(params, blocker_ready, stop), daemon=True
        ),
        threading.Thread(
            target=_blocked_thread, args=(params, blocker_ready), daemon=True
        ),
        threading.Thread(
            target=_idle_in_txn_thread, args=(params, idle_ready, stop), daemon=True
        ),
        threading.Thread(target=_long_query_thread, args=(params,), daemon=True),
    ]

    print("  Starting blocker thread...")
    threads[0].start()
    blocker_ready.wait(timeout=10)

    print("  Starting blocked thread...")
    threads[1].start()
    if not _wait_for_blocked(admin_conn, timeout=15):
        print("  WARNING: blocked session did not appear in pg_locks within 15s")

    print("  Starting idle-in-transaction thread...")
    threads[2].start()
    idle_ready.wait(timeout=10)
    if not _wait_for_state(admin_conn, "idle in transaction", timeout=15):
        print("  WARNING: idle-in-transaction session did not appear within 15s")

    print("  Starting long query thread...")
    threads[3].start()

    return threads, stop


# ---------------------------------------------------------------------------
# Expected checks: every check_name that should appear in pg_firstAid()
# output after a complete seed run.
# ---------------------------------------------------------------------------

# Checks that always fire regardless of seed data.
_ALWAYS_FIRE: frozenset[str] = frozenset(
    {
        "Database Size",
        "PostgreSQL Version",
        "shared_buffers Setting",
        "work_mem Setting",
        "effective_cache_size Setting",
        "maintenance_work_mem Setting",
        "Transaction ID Wraparound Risk",
        "Checkpoint Stats",
        "Server Role",
        "Connection Utilization",
        "Installed Extension",
        "Server Uptime",
        "Is Logging Enabled",
        "Size of ALL Logfiles combined",
    }
)

# Checks seeded by 01_seed_static_checks.sql.
_STATIC_CHECKS: frozenset[str] = frozenset(
    {
        "Missing Primary Key",
        "Unused Large Index",
        "Duplicate Index",
        "Table with more than 200 columns",
        "Missing Statistics",
        "Tables larger than 100GB",
        "Tables larger than 50GB",
        "Outdated Statistics",
        "Table with more than 50 columns",
        "Low Index Efficiency",
        "Excessive Sequential Scans",
        "Missing FK Index",
        "Table With Single Or No Columns",
        "Table With No Activity Since Stats Reset",
        "Role Never Logged In",
        "Empty Table",
        "Index With Very Low Usage",
    }
)

# Checks seeded by live session threads.
_SESSION_CHECKS: frozenset[str] = frozenset(
    {
        "Current Blocked/Blocking Queries",
        "Long Running Queries",
        "Top 10 Expensive Active Queries",
        "Lock-Wait-Heavy Active Queries",
        "Idle In Transaction Over 5 Minutes",
    }
)

# pg_stat_statements workload checks (seeded by 02_seed_pg_stat_statements.sql).
_PSS_WORKLOAD_CHECKS: frozenset[str] = frozenset(
    {
        "Top 10 Queries by Total Execution Time",
        "High Mean Execution Time Queries",
        "Top 10 Queries by Temp Block Spills",
        "Low Cache Hit Ratio Queries",
        "High Runtime Variance Queries",
        "High Calls Low Value Queries",
        "High Rows Per Call Queries",
        "High Shared Block Reads Per Call Queries",
        "Top Queries by WAL Bytes Per Call",
    }
)

# Checks that fire when pg_stat_statements is absent.
_PSS_MISSING_CHECK: str = "pg_stat_statements Extension Missing"

# Checks that require wal_level=logical (conditional).
_REPLICATION_CHECKS: frozenset[str] = frozenset(
    {
        "Inactive Replication Slots",
    }
)

# Checks intentionally not seeded.
_NEVER_SEEDED: frozenset[str] = frozenset(
    {
        "High Connection Count",
        "Replication Slots Near Max Wal Size",
        "Table Bloat (Detailed)",
        "Idle Connections Over 1 Hour",
    }
)

_MANAGED_UNSUPPORTED_CHECKS: frozenset[str] = frozenset(
    {
        "Empty Table",
        "Index With Very Low Usage",
        "Role Never Logged In",
        "Table With No Activity Since Stats Reset",
    }
)

_DEFAULT_ONLY_CHECKS: dict[str, tuple[str, str]] = {
    "shared_buffers At Default": ("shared_buffers", "128MB"),
    "work_mem At Default": ("work_mem", "4MB"),
}


def classify_default_setting_checks(
    test_conn: PgConnection,
) -> tuple[set[str], set[str]]:
    """Return expected and skipped checks for settings that only fire at defaults."""
    expected: set[str] = set()
    skipped: set[str] = set()

    for check_name, (setting_name, default_value) in _DEFAULT_ONLY_CHECKS.items():
        row = _fetchone(
            test_conn,
            "SELECT pg_size_bytes(current_setting(%s)) = pg_size_bytes(%s)",
            (setting_name, default_value),
        )
        if row and row[0]:
            expected.add(check_name)
        else:
            skipped.add(check_name)

    return expected, skipped


def build_report(
    fired: set[str],
    expected: set[str],
    skipped: set[str],
) -> tuple[list[str], list[str], list[str]]:
    """Classify each expected check as passed, failed, or skipped.

    Returns (passed, failed, skipped_list) — each is a sorted list of check names.
    A check in `skipped` is never placed in `failed`, even if it did not fire.
    """
    passed: list[str] = []
    failed: list[str] = []
    skipped_list: list[str] = []

    for check in sorted(expected):
        if check in skipped:
            skipped_list.append(check)
        elif check in fired:
            passed.append(check)
        else:
            failed.append(check)

    return passed, failed, skipped_list


def run_validation(
    test_conn: PgConnection,
    replication_slot_created: bool,
    pss_seeded: bool,
    pss_extension_installed: bool = False,
    managed: bool = False,
) -> bool:
    """Run pg_firstAid() or SELECT from v_pgfirstAid and compare to expected checks.

    Returns True if all non-skipped expected checks fired, False otherwise.
    """
    query = (
        "SELECT check_name, count(*) FROM v_pgfirstAid GROUP BY check_name"
        if managed
        else "SELECT check_name, count(*) FROM pg_firstAid() GROUP BY check_name"
    )
    rows = _fetchall(test_conn, query)
    fired: set[str] = {row[0] for row in rows}

    expected = set(_ALWAYS_FIRE) | set(_STATIC_CHECKS) | set(_SESSION_CHECKS)

    skipped = set(_NEVER_SEEDED)

    default_expected, default_skipped = classify_default_setting_checks(test_conn)
    expected |= default_expected
    skipped |= default_skipped

    if managed:
        skipped |= set(_MANAGED_UNSUPPORTED_CHECKS)

    if pss_seeded:
        expected |= set(_PSS_WORKLOAD_CHECKS)
    elif pss_extension_installed:
        # Extension installed but not queryable (not in shared_preload_libraries).
        # Neither workload checks nor "Extension Missing" check will fire.
        skipped.add(_PSS_MISSING_CHECK)
    else:
        expected.add(_PSS_MISSING_CHECK)

    if replication_slot_created:
        expected |= set(_REPLICATION_CHECKS)
    else:
        skipped |= set(_REPLICATION_CHECKS)

    passed, failed, skipped_list = build_report(fired, expected, skipped)

    print("\n=== pgFirstAid Validation Results ===\n")
    for check in passed:
        print(f"  PASS  {check}")
    for check in failed:
        print(f"  FAIL  {check}")
    for check in skipped_list:
        print(f"  SKIP  {check}")

    total = len(passed) + len(failed)
    print(
        f"\n  {len(passed)}/{total} checks passed"
        f", {len(skipped_list)} skipped"
        f", {len(failed)} failed\n"
    )

    return len(failed) == 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Seed and validate all pgFirstAid health checks"
    )
    parser.add_argument(
        "--host", default=None, help="PostgreSQL host (default: PGHOST or localhost)"
    )
    parser.add_argument(
        "--port", default=None, help="PostgreSQL port (default: PGPORT or 5432)"
    )
    parser.add_argument(
        "--user", default=None, help="PostgreSQL user (default: PGUSER or postgres)"
    )
    parser.add_argument(
        "--password", default=None, help="PostgreSQL password (default: PGPASSWORD)"
    )
    parser.add_argument(
        "--managed",
        action="store_true",
        default=False,
        help="Install view_pgFirstAid_managed.sql and query v_pgfirstAid instead of pg_firstaid()",
    )
    return parser.parse_args()


def main() -> int:
    """Orchestrate the full seed-and-validate run. Returns exit code (0 = pass)."""
    args = parse_args()
    params = get_conn_params(args)

    managed = args.managed
    mode_label = "managed (v_pgfirstAid)" if managed else "standard (pg_firstaid())"
    print(
        f"Connecting to {params['user']}@{params['host']}:{params['port']} [{mode_label}]"
    )

    admin_conn = connect_admin(params)
    test_conn: PgConnection | None = None
    replication_slot_created = False
    pss_extension_installed = False
    pss_seeded = False
    stop_event: threading.Event | None = None
    success = False

    try:
        # --- Database setup -----------------------------------------------
        print(f"Creating test database '{TEST_DB}'...")
        create_test_db(admin_conn)

        test_conn = connect_test(params)

        print("Installing pgFirstAid with patched thresholds...")
        install_function(test_conn, managed=managed)

        # --- Static seed ------------------------------------------------------
        print("Seeding structural checks (01_seed_static_checks.sql)...")
        run_sql_file(test_conn, SEED_DIR / "01_seed_static_checks.sql")
        seed_low_usage_index_scans(test_conn)
        verify_seed_sizes(test_conn)
        if not wait_for_index_scan_count(test_conn, "pgfirstaid_seed_low_usage_idx"):
            print(
                "  WARNING: low-usage index scan stats did not become visible within 5s"
            )

        # --- pg_stat_statements seed (via psql for \gexec support) -----------
        print("Seeding pg_stat_statements workload (02_seed_pg_stat_statements.sql)...")
        psql_seed_succeeded = run_psql_file(
            params, SEED_DIR / "02_seed_pg_stat_statements.sql"
        )
        pss_extension_installed, pss_seeded = classify_pss_state(
            test_conn, psql_seed_succeeded
        )
        if pss_extension_installed and not pss_seeded:
            print(
                "  SKIP: pg_stat_statements not in shared_preload_libraries — PSS checks not seeded"
            )

        # --- Replication slot -------------------------------------------------
        print("Attempting replication slot seeding...")
        replication_slot_created = try_create_replication_slot(test_conn)

        # --- Live session threads ---------------------------------------------
        print("Starting live session threads...")
        _threads, stop_event = start_session_threads(params, admin_conn)

        # Wait for the long query to appear as an active query (>30s threshold).
        print(
            "Waiting 35s for active query threshold (Top 10 Expensive Active Queries)..."
        )
        if not _wait_for_active_query(admin_conn, min_seconds=35, timeout=60):
            print(
                "  WARNING: long query did not reach 35s threshold — check may not fire"
            )

        # Wait for idle-in-transaction and long-running query (>5 min threshold).
        print(
            "Waiting 6 minutes for 5-minute session thresholds "
            "(Long Running Queries, Idle In Transaction)..."
        )
        for minute in range(1, 7):
            time.sleep(60)
            print(f"  {minute}/6 minutes elapsed")

        # --- PSS diagnostic (before validation) --------------------------------
        if pss_seeded:
            if not is_pss_queryable(test_conn):
                print(
                    "  PSS diagnostic: pg_stat_statements not accessible — downgrading pss_seeded"
                )
                pss_seeded = False
            else:
                try:
                    row = _fetchone(
                        test_conn, "SELECT count(*) FROM pg_stat_statements"
                    )
                    print(
                        f"  PSS diagnostic: {row[0]} total entries in pg_stat_statements"
                    )
                except Error as e:
                    print(
                        f"  PSS diagnostic: query failed ({e}) — downgrading pss_seeded"
                    )
                    pss_seeded = False

        # --- Validate ---------------------------------------------------------
        target = "v_pgfirstAid" if managed else "pg_firstAid()"
        print(f"Running {target} validation...")
        success = run_validation(
            test_conn,
            replication_slot_created,
            pss_seeded,
            pss_extension_installed,
            managed,
        )

    finally:
        # Signal threads to stop and allow them to rollback cleanly.
        if stop_event is not None:
            stop_event.set()
            time.sleep(2)

        if replication_slot_created and test_conn is not None:
            drop_replication_slot(test_conn)

        if test_conn is not None:
            test_conn.close()

        print(f"Dropping test database '{TEST_DB}'...")
        drop_test_db(admin_conn)
        drop_seed_role(admin_conn)
        admin_conn.close()

    return 0 if success else 1


if __name__ == "__main__":
    sys.exit(main())
