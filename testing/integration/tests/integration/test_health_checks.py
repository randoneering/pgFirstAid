from concurrent.futures import ThreadPoolExecutor, as_completed
import threading
import time

import psycopg
import pytest

from pgfirstaid_pytest import TestConfig as PgConfig
from pgfirstaid_pytest import connect, wait_for_sql_true


def _start_active_connection(
    config: PgConfig,
    connection_id: int,
    start_event: threading.Event,
    sleep_seconds: int,
) -> bool:
    app_name = f"pgfirstaid_pytest_conn_{connection_id}"
    try:
        with connect(
            config,
            autocommit=True,
            application_name=app_name,
        ) as conn:
            if not start_event.wait(timeout=15):
                return False
            with conn.cursor() as cur:
                cur.execute("SELECT pg_sleep(%s)", (sleep_seconds,))
            return True
    except psycopg.Error:
        return False


@pytest.mark.integration
def test_outdated_statistics_detected(
    db_conn: psycopg.Connection[tuple[object, ...]],
    test_schema: str,
    config: PgConfig,
) -> None:
    table_name = f"{test_schema}.outdated_stats_table"

    with db_conn.cursor() as cur:
        cur.execute(
            f"""
            CREATE TABLE {table_name} (
                id serial PRIMARY KEY,
                data text
            ) WITH (autovacuum_enabled = false)
            """
        )
        cur.execute(
            f"""
            INSERT INTO {table_name} (data)
            SELECT md5(g::text)
            FROM generate_series(1, 2000) g
            """
        )
        cur.execute(f"ANALYZE {table_name}")
        cur.execute(f"UPDATE {table_name} SET data = md5(data) WHERE id <= 800")
        cur.execute(f"DELETE FROM {table_name} WHERE id > 1200")

    stats_visible = wait_for_sql_true(
        db_conn,
        """
        SELECT EXISTS (
            SELECT 1
            FROM pg_stat_user_tables
            WHERE schemaname = %s
              AND relname = 'outdated_stats_table'
              AND n_mod_since_analyze > 150
        )
        """,
        (test_schema,),
        timeout_seconds=config.wait_timeout_seconds,
    )
    assert stats_visible, "Expected pg_stat_user_tables to show modified rows"

    with db_conn.cursor() as cur:
        cur.execute(
            """
            SELECT EXISTS (
                SELECT 1
                FROM pg_firstAid()
                WHERE check_name = 'Outdated Statistics'
                  AND object_name LIKE %s
            )
            """,
            ("%outdated_stats_table%",),
        )
        assert cur.fetchone()[0] is True

        cur.execute(
            """
            SELECT EXISTS (
                SELECT 1
                FROM v_pgfirstaid
                WHERE check_name = 'Outdated Statistics'
                  AND object_name LIKE %s
            )
            """,
            ("%outdated_stats_table%",),
        )
        assert cur.fetchone()[0] is True


@pytest.mark.integration
@pytest.mark.slow
def test_high_connection_count_detected(
    db_conn: psycopg.Connection[tuple[object, ...]],
    config: PgConfig,
) -> None:
    start_event = threading.Event()
    target = config.active_conn_target
    sleep_seconds = config.active_conn_sleep_seconds
    successes = 0

    with ThreadPoolExecutor(max_workers=target) as executor:
        futures = [
            executor.submit(
                _start_active_connection,
                config,
                connection_id,
                start_event,
                sleep_seconds,
            )
            for connection_id in range(1, target + 1)
        ]

        # Give threads enough time to establish connections before they start sleeping.
        time.sleep(2)
        start_event.set()

        active_seen = wait_for_sql_true(
            db_conn,
            """
            SELECT count(*) >= %s
            FROM pg_stat_activity
            WHERE application_name LIKE 'pgfirstaid_pytest_conn_%%'
              AND state = 'active'
            """,
            (target,),
            timeout_seconds=config.wait_timeout_seconds,
        )

        if not active_seen:
            for future in as_completed(futures):
                successes += 1 if future.result() else 0
            pytest.skip(
                "Could not establish enough active test sessions to cross the "
                "High Connection Count threshold"
            )

        with db_conn.cursor() as cur:
            cur.execute(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM pg_firstAid()
                    WHERE check_name = 'High Connection Count'
                )
                """
            )
            assert cur.fetchone()[0] is True

            cur.execute(
                """
                SELECT EXISTS (
                    SELECT 1
                    FROM v_pgfirstaid
                    WHERE check_name = 'High Connection Count'
                )
                """
            )
            assert cur.fetchone()[0] is True

        for future in as_completed(futures):
            successes += 1 if future.result() else 0

    assert successes > 0
