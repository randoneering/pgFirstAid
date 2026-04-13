import pytest

from pgfirstaid_pytest import TestConfig


def test_from_env_requires_connection_variables(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    for name in ("PGHOST", "PGPORT", "PGUSER", "PGDATABASE", "PGPASSWORD"):
        monkeypatch.delenv(name, raising=False)

    with pytest.raises(
        ValueError, match="Missing required PostgreSQL environment variables"
    ):
        TestConfig.from_env()


def test_missing_env_vars_reports_unset_connection_variables(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("PGHOST", "db.example.test")
    monkeypatch.delenv("PGPORT", raising=False)
    monkeypatch.delenv("PGUSER", raising=False)
    monkeypatch.setenv("PGDATABASE", "appdb")

    assert TestConfig.missing_env_vars() == ("PGPORT", "PGUSER")


def test_from_env_reads_standard_pg_variables(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("PGHOST", "db.example.test")
    monkeypatch.setenv("PGPORT", "6543")
    monkeypatch.setenv("PGUSER", "pgfirstaid")
    monkeypatch.setenv("PGDATABASE", "appdb")
    monkeypatch.setenv("PGPASSWORD", "secret")
    monkeypatch.setenv("PGSSLMODE", "require")

    config = TestConfig.from_env()

    assert config.host == "db.example.test"
    assert config.port == 6543
    assert config.user == "pgfirstaid"
    assert config.password == "secret"
    assert config.database == "appdb"
    assert config.sslmode == "require"
