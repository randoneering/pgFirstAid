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
    pip install "psycopg[binary]"
"""

import argparse
import os
import re
import subprocess
import sys
import threading
import time
from pathlib import Path

import psycopg

SEED_DIR = Path(__file__).parent / "healthcheck_seed"
PG_FIRSTAID_SQL = Path(__file__).parent.parent / "pgFirstAid.sql"
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
    """Build psycopg connection kwargs from CLI args and env vars.

    CLI args take precedence over env vars; env vars over built-in defaults.
    The returned dict always contains dbname='postgres' (maintenance db).
    """
    return {
        "host": args.host or os.environ.get("PGHOST", "localhost"),
        "port": int(args.port or os.environ.get("PGPORT", 5432)),
        "user": args.user or os.environ.get("PGUSER", "postgres"),
        "password": args.password or os.environ.get("PGPASSWORD", ""),
        "dbname": "postgres",
    }


def connect_admin(params: dict) -> psycopg.Connection:
    """Connect to the maintenance database with autocommit (for CREATE/DROP DATABASE)."""
    return psycopg.connect(**params, autocommit=True)


def connect_test(params: dict) -> psycopg.Connection:
    """Connect to the test database with autocommit for DDL."""
    test_params = {**params, "dbname": TEST_DB}
    return psycopg.connect(**test_params, autocommit=True)


def create_test_db(admin_conn: psycopg.Connection) -> None:
    """Drop and recreate the test database from scratch."""
    # Terminate any existing connections to the test db before dropping.
    admin_conn.execute(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        "WHERE datname = %s AND pid <> pg_backend_pid()",
        (TEST_DB,),
    )
    admin_conn.execute(f"DROP DATABASE IF EXISTS {TEST_DB}")
    admin_conn.execute(f"CREATE DATABASE {TEST_DB}")


def drop_test_db(admin_conn: psycopg.Connection) -> None:
    """Terminate all connections to the test database and drop it."""
    admin_conn.execute(
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity "
        "WHERE datname = %s AND pid <> pg_backend_pid()",
        (TEST_DB,),
    )
    admin_conn.execute(f"DROP DATABASE IF EXISTS {TEST_DB}")


def install_function(test_conn: psycopg.Connection) -> None:
    """Read pgFirstAid.sql, patch thresholds, and install into test DB."""
    sql = PG_FIRSTAID_SQL.read_text()
    patched = patch_thresholds(sql)
    test_conn.execute(patched)


def run_sql_file(test_conn: psycopg.Connection, path: Path) -> None:
    """Execute a plain SQL file against the test connection."""
    test_conn.execute(path.read_text())


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
    ]
    try:
        result = subprocess.run(cmd, env=env, capture_output=True, text=True)
    except FileNotFoundError:
        print("  SKIP: psql not found — pg_stat_statements seed skipped")
        return False
    if result.returncode != 0:
        print(f"  WARNING: psql exited {result.returncode}:\n{result.stderr[:500]}")
        return False
    return True


def try_create_replication_slot(test_conn: psycopg.Connection) -> bool:
    """Create a logical replication slot to trigger the inactive-slot check.

    Returns True if the slot was created, False if skipped due to
    wal_level != logical or insufficient privilege.
    """
    try:
        test_conn.execute(
            "SELECT pg_create_logical_replication_slot("
            "    'pgfirstaid_test_slot', 'test_decoding')"
        )
        return True
    except psycopg.errors.ObjectNotInPrerequisiteState:
        print("  SKIP: wal_level != logical — Inactive Replication Slots check not seeded")
        return False
    except psycopg.errors.InsufficientPrivilege:
        print("  SKIP: insufficient privilege — Inactive Replication Slots check not seeded")
        return False


def drop_replication_slot(test_conn: psycopg.Connection) -> None:
    """Drop the test replication slot if it exists."""
    try:
        test_conn.execute(
            "SELECT pg_drop_replication_slot('pgfirstaid_test_slot')"
        )
    except Exception:
        pass


def verify_seed_sizes(test_conn: psycopg.Connection) -> None:
    """Warn if size-seeded tables are outside expected ranges after patching."""
    row = test_conn.execute("""
        SELECT
            pg_relation_size('pgfirstaid_seed.large_table')  AS large_bytes,
            pg_relation_size('pgfirstaid_seed.medium_table') AS medium_bytes
    """).fetchone()
    large_bytes, medium_bytes = row
    if large_bytes <= 1_048_576:
        print(f"  WARNING: large_table is {large_bytes} bytes — may not trigger >1MB check")
    if not (524_288 <= medium_bytes <= 1_048_576):
        print(
            f"  WARNING: medium_table is {medium_bytes} bytes — "
            f"expected 524288–1048576 for 50GB patched check"
        )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Seed and validate all pgFirstAid health checks"
    )
    parser.add_argument("--host", default=None, help="PostgreSQL host (default: PGHOST or localhost)")
    parser.add_argument("--port", default=None, help="PostgreSQL port (default: PGPORT or 5432)")
    parser.add_argument("--user", default=None, help="PostgreSQL user (default: PGUSER or postgres)")
    parser.add_argument("--password", default=None, help="PostgreSQL password (default: PGPASSWORD)")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    params = get_conn_params(args)
    print(f"Connecting to {params['user']}@{params['host']}:{params['port']}")
