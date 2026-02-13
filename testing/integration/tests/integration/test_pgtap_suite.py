from __future__ import annotations

import os
from pathlib import Path
import re
import subprocess

import psycopg
import pytest

from pgfirstaid_pytest import TestConfig as PgConfig
from pgfirstaid_pytest import execute_sql_file


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[4]


def _pgtap_dir() -> Path:
    return _repo_root() / "testing" / "pgTAP"


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
    db_conn: psycopg.Connection[tuple[object, ...]],
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


def _extract_check_names_from_source(sql_text: str) -> set[str]:
    return set(
        re.findall(r"'([^']+)'\s+as\s+check_name", sql_text, flags=re.IGNORECASE)
    )


def _extract_check_names_from_pgtap(sql_text: str) -> set[str]:
    return set(re.findall(r"check_name\s*=\s*'([^']+)'", sql_text, flags=re.IGNORECASE))


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
@pytest.mark.parametrize("view_sql", _view_sql_files())
def test_view_variant_matches_function_check_names(
    db_conn: psycopg.Connection[tuple[object, ...]],
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
def test_view_parity_for_all_health_checks(
    db_conn: psycopg.Connection[tuple[object, ...]],
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
