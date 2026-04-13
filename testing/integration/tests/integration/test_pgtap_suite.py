from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess

from psycopg2.extensions import connection as PgConnection
import pytest

from pgfirstaid_pytest import TestConfig as PgConfig
from pgfirstaid_pytest import execute_sql_file


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def _pgtap_dir() -> Path:
    return _repo_root() / "testing" / "pgTAP"


def _pgtap_setup_sql() -> Path:
    return _pgtap_dir() / "00_setup.sql"


def _pgtap_teardown_sql() -> Path:
    return _pgtap_dir() / "99_teardown.sql"


def _pgtap_test_files() -> list[Path]:
    return sorted(_pgtap_dir().glob("0[1-9]_*.sql"))


def _run_pgtap_file(config: PgConfig, file_path: Path) -> tuple[int, str]:
    command = [
        "psql",
        "-X",
        "-v",
        "ON_ERROR_STOP=1",
        "-h",
        config.host,
        "-p",
        str(config.port),
        "-U",
        config.user,
        "-d",
        config.database,
        "-f",
        str(file_path),
    ]

    env = os.environ.copy()
    if config.password is not None:
        env["PGPASSWORD"] = config.password
    if config.sslmode is not None:
        env["PGSSLMODE"] = config.sslmode

    result = subprocess.run(
        command,
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    output = f"{result.stdout}\n{result.stderr}".strip()
    return result.returncode, output


def _tap_failures(output: str) -> list[str]:
    return [line for line in output.splitlines() if re.match(r"^\s*not ok\s+\d+", line)]


@pytest.mark.integration
@pytest.mark.slow
@pytest.mark.parametrize("pgtap_file", _pgtap_test_files())
def test_pgtap_sql_file_passes(
    config: PgConfig,
    prepared_database: None,
    db_conn: PgConnection,
    pgtap_file: Path,
) -> None:
    _ = prepared_database
    execute_sql_file(db_conn, _default_view_sql())
    return_code, output = _run_pgtap_file(config, pgtap_file)
    assert return_code == 0, (
        f"pgTAP file failed: {pgtap_file.name}\n"
        f"psql exited with {return_code}\n\n{output}"
    )

    failures = _tap_failures(output)
    assert not failures, (
        f"pgTAP assertions failed in {pgtap_file.name}:\n"
        + "\n".join(failures)
        + f"\n\nFull output:\n{output}"
    )


@pytest.mark.integration
def test_session_teardown_handles_installed_objects(db_conn: PgConnection) -> None:
    # The shared teardown runs at session end, after pg_firstAid() and v_pgfirstaid
    # have been installed for the integration suite.
    execute_sql_file(db_conn, _pgtap_setup_sql())
    execute_sql_file(db_conn, _repo_root() / "pgFirstAid.sql")
    execute_sql_file(db_conn, _default_view_sql())

    try:
        execute_sql_file(db_conn, _pgtap_teardown_sql())
    finally:
        execute_sql_file(db_conn, _pgtap_setup_sql())
        execute_sql_file(db_conn, _repo_root() / "pgFirstAid.sql")
        execute_sql_file(db_conn, _default_view_sql())


def _extract_check_names_from_source(sql_text: str) -> set[str]:
    return set(
        re.findall(r"'([^']+)'\s+as\s+check_name", sql_text, flags=re.IGNORECASE)
    )


def _extract_check_names_from_pgtap(sql_text: str) -> set[str]:
    return set(re.findall(r"check_name\s*=\s*'([^']+)'", sql_text, flags=re.IGNORECASE))


def _extract_function_body(sql_text: str, func_name: str) -> str | None:
    # Match the dollar-quoted body of a named PL/pgSQL function.
    # Use [$] character classes for literal $ because \$ loses the backslash
    # in Python raw strings when $ is not a recognised escape sequence.
    match = re.search(
        rf"function\s+{re.escape(func_name)}\b[^$]*[$][$](.*?)[$][$]",
        sql_text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if match is None:
        return None
    # Normalise whitespace so trivial formatting differences don't cause false diffs.
    return "\n".join(line.strip() for line in match.group(1).strip().splitlines())


def _view_sql_files() -> list[Path]:
    root = _repo_root()
    all_views = [root / "view_pgFirstAid.sql", root / "view_pgFirstAid_managed.sql"]
    mode = os.getenv("PGFA_TEST_VIEW_MODE", "both").strip().lower()
    if mode == "managed":
        return [root / "view_pgFirstAid_managed.sql"]
    if mode in {"self_hosted", "self-hosted"}:
        return [root / "view_pgFirstAid.sql"]
    return all_views


def _default_view_sql() -> Path:
    root = _repo_root()
    mode = os.getenv("PGFA_TEST_VIEW_MODE", "both").strip().lower()
    if mode == "managed":
        return root / "view_pgFirstAid_managed.sql"
    return root / "view_pgFirstAid.sql"


@pytest.mark.integration
def test_every_health_check_has_pgtap_coverage() -> None:
    source_sql = (_repo_root() / "pgFirstAid.sql").read_text(encoding="utf-8")
    all_checks = _extract_check_names_from_source(source_sql)

    pgtap_checks: set[str] = set()
    for test_file in _pgtap_test_files():
        pgtap_checks.update(
            _extract_check_names_from_pgtap(test_file.read_text(encoding="utf-8"))
        )

    missing = sorted(all_checks - pgtap_checks)
    assert not missing, "Missing pgTAP coverage for health checks: " + ", ".join(
        missing
    )


@pytest.mark.integration
def test_both_view_sql_files_cover_all_health_checks() -> None:
    source_sql = (_repo_root() / "pgFirstAid.sql").read_text(encoding="utf-8")
    expected_checks = _extract_check_names_from_source(source_sql)

    for view_file in _view_sql_files():
        view_sql = view_file.read_text(encoding="utf-8")
        view_checks = _extract_check_names_from_source(view_sql)
        missing = sorted(expected_checks - view_checks)
        assert not missing, (
            f"Missing check_name coverage in {view_file.name}: " + ", ".join(missing)
        )


@pytest.mark.integration
def test_checkpoint_stats_helper_body_matches_across_install_scripts() -> None:
    # _pg_firstaid_checkpoint_stats() is duplicated in all three install scripts so
    # they each remain standalone.  This test catches accidental divergence.
    root = _repo_root()
    scripts = [
        root / "pgFirstAid.sql",
        root / "view_pgFirstAid.sql",
        root / "view_pgFirstAid_managed.sql",
    ]

    bodies: dict[str, str] = {}
    for script in scripts:
        body = _extract_function_body(
            script.read_text(encoding="utf-8"),
            "_pg_firstaid_checkpoint_stats",
        )
        assert body is not None, (
            f"_pg_firstaid_checkpoint_stats() not found in {script.name} — "
            "was it renamed or removed?"
        )
        bodies[script.name] = body

    reference_name = scripts[0].name
    for script in scripts[1:]:
        assert bodies[script.name] == bodies[reference_name], (
            f"_pg_firstaid_checkpoint_stats() in {script.name} differs from "
            f"{reference_name} — keep these identical so the checkpoint stats "
            "check produces consistent results regardless of install path."
        )


@pytest.mark.integration
@pytest.mark.parametrize("view_sql", _view_sql_files())
def test_view_variant_matches_function_check_names(
    db_conn: PgConnection,
    view_sql: Path,
) -> None:
    execute_sql_file(db_conn, view_sql)

    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT check_name FROM pg_firstAid()
            EXCEPT
            SELECT check_name FROM v_pgfirstaid
            """
        )
        missing_in_view = sorted(str(row[0]) for row in cur.fetchall())

        cur.execute(
            """
            SELECT check_name FROM v_pgfirstaid
            EXCEPT
            SELECT check_name FROM pg_firstAid()
            """
        )
        extra_in_view = sorted(str(row[0]) for row in cur.fetchall())

    assert not missing_in_view, (
        f"{view_sql.name} missing check_name entries from pg_firstAid(): "
        + ", ".join(missing_in_view)
    )
    assert not extra_in_view, (
        f"{view_sql.name} has extra check_name entries not in pg_firstAid(): "
        + ", ".join(extra_in_view)
    )

    execute_sql_file(db_conn, _default_view_sql())


@pytest.mark.integration
@pytest.mark.parametrize("view_sql", _view_sql_files())
def test_view_variant_installs_standalone(
    db_conn: PgConnection,
    view_sql: Path,
) -> None:
    execute_sql_file(db_conn, _pgtap_teardown_sql())
    execute_sql_file(db_conn, _pgtap_setup_sql())

    try:
        execute_sql_file(db_conn, view_sql)

        with db_conn.cursor() as cur:
            cur.execute("SELECT count(*) >= 0 FROM v_pgfirstaid")
            assert cur.fetchone()[0] is True
    finally:
        execute_sql_file(db_conn, _pgtap_setup_sql())
        execute_sql_file(db_conn, _repo_root() / "pgFirstAid.sql")
        execute_sql_file(db_conn, _default_view_sql())


@pytest.mark.integration
def test_managed_view_duplicate_index_check_ignores_partial_indexes(
    db_conn: PgConnection,
    test_schema: str,
) -> None:
    table_name = f"{test_schema}.partial_index_table"
    managed_view = _repo_root() / "view_pgFirstAid_managed.sql"

    with db_conn.cursor() as cur:
        cur.execute(
            f"""
            CREATE TABLE {table_name} (
                id serial PRIMARY KEY,
                value integer NOT NULL
            )
            """
        )
        cur.execute(
            f"CREATE INDEX partial_idx_a ON {table_name} (value) WHERE value > 0"
        )
        cur.execute(
            f"CREATE INDEX partial_idx_b ON {table_name} (value) WHERE value > 10"
        )

    execute_sql_file(db_conn, managed_view)

    try:
        with db_conn.cursor() as cur:
            cur.execute(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM v_pgfirstaid
                    WHERE check_name = 'Duplicate Index'
                      AND object_name LIKE %s
                )
                """,
                (f"{test_schema}.partial_index_table:%",),
            )
            assert cur.fetchone()[0] is False
    finally:
        execute_sql_file(db_conn, _default_view_sql())


@pytest.mark.integration
def test_view_parity_for_all_health_checks(
    db_conn: PgConnection,
) -> None:
    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT check_name FROM pg_firstAid()
            EXCEPT
            SELECT check_name FROM v_pgfirstaid
            """
        )
        missing_in_view = sorted(str(row[0]) for row in cur.fetchall())

        cur.execute(
            """
            SELECT check_name FROM v_pgfirstaid
            EXCEPT
            SELECT check_name FROM pg_firstAid()
            """
        )
        extra_in_view = sorted(str(row[0]) for row in cur.fetchall())

    assert not missing_in_view, (
        "These checks exist in pg_firstAid() but are missing in v_pgfirstaid: "
        + ", ".join(missing_in_view)
    )
    assert not extra_in_view, (
        "These checks exist in v_pgfirstaid but are missing in pg_firstAid(): "
        + ", ".join(extra_in_view)
    )


@pytest.mark.integration
def test_view_matches_function_row_order(
    db_conn: PgConnection,
) -> None:
    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT severity, category, check_name
            FROM pg_firstAid()
            ORDER BY severity, category, check_name
            """
        )
        function_rows = [tuple(str(value) for value in row) for row in cur.fetchall()]

        cur.execute(
            """
            SELECT severity, category, check_name
            FROM v_pgfirstaid
            ORDER BY severity, category, check_name
            """
        )
        view_rows = [tuple(str(value) for value in row) for row in cur.fetchall()]

    assert function_rows == view_rows


@pytest.mark.integration
def test_wraparound_risk_current_value_is_human_readable(
    db_conn: PgConnection,
) -> None:
    expected_pattern = re.compile(
        r"^[^:]+: XID age [\d,]+ \([\d.]+% of wraparound window, ~[\d,]+ remaining\)$"
    )

    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT current_value
            FROM pg_firstAid()
            WHERE check_name = 'Transaction ID Wraparound Risk'
            """
        )
        function_values = [str(row[0]) for row in cur.fetchall()]

        cur.execute(
            """
            SELECT current_value
            FROM v_pgfirstaid
            WHERE check_name = 'Transaction ID Wraparound Risk'
            """
        )
        view_values = [str(row[0]) for row in cur.fetchall()]

    assert function_values, "Expected wraparound risk rows from pg_firstAid()"
    assert view_values, "Expected wraparound risk rows from v_pgfirstaid"
    assert all(expected_pattern.match(value) for value in function_values), (
        function_values
    )
    assert all(expected_pattern.match(value) for value in view_values), view_values


@pytest.mark.integration
def test_checkpoint_stats_guidance_matches_server_version(
    db_conn: PgConnection,
) -> None:
    with db_conn.cursor() as cur:
        cur.execute("SELECT current_setting('server_version_num')::int")
        server_version_num = cur.fetchone()[0]

        cur.execute(
            """
            SELECT recommended_action
            FROM pg_firstAid()
            WHERE check_name = 'Checkpoint Stats'
            """
        )
        function_action = str(cur.fetchone()[0])

        cur.execute(
            """
            SELECT recommended_action
            FROM v_pgfirstaid
            WHERE check_name = 'Checkpoint Stats'
            """
        )
        view_action = str(cur.fetchone()[0])

    expected_reset = (
        "pg_stat_reset_shared('checkpointer')"
        if server_version_num >= 170000
        else "pg_stat_reset_shared('bgwriter')"
    )

    assert expected_reset in function_action
    assert expected_reset in view_action
