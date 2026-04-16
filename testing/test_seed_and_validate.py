import argparse
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from seed_and_validate import get_conn_params


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
