from dataclasses import dataclass
import os


_REQUIRED_ENV_VARS = ("PGHOST", "PGPORT", "PGUSER", "PGDATABASE")


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
    def missing_env_vars(cls) -> tuple[str, ...]:
        return tuple(name for name in _REQUIRED_ENV_VARS if not os.getenv(name))

    @classmethod
    def from_env(cls) -> "TestConfig":
        missing = cls.missing_env_vars()
        if missing:
            missing_list = ", ".join(missing)
            raise ValueError(
                "Missing required PostgreSQL environment variables: "
                f"{missing_list}. Set the standard PG* connection variables before "
                "running integration tests."
            )

        return cls(
            host=os.environ["PGHOST"],
            port=int(os.environ["PGPORT"]),
            user=os.environ["PGUSER"],
            password=os.getenv("PGPASSWORD"),
            database=os.environ["PGDATABASE"],
            sslmode=os.getenv("PGSSLMODE"),
            active_conn_target=int(os.getenv("PGFA_TEST_ACTIVE_CONN_TARGET", "52")),
            active_conn_sleep_seconds=int(
                os.getenv("PGFA_TEST_ACTIVE_CONN_SLEEP_SECONDS", "20")
            ),
            wait_timeout_seconds=int(os.getenv("PGFA_TEST_WAIT_TIMEOUT_SECONDS", "45")),
        )
