from __future__ import annotations

import json
import os
from collections.abc import Iterator
from pathlib import Path
from uuid import uuid4

import psycopg2
import pytest
from psycopg2 import sql
from psycopg2.extensions import connection as PgConnection

ROOT = Path(__file__).resolve().parents[1]
INSTALLERS = ["pgFirstAid.sql", "view_pgFirstAid.sql", "view_pgFirstAid_managed.sql"]
QUERY_CHECKS = [
    "Top 10 Queries by Total Execution Time",
    "High Mean Execution Time Queries",
    "Top 10 Queries by Temp Block Spills",
    "Low Cache Hit Ratio Queries",
    "High Runtime Variance Queries",
    "High Calls Low Value Queries",
    "High Rows Per Call Queries",
    "High Shared Block Reads Per Call Queries",
    "Top Queries by WAL Bytes Per Call",
    "Not In With Subquery",
]


@pytest.fixture(params=INSTALLERS)
def context_database(
    request: pytest.FixtureRequest,
) -> Iterator[tuple[PgConnection, str]]:
    dsn = os.getenv("PGFA_PROMPT_TEST_DSN")
    if not dsn and not all(
        os.getenv(key) for key in ("PGHOST", "PGUSER", "PGDATABASE")
    ):
        pytest.skip(
            "Set PGFA_PROMPT_TEST_DSN or PG* for a disposable PostgreSQL database"
        )
    conn = psycopg2.connect(dsn or "")
    try:
        with conn.cursor() as cur:
            schema = f"query_context_{uuid4().hex[:8]}"
            cur.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
            cur.execute(
                sql.SQL(
                    "SET LOCAL search_path TO {}, pg_temp, public, pg_catalog"
                ).format(sql.Identifier(schema))
            )
            # Pass the extension guard without requiring preload or live statistics.
            cur.execute(
                "CREATE EXTENSION IF NOT EXISTS pg_stat_statements WITH SCHEMA public"
            )
            cur.execute(
                "CREATE TABLE pg_stat_statements (LIKE public.pg_stat_statements)"
            )
        yield conn, request.param
    finally:
        conn.rollback()
        conn.close()


def report_rows(conn: PgConnection, installer: str) -> list[dict[str, str]]:
    target = "pg_firstaid()" if installer == "pgFirstAid.sql" else "v_pgfirstaid"
    with conn.cursor() as cur:
        cur.execute(f"SELECT * FROM {target}")
        columns = [column.name for column in cur.description]
        return [dict(zip(columns, row)) for row in cur.fetchall()]


@pytest.fixture
def query_workload(
    context_database: tuple[PgConnection, str],
) -> tuple[PgConnection, str, int, str, list[tuple[int, str]]]:
    conn, installer = context_database
    roles = []
    with conn.cursor() as cur:
        cur.execute(
            "SELECT oid, quote_ident(datname) FROM pg_database "
            "WHERE datname = current_database()"
        )
        dbid, database = cur.fetchone()
        cur.execute(
            "SELECT oid FROM pg_database WHERE datname <> current_database() LIMIT 1"
        )
        foreign_dbid = cur.fetchone()[0]
        for label in ['Query Role "one"', "Query.Role two"]:
            role = f"{label} {uuid4().hex[:8]}"
            cur.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(role)))
            cur.execute("SELECT oid FROM pg_roles WHERE rolname = %s", (role,))
            roles.append((cur.fetchone()[0], role))
        for userid, _ in roles:
            for profile in (0, 1):
                for foreign in range(13):
                    # Foreign rows fill each top ten unless filtering happens first.
                    scale = 100 + foreign if foreign else 1
                    queryid = (
                        5500551 + profile
                        if foreign <= 1
                        else 5500600 + foreign * 2 + profile
                    )
                    calls = 6000 * scale
                    cur.execute(
                        "INSERT INTO pg_stat_statements "
                        "(dbid, userid, queryid, query, calls, total_exec_time, "
                        "mean_exec_time, stddev_exec_time, rows, temp_blks_read, "
                        "temp_blks_written, shared_blks_hit, "
                        "shared_blks_read, wal_bytes) "
                        "VALUES (%s, %s, %s, %s, %s, %s, %s, "
                        "%s, %s, %s, %s, %s, %s, %s)",
                        (
                            foreign_dbid if foreign else dbid,
                            userid,
                            queryid,
                            "SELECT 'foreign' WHERE 1 NOT IN (SELECT NULL)"
                            if foreign
                            else "SELECT 'local' WHERE 1 NOT IN (SELECT NULL)",
                            calls,
                            9000000 * scale,
                            200 * scale if profile == 0 else 1,
                            10000 * scale,
                            calls * 20000 * scale if profile == 0 else calls,
                            200 * scale,
                            300 * scale,
                            0 if foreign else 100,
                            calls * 2000 * scale,
                            calls * 2000000 * scale,
                        ),
                    )
        cur.execute((ROOT / installer).read_text())
    return conn, installer, dbid, database, roles


@pytest.mark.parametrize("check_name", QUERY_CHECKS)
def test_query_findings_scope_database_before_ranking(
    query_workload: tuple[PgConnection, str, int, str, list[tuple[int, str]]],
    check_name: str,
) -> None:
    conn, installer, _, _, _ = query_workload
    with conn.cursor() as cur:
        cur.execute(
            "SELECT current_value FROM pgfirstaid_pg_stat_statements_checks() "
            "WHERE check_name = %s",
            (check_name,),
        )
        helper_evidence = [row[0] for row in cur.fetchall()]
    assert helper_evidence, check_name
    assert all(
        "'local'" in value and "'foreign'" not in value for value in helper_evidence
    )
    rows = [
        row for row in report_rows(conn, installer) if row["check_name"] == check_name
    ]
    assert rows, check_name
    assert all("'local'" in row["current_value"] for row in rows)


@pytest.mark.parametrize("check_name", QUERY_CHECKS)
def test_query_findings_distinguish_colliding_user_queryids(
    query_workload: tuple[PgConnection, str, int, str, list[tuple[int, str]]],
    check_name: str,
) -> None:
    conn, installer, dbid, database, roles = query_workload
    rows = [
        row for row in report_rows(conn, installer) if row["check_name"] == check_name
    ]
    for userid, role in roles:
        expected_context = (
            f"dbid: {dbid}, database: {database}, "
            f"userid: {userid}, role: {sql.Identifier(role).as_string(conn)}"
        )
        matches = [row for row in rows if expected_context in row["object_name"]]
        assert matches, (check_name, expected_context, rows)
        for row in matches:
            assert row["object_name"].startswith("queryid: ")
            assert json.dumps(row["object_name"]) in row["agent_prompt"]
    assert len({row["object_name"] for row in rows}) == len(rows)


def test_blocked_and_blocking_findings_keep_both_session_identities(
    context_database: tuple[PgConnection, str],
) -> None:
    conn, installer = context_database
    with conn.cursor() as cur:
        # Catalog shadows avoid creating live locks or cancelling another backend.
        cur.execute("CREATE TABLE pg_stat_activity (LIKE pg_catalog.pg_stat_activity)")
        cur.execute("CREATE TABLE pg_locks (LIKE pg_catalog.pg_locks)")
        cur.execute(
            "SELECT datname FROM pg_database "
            "WHERE datname <> current_database() LIMIT 1"
        )
        foreign_database = cur.fetchone()[0]
        role = f'Blocking "Role" {uuid4().hex[:8]}'
        cur.execute(sql.SQL("CREATE ROLE {} NOLOGIN").format(sql.Identifier(role)))
        cur.execute(
            "INSERT INTO pg_stat_activity "
            "(pid, datname, usename, backend_start, query_start, query, state) VALUES "
            "(55001, current_database(), current_user, "
            "'2026-01-01 01:02:03+00', now(), 'SELECT blocked', 'active'), "
            "(55002, %s, %s, '2026-01-02 04:05:06+00', now(), "
            "'SELECT blocking', 'active')",
            (foreign_database, role),
        )
        cur.execute(
            "INSERT INTO pg_locks (pid, transactionid, granted) VALUES "
            "(55001, '12345'::xid, false), (55002, '12345'::xid, true)"
        )
        cur.execute((ROOT / installer).read_text())
        cur.execute("SELECT quote_ident(current_database()), quote_ident(current_user)")
        database, user = cur.fetchone()
    rows = [
        row
        for row in report_rows(conn, installer)
        if row["check_name"] == "Current Blocked/Blocking Queries"
    ]
    assert len(rows) == 1
    row = rows[0]
    for side, evidence, db, username, pid, started in [
        ("Blocked", row["object_name"], database, user, "55001", "2026-01-01 01:02:03"),
        (
            "Blocking",
            row["current_value"],
            foreign_database,
            sql.Identifier(role).as_string(conn),
            "55002",
            "2026-01-02 04:05:06",
        ),
    ]:
        assert f"{side} PID: {pid}" in evidence
        assert f"database: {db}" in evidence
        assert f"role: {username}" in evidence
        assert f"backend_start: {started}" in evidence
        assert json.dumps(evidence) in row["agent_prompt"]


def test_idle_connection_prompt_keeps_its_actual_database_and_backend(
    context_database: tuple[PgConnection, str],
) -> None:
    conn, installer = context_database
    with conn.cursor() as cur:
        cur.execute("CREATE TABLE pg_stat_activity (LIKE pg_catalog.pg_stat_activity)")
        cur.execute(
            "SELECT datname, quote_ident(datname) FROM pg_database "
            "WHERE datname <> current_database() LIMIT 1"
        )
        database, quoted_database = cur.fetchone()
        cur.execute(
            "INSERT INTO pg_stat_activity "
            "(pid, datname, usename, backend_start, state_change, state) VALUES "
            "(55003, %s, 'Idle Role', '2026-01-03 04:05:06+00', "
            "now() - interval '2 hours', 'idle')",
            (database,),
        )
        cur.execute((ROOT / installer).read_text())
    rows = [
        row
        for row in report_rows(conn, installer)
        if row["check_name"] == "Idle Connections Over 1 Hour"
    ]
    assert len(rows) == 1
    row = rows[0]
    assert f"database: {quoted_database}" in row["object_name"]
    assert '"Idle Role"' in row["object_name"]
    assert "backend_start: 2026-01-03 04:05:06" in row["current_value"]
    assert json.dumps(row["object_name"]) in row["agent_prompt"]
    assert json.dumps(row["current_value"]) in row["agent_prompt"]
