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
