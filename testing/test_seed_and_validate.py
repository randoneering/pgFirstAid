import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from seed_and_validate import get_conn_params, patch_thresholds, PG_FIRSTAID_SQL, build_report


def _args(**kwargs):
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=None)
    parser.add_argument("--port", default=None)
    parser.add_argument("--user", default=None)
    parser.add_argument("--password", default=None)
    return parser.parse_args(
        [f"--{k}={v}" for k, v in kwargs.items()]
    )


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
