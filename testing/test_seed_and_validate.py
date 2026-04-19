import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import psycopg

from seed_and_validate import (
    _ALWAYS_FIRE,
    _DEFAULT_ONLY_CHECKS,
    _MANAGED_UNSUPPORTED_CHECKS,
    _NEVER_SEEDED,
    _PSS_MISSING_CHECK,
    _PSS_WORKLOAD_CHECKS,
    _REPLICATION_CHECKS,
    _SESSION_CHECKS,
    _STATIC_CHECKS,
    PG_FIRSTAID_MANAGED_SQL,
    PG_FIRSTAID_SQL,
    TEST_DB,
    build_report,
    classify_default_setting_checks,
    classify_pss_state,
    get_conn_params,
    seed_low_usage_index_scans,
    wait_for_index_scan_count,
    patch_thresholds,
    run_psql_file,
    try_create_replication_slot,
)


def _args(**kwargs):
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=None)
    parser.add_argument("--port", default=None)
    parser.add_argument("--user", default=None)
    parser.add_argument("--password", default=None)
    return parser.parse_args([f"--{k}={v}" for k, v in kwargs.items()])


def test_get_conn_params_defaults(monkeypatch):
    monkeypatch.delenv("PGHOST", raising=False)
    monkeypatch.delenv("PGPORT", raising=False)
    monkeypatch.delenv("PGUSER", raising=False)
    monkeypatch.delenv("PGPASSWORD", raising=False)
    params = get_conn_params(_args())
    assert params["host"] == "localhost"
    assert params["port"] == 5432
    assert params["user"] == "postgres"
    assert params["password"] == ""
    assert params["dbname"] == "postgres"


def test_get_conn_params_env(monkeypatch):
    monkeypatch.setenv("PGHOST", "db.example.com")
    monkeypatch.setenv("PGPORT", "5433")
    monkeypatch.setenv("PGUSER", "admin")
    monkeypatch.setenv("PGPASSWORD", "secret")
    params = get_conn_params(_args())
    assert params["host"] == "db.example.com"
    assert params["port"] == 5433
    assert params["user"] == "admin"
    assert params["password"] == "secret"


def test_get_conn_params_cli_overrides_env(monkeypatch):
    monkeypatch.setenv("PGHOST", "env-host")
    monkeypatch.setenv("PGPORT", "9999")
    params = get_conn_params(_args(host="cli-host", port="5432"))
    assert params["host"] == "cli-host"
    assert params["port"] == 5432


def test_patch_unused_large_index():
    sql = "pg_relation_size(psi.indexrelid) > 104857600;"
    result = patch_thresholds(sql)
    assert "> 8192" in result
    assert "104857600" not in result


def test_patch_tables_over_100gb():
    sql = "pg_relation_size(...) > 107374182400"
    result = patch_thresholds(sql)
    assert "> 1048576" in result
    assert "107374182400" not in result


def test_patch_tables_50gb_to_100gb():
    sql = "pg_relation_size(...) between 53687091200 and 107374182400"
    result = patch_thresholds(sql)
    assert "between 524288 and 1048576" in result
    assert "53687091200" not in result


def test_patch_does_not_modify_file(tmp_path):
    """patch_thresholds must not write to disk."""
    original = PG_FIRSTAID_SQL.read_text()
    patch_thresholds(original)
    assert PG_FIRSTAID_SQL.read_text() == original


def test_build_report_all_pass():
    fired = {"Missing Primary Key", "Duplicate Index", "Database Size"}
    expected = {"Missing Primary Key", "Duplicate Index", "Database Size"}
    skipped = set()
    passed, failed, skip_list = build_report(fired, expected, skipped)
    assert "Missing Primary Key" in passed
    assert "Duplicate Index" in passed
    assert failed == []
    assert skip_list == []


def test_build_report_missing_check():
    fired = {"Database Size"}
    expected = {"Database Size", "Missing Primary Key"}
    skipped = set()
    passed, failed, skip_list = build_report(fired, expected, skipped)
    assert "Missing Primary Key" in failed
    assert "Database Size" in passed


def test_build_report_skipped_not_in_failed():
    fired = set()
    expected = {"Inactive Replication Slots", "Database Size"}
    skipped = {"Inactive Replication Slots"}
    passed, failed, skip_list = build_report(fired, expected, skipped)
    assert "Inactive Replication Slots" in skip_list
    assert "Inactive Replication Slots" not in failed
    assert "Database Size" in failed


def test_run_psql_file_enables_on_error_stop(monkeypatch, tmp_path):
    sql_file = tmp_path / "seed.sql"
    sql_file.write_text("SELECT 1;\n")
    calls: list[list[str]] = []

    def fake_run(cmd, **kwargs):
        calls.append(cmd)
        return subprocess.CompletedProcess(cmd, 0, stdout="", stderr="")

    monkeypatch.setattr(subprocess, "run", fake_run)

    success = run_psql_file(
        {"host": "localhost", "port": 5432, "user": "postgres", "password": "secret"},
        sql_file,
    )

    assert success is True
    assert calls == [
        [
            "psql",
            "--host=localhost",
            "--port=5432",
            "--username=postgres",
            f"--dbname={TEST_DB}",
            f"--file={sql_file}",
            "--no-psqlrc",
            "-v",
            "ON_ERROR_STOP=1",
        ]
    ]


def test_try_create_replication_slot_skips_missing_output_plugin(capsys):
    class FakeConn:
        def execute(self, _query):
            raise psycopg.errors.UndefinedObject(
                'logical decoding output plugin "test_decoding" does not exist'
            )

    created = try_create_replication_slot(FakeConn())

    assert created is False
    assert "test_decoding unavailable" in capsys.readouterr().out


def test_expected_check_groups_cover_all_defined_checks():
    standard_configured_checks = (
        set(_ALWAYS_FIRE)
        | set(_DEFAULT_ONLY_CHECKS)
        | set(_STATIC_CHECKS)
        | set(_SESSION_CHECKS)
        | set(_PSS_WORKLOAD_CHECKS)
        | set(_REPLICATION_CHECKS)
        | set(_NEVER_SEEDED)
        | {_PSS_MISSING_CHECK}
    )

    def extract_checks(path: Path) -> set[str]:
        return set(re.findall(r"'([^']+)'\s+as check_name", path.read_text()))

    standard_checks = extract_checks(PG_FIRSTAID_SQL)
    managed_checks = extract_checks(PG_FIRSTAID_MANAGED_SQL)
    managed_configured_checks = standard_configured_checks - set(
        _MANAGED_UNSUPPORTED_CHECKS
    )

    assert standard_configured_checks == standard_checks
    assert managed_configured_checks == managed_checks


def test_classify_default_setting_checks_marks_only_matching_defaults_expected():
    class FakeResult:
        def __init__(self, value):
            self._value = value

        def fetchone(self):
            return (self._value,)

    class FakeConn:
        def __init__(self):
            self._responses = {
                "shared_buffers": True,
                "work_mem": False,
            }

        def execute(self, _query, params):
            return FakeResult(self._responses[params[0]])

    expected, skipped = classify_default_setting_checks(FakeConn())

    assert expected == {"shared_buffers At Default"}
    assert skipped == {"work_mem At Default"}


def test_classify_pss_state_marks_installed_but_unqueryable_as_not_seeded():
    class FakeResult:
        def __init__(self, value):
            self._value = value

        def fetchone(self):
            return (self._value,)

    class FakeConn:
        def execute(self, query, params=None):
            if "FROM pg_extension" in query:
                return FakeResult(1)
            if "FROM pg_stat_statements" in query:
                raise psycopg.errors.ObjectNotInPrerequisiteState(
                    'pg_stat_statements must be loaded via "shared_preload_libraries"'
                )
            raise AssertionError(query)

    installed, seeded = classify_pss_state(FakeConn(), psql_seed_succeeded=False)

    assert installed is True
    assert seeded is False


def test_wait_for_index_scan_count_polls_until_scans_visible(monkeypatch):
    class FakeResult:
        def __init__(self, value):
            self._value = value

        def fetchone(self):
            return (self._value,)

    class FakeConn:
        def __init__(self):
            self._values = iter([0, 0, 5])

        def execute(self, _query, _params):
            return FakeResult(next(self._values))

    sleep_calls: list[float] = []
    monkeypatch.setattr("seed_and_validate.time.sleep", sleep_calls.append)

    visible = wait_for_index_scan_count(
        FakeConn(), "pgfirstaid_seed_low_usage_idx", min_scans=1, timeout=3
    )

    assert visible is True
    assert sleep_calls == [1.0, 1.0]


def test_low_usage_seed_uses_top_level_selects_not_do_block():
    seed_sql = (
        Path(__file__).parent / "healthcheck_seed" / "01_seed_static_checks.sql"
    ).read_text()

    low_usage_section = seed_sql.split("-- LOW: Index With Very Low Usage", 1)[1]
    low_usage_section = low_usage_section.split(
        "-- ============================================================\n-- Lock target",
        1,
    )[0]

    assert "DO $$" not in low_usage_section
    assert (
        low_usage_section.count("SELECT id FROM pgfirstaid_seed.low_usage_idx_table")
        >= 5
    )


def test_seed_low_usage_index_scans_runs_five_lookups():
    class FakeConn:
        def __init__(self):
            self.calls = []

        def execute(self, query, params):
            self.calls.append((query, params))

    conn = FakeConn()

    seed_low_usage_index_scans(conn)

    assert len(conn.calls) == 5
    assert all(
        "low_usage_idx_table" in query and "search_key = md5(%s::text)" in query
        for query, _params in conn.calls
    )
    assert [params for _query, params in conn.calls] == [(str(i),) for i in range(1, 6)]
