from pathlib import Path
import sys
from typing import Iterator

import pytest
import psycopg2
from psycopg2.extensions import connection as PgConnection

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from pgfirstaid_pytest import TestConfig, connect, execute_sql_file


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[3]


def _setup_sql_path() -> Path:
    return _repo_root() / "testing" / "pgTAP" / "00_setup.sql"


def _teardown_sql_path() -> Path:
    return _repo_root() / "testing" / "pgTAP" / "99_teardown.sql"


def _pgfirstaid_sql_path() -> Path:
    return _repo_root() / "pgFirstAid.sql"


def _managed_view_sql_path() -> Path:
    return _repo_root() / "view_pgFirstAid_managed.sql"


@pytest.fixture(scope="session")
def config() -> TestConfig:
    missing = TestConfig.missing_env_vars()
    if missing:
        missing_list = ", ".join(missing)
        pytest.skip(
            "Missing required PostgreSQL environment variables: "
            f"{missing_list}. Set the standard PG* connection variables before "
            "running integration tests."
        )

    return TestConfig.from_env()


@pytest.fixture(scope="session")
def prepared_database(config: TestConfig) -> Iterator[None]:
    with connect(config, autocommit=True) as conn:
        execute_sql_file(conn, _setup_sql_path())
        execute_sql_file(conn, _pgfirstaid_sql_path())
        execute_sql_file(conn, _managed_view_sql_path())
    yield
    with connect(config, autocommit=True) as conn:
        execute_sql_file(conn, _teardown_sql_path())


@pytest.fixture
def db_conn(
    config: TestConfig,
    prepared_database: None,
) -> Iterator[PgConnection]:
    with connect(config, autocommit=True) as conn:
        yield conn


@pytest.fixture
def test_schema(db_conn: PgConnection) -> Iterator[str]:
    schema_name = "pgfirstaid_pytest"
    with db_conn.cursor() as cur:
        cur.execute(f"CREATE SCHEMA IF NOT EXISTS {schema_name}")
    yield schema_name
    with db_conn.cursor() as cur:
        cur.execute(f"DROP SCHEMA IF EXISTS {schema_name} CASCADE")
