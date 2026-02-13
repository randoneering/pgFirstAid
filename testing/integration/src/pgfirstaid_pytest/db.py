from pathlib import Path
import time
from typing import Any

import psycopg

from .config import TestConfig


def connect(
    config: TestConfig,
    *,
    autocommit: bool = True,
    application_name: str | None = None,
) -> psycopg.Connection[Any]:
    kwargs: dict[str, Any] = {
        "host": config.host,
        "port": config.port,
        "user": config.user,
        "dbname": config.database,
        "autocommit": autocommit,
    }
    if config.password is not None:
        kwargs["password"] = config.password
    if config.sslmode is not None:
        kwargs["sslmode"] = config.sslmode
    if application_name is not None:
        kwargs["application_name"] = application_name
    return psycopg.connect(**kwargs)


def execute_sql_file(conn: psycopg.Connection[Any], file_path: Path) -> None:
    sql_text = file_path.read_text(encoding="utf-8")
    with conn.cursor() as cur:
        cur.execute(sql_text)


def wait_for_sql_true(
    conn: psycopg.Connection[Any],
    sql: str,
    params: tuple[Any, ...] | None = None,
    *,
    timeout_seconds: int,
    interval_seconds: float = 0.5,
) -> bool:
    start = time.monotonic()
    with conn.cursor() as cur:
        while time.monotonic() - start < timeout_seconds:
            cur.execute(sql, params)
            row = cur.fetchone()
            if row and bool(row[0]):
                return True
            time.sleep(interval_seconds)
    return False
