from dataclasses import dataclass
import os


@dataclass(frozen=True)
class TestConfig:
    host: str
    port: int
    user: str
    password: str | None
    database: str
    sslmode: str | None
    active_conn_target: int
    active_conn_sleep_seconds: int
    wait_timeout_seconds: int

    @classmethod
    def from_env(cls) -> "TestConfig":
        return cls(
            host=os.getenv("PGHOST", "localhost"),
            port=int(os.getenv("PGPORT", "5432")),
            user=os.getenv("PGUSER", "postgres"),
            password=os.getenv("PGPASSWORD"),
            database=os.getenv("PGDATABASE", "postgres"),
            sslmode=os.getenv("PGSSLMODE"),
            active_conn_target=int(os.getenv("PGFA_TEST_ACTIVE_CONN_TARGET", "52")),
            active_conn_sleep_seconds=int(
                os.getenv("PGFA_TEST_ACTIVE_CONN_SLEEP_SECONDS", "20")
            ),
            wait_timeout_seconds=int(os.getenv("PGFA_TEST_WAIT_TIMEOUT_SECONDS", "45")),
        )
