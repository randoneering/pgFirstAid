from __future__ import annotations

import importlib.util
import os
import subprocess
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any
from uuid import uuid4

import psycopg2
import pytest
from psycopg2 import sql
from psycopg2.extensions import TRANSACTION_STATUS_IDLE, TRANSACTION_STATUS_INTRANS
from psycopg2.extensions import connection as PgConnection

ROOT = Path(__file__).resolve().parents[1]
CANONICAL = ROOT / "pgFirstAid.sql"
COLUMNS = (
    "severity",
    "category",
    "check_name",
    "object_name",
    "issue_description",
    "current_value",
    "recommended_action",
    "documentation_link",
)
HELPER_ARGS = ", ".join(["text"] * 8)


@dataclass
class Database:
    conn: PgConnection
    schema: str
    owner: str
    reader: str
    delegate: str
    outsider: str


@pytest.fixture
def database() -> Iterator[Database]:
    dsn = os.getenv("PGFA_CI_INSTALL_TEST_DSN")
    if not dsn:
        pytest.skip("Set PGFA_CI_INSTALL_TEST_DSN to a disposable PostgreSQL database")
    conn = psycopg2.connect(dsn)
    token = uuid4().hex[:12]
    db = Database(
        conn,
        f'CI Tests. "{token}"',
        f'CI Owner. "{token}"',
        f'CI Reader. "{token}"',
        f'CI Delegate. "{token}"',
        f'CI Outsider. "{token}"',
    )
    try:
        with conn.cursor() as cur:
            cur.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(db.schema)))
            for role in (db.owner, db.reader, db.delegate, db.outsider):
                cur.execute(sql.SQL("CREATE ROLE {}").format(sql.Identifier(role)))
                cur.execute(
                    sql.SQL("GRANT USAGE ON SCHEMA {} TO {}").format(
                        sql.Identifier(db.schema), sql.Identifier(role)
                    )
                )
            cur.execute(
                sql.SQL("SET LOCAL search_path TO {}, public").format(
                    sql.Identifier(db.schema)
                )
            )
        yield db
    finally:
        conn.rollback()
        conn.close()


def install(
    conn: PgConnection,
    sql_path: Path = CANONICAL,
    *,
    allow_legacy_upgrade: bool = False,
) -> None:
    from ci_install import install_pgfirstaid

    install_pgfirstaid(conn, sql_path, allow_legacy_upgrade=allow_legacy_upgrade)


def scalar(conn: PgConnection, query: str, params: tuple[Any, ...] = ()) -> Any:
    with conn.cursor() as cur:
        cur.execute(query, params)
        return cur.fetchone()[0]


def acl(conn: PgConnection, name: str = "pg_firstaid()") -> list[tuple[Any, ...]]:
    with conn.cursor() as cur:
        cur.execute(
            "SELECT a.grantor, a.grantee, a.privilege_type, a.is_grantable "
            "FROM pg_proc p CROSS JOIN LATERAL "
            "aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a "
            "WHERE p.oid = %s::regprocedure ORDER BY 1, 2, 3, 4",
            (name,),
        )
        return cur.fetchall()


def definition(conn: PgConnection) -> str:
    return scalar(conn, "SELECT pg_get_functiondef('pg_firstaid()'::regprocedure)")


def scoped_signature(database: Database, signature: str) -> str:
    return f"{sql.Identifier(database.schema).as_string(database.conn)}.{signature}"


def legacy(db: Database, *, public: bool = False) -> None:
    with db.conn.cursor() as cur:
        columns = sql.SQL(", ").join(
            sql.SQL("{} text").format(sql.Identifier(name)) for name in COLUMNS
        )
        cur.execute(
            sql.SQL(
                "CREATE FUNCTION pg_firstaid() RETURNS TABLE ({}) "
                "LANGUAGE sql AS 'SELECT NULL::text, NULL::text, NULL::text, "
                "NULL::text, NULL::text, NULL::text, NULL::text, "
                "NULL::text WHERE false'"
            ).format(columns)
        )
        cur.execute(
            sql.SQL("ALTER FUNCTION pg_firstaid() OWNER TO {}").format(
                sql.Identifier(db.owner)
            )
        )
        cur.execute("COMMENT ON FUNCTION pg_firstaid() IS 'CI legacy comment'")
        if not public:
            cur.execute("REVOKE EXECUTE ON FUNCTION pg_firstaid() FROM PUBLIC")
        cur.execute("SELECT current_user")
        original = cur.fetchone()[0]
        cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(db.owner)))
        cur.execute(
            sql.SQL(
                "GRANT EXECUTE ON FUNCTION pg_firstaid() TO {} WITH GRANT OPTION"
            ).format(sql.Identifier(db.reader))
        )
        cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(db.reader)))
        cur.execute(
            sql.SQL("GRANT EXECUTE ON FUNCTION pg_firstaid() TO {}").format(
                sql.Identifier(db.delegate)
            )
        )
        cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(original)))


def test_normal_installer_upgrades_legacy_in_same_file(database: Database) -> None:
    legacy(database)
    old_acl = acl(database.conn)
    with database.conn.cursor() as cur:
        cur.execute(CANONICAL.read_text())
    assert "agent_prompt" in definition(database.conn)
    assert acl(database.conn) == old_acl


@pytest.mark.parametrize("public", [False, True])
def test_upgrade_preserves_owner_acl_grantors_and_comment(
    database: Database, public: bool
) -> None:
    legacy(database, public=public)
    before = acl(database.conn)
    install(database.conn, allow_legacy_upgrade=True)
    assert acl(database.conn) == before
    assert (
        scalar(
            database.conn,
            "SELECT pg_get_userbyid(proowner) FROM pg_proc "
            "WHERE oid = 'pg_firstaid()'::regprocedure",
        )
        == database.owner
    )
    assert (
        scalar(
            database.conn,
            "SELECT obj_description('pg_firstaid()'::regprocedure, 'pg_proc')",
        )
        == "CI legacy comment"
    )
    assert scalar(
        database.conn,
        "SELECT proargnames FROM pg_proc WHERE oid = 'pg_firstaid()'::regprocedure",
    ) == [*COLUMNS, "agent_prompt"]
    helper = f"pgfirstaid_agent_prompt({HELPER_ARGS})"
    for role in (database.owner, database.reader, database.delegate):
        assert scalar(
            database.conn,
            "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
            (role, helper),
        )
    assert (
        scalar(
            database.conn,
            "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
            (database.outsider, helper),
        )
        is public
    )
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(database.reader))
        )
        cur.execute(
            "SELECT pgfirstaid_agent_prompt('LOW', 'test', 'test', 'test', "
            "NULL, NULL, NULL, NULL)"
        )
        assert "read-only" in cur.fetchone()[0].lower()
        cur.execute("RESET ROLE")


def test_dependency_refusal_leaves_legacy_and_acl(database: Database) -> None:
    legacy(database)
    before = definition(database.conn), acl(database.conn)
    with database.conn.cursor() as cur:
        cur.execute("CREATE VIEW legacy_consumer AS SELECT * FROM pg_firstaid()")
    with pytest.raises(psycopg2.errors.DependentObjectsStillExist):
        install(database.conn, allow_legacy_upgrade=True)
    assert (definition(database.conn), acl(database.conn)) == before
    assert scalar(database.conn, "SELECT count(*) FROM legacy_consumer") == 0


def test_bad_install_rolls_back_legacy_and_new_helpers(
    database: Database, tmp_path: Path
) -> None:
    legacy(database)
    before = definition(database.conn), acl(database.conn)
    broken = tmp_path / "broken.sql"
    broken.write_text(CANONICAL.read_text() + "\nSELECT ci_install_missing_symbol;\n")
    with pytest.raises(psycopg2.errors.UndefinedColumn):
        install(database.conn, broken, allow_legacy_upgrade=True)
    assert (definition(database.conn), acl(database.conn)) == before
    assert (
        scalar(
            database.conn,
            "SELECT to_regprocedure(%s)",
            (scoped_signature(database, f"pgfirstaid_agent_prompt({HELPER_ARGS})"),),
        )
        is None
    )


def test_legacy_requires_explicit_opt_in(database: Database) -> None:
    legacy(database)
    before = definition(database.conn), acl(database.conn)
    with pytest.raises(RuntimeError, match="allow.legacy.upgrade"):
        install(database.conn)
    assert (definition(database.conn), acl(database.conn)) == before


def test_fresh_install_and_reinstall_keep_identity(database: Database) -> None:
    install(database.conn)
    oid = scalar(database.conn, "SELECT 'pg_firstaid()'::regprocedure::oid")
    install(database.conn)
    assert scalar(database.conn, "SELECT 'pg_firstaid()'::regprocedure::oid") == oid
    assert "agent_prompt" in definition(database.conn)


@pytest.mark.parametrize(
    "change",
    [
        "ALTER FUNCTION pg_firstaid() SECURITY DEFINER",
        "ALTER FUNCTION pg_firstaid() SET search_path TO public",
        "ALTER FUNCTION pg_firstaid() IMMUTABLE",
        "ALTER FUNCTION pg_firstaid() STRICT",
    ],
)
def test_unsupported_metadata_refuses_before_drop(
    database: Database, change: str
) -> None:
    legacy(database)
    with database.conn.cursor() as cur:
        cur.execute(change)
    before = definition(database.conn), acl(database.conn)
    with pytest.raises(RuntimeError, match="[Mm]anual"):
        install(database.conn, allow_legacy_upgrade=True)
    assert (definition(database.conn), acl(database.conn)) == before


@pytest.mark.parametrize("allow", [False, True])
@pytest.mark.parametrize("shape", ["single", "wrong_type", "wrong_name"])
def test_unknown_shape_is_never_dropped(
    database: Database, allow: bool, shape: str
) -> None:
    names = ["surprise"] if shape == "single" else list(COLUMNS)
    if shape == "wrong_name":
        names[-1] = "unexpected"
    types = ["text"] * len(names)
    if shape == "wrong_type":
        types[-1] = "integer"
    columns = sql.SQL(", ").join(
        sql.SQL("{} {}").format(sql.Identifier(name), sql.SQL(kind))
        for name, kind in zip(names, types, strict=True)
    )
    values = sql.SQL(", ").join(sql.SQL("NULL::{}").format(sql.SQL(t)) for t in types)
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL(
                "CREATE FUNCTION pg_firstaid() RETURNS TABLE ({}) LANGUAGE sql AS {}"
            ).format(
                columns, sql.Literal(sql.SQL("SELECT {}").format(values).as_string(cur))
            )
        )
    before = definition(database.conn)
    with pytest.raises(RuntimeError, match="[Mm]anual"):
        install(database.conn, allow_legacy_upgrade=allow)
    assert definition(database.conn) == before


def test_existing_helper_acl_is_preserved_with_legacy_callers(
    database: Database,
) -> None:
    install(database.conn)
    helper = f"pgfirstaid_agent_prompt({HELPER_ARGS})"
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL("REVOKE EXECUTE ON FUNCTION {} FROM PUBLIC").format(sql.SQL(helper))
        )
    before = acl(database.conn, helper)
    # Keep the helper's existing policy while substituting the legacy fixture.
    with database.conn.cursor() as cur:
        cur.execute("DROP FUNCTION pg_firstaid() RESTRICT")
    legacy(database)
    install(database.conn, allow_legacy_upgrade=True)
    assert set(before) <= set(acl(database.conn, helper))
    assert all(grant[1] != 0 for grant in acl(database.conn, helper))


@pytest.mark.parametrize("use_wrapper", [False, True])
def test_integration_fixture_supports_direct_sql_and_ci_wrapper(
    database: Database,
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    use_wrapper: bool,
) -> None:
    legacy(database)
    before = acl(database.conn)
    path = ROOT / "testing" / "integration" / "tests" / "conftest.py"
    spec = importlib.util.spec_from_file_location("ci_fixture_under_test", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    @contextmanager
    def existing_connection(*args: Any, **kwargs: Any) -> Iterator[PgConnection]:
        # Keep the legacy fixture uncommitted and avoid touching a shared database.
        yield database.conn

    empty = tmp_path / "no_session_cleanup.sql"
    empty.write_text("SELECT 1;\n")
    monkeypatch.setattr(module, "connect", existing_connection)
    monkeypatch.setattr(module, "_setup_sql_path", lambda: empty)
    monkeypatch.setattr(module, "_teardown_sql_path", lambda: empty)
    if use_wrapper:
        monkeypatch.setenv("PGFA_TEST_ALLOW_LEGACY_UPGRADE", "1")
    else:
        monkeypatch.delenv("PGFA_TEST_ALLOW_LEGACY_UPGRADE", raising=False)
    fixture = module.prepared_database.__wrapped__(None)
    next(fixture)
    assert "agent_prompt" in definition(database.conn)
    assert acl(database.conn) == before
    with pytest.raises(StopIteration):
        next(fixture)


def test_existing_helper_grants_allow_preserved_legacy_callers(
    database: Database,
) -> None:
    install(database.conn)
    helper = f"pgfirstaid_agent_prompt({HELPER_ARGS})"
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL("REVOKE EXECUTE ON FUNCTION {} FROM PUBLIC").format(sql.SQL(helper))
        )
        cur.execute("DROP FUNCTION pg_firstaid() RESTRICT")
    legacy(database)
    install(database.conn, allow_legacy_upgrade=True)
    for role in (database.owner, database.reader, database.delegate):
        assert scalar(
            database.conn,
            "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
            (role, helper),
        ), role
    assert not scalar(
        database.conn,
        "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
        (database.outsider, helper),
    )


def test_inaccessible_acl_grantor_rolls_back_instead_of_flattening(
    database: Database,
) -> None:
    legacy(database)
    before = definition(database.conn), acl(database.conn)
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL("GRANT CREATE ON SCHEMA {} TO {}").format(
                sql.Identifier(database.schema), sql.Identifier(database.owner)
            )
        )
        cur.execute(
            sql.SQL("SET LOCAL SESSION AUTHORIZATION {}").format(
                sql.Identifier(database.owner)
            )
        )
    try:
        with pytest.raises(psycopg2.errors.InsufficientPrivilege):
            install(database.conn, allow_legacy_upgrade=True)
        assert scalar(database.conn, "SELECT current_user") == database.owner
    finally:
        with database.conn.cursor() as cur:
            cur.execute("RESET SESSION AUTHORIZATION")
    assert (definition(database.conn), acl(database.conn)) == before
    assert (
        scalar(
            database.conn,
            "SELECT to_regprocedure(%s)",
            (scoped_signature(database, f"pgfirstaid_agent_prompt({HELPER_ARGS})"),),
        )
        is None
    )


def test_install_targets_creation_schema_not_search_path_fallback(
    database: Database,
) -> None:
    legacy(database)
    before = definition(database.conn), acl(database.conn)
    other = f"Other Schema.{uuid4().hex[:8]}"
    with database.conn.cursor() as cur:
        cur.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(other)))
        cur.execute(
            sql.SQL("SET LOCAL search_path TO {}, {}, public").format(
                sql.Identifier(other), sql.Identifier(database.schema)
            )
        )
    install(database.conn)
    assert (
        scalar(
            database.conn,
            "SELECT cardinality(proargnames) FROM pg_proc "
            "WHERE pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = %s) "
            "AND proname = 'pg_firstaid'",
            (other,),
        )
        == 9
    )
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL("SET LOCAL search_path TO {}, public").format(
                sql.Identifier(database.schema)
            )
        )
    assert (definition(database.conn), acl(database.conn)) == before


def test_upgrade_restores_caller_role_and_timeout_settings(database: Database) -> None:
    legacy(database)
    with database.conn.cursor() as cur:
        cur.execute("RESET ROLE")
        cur.execute("SET LOCAL lock_timeout = '5s'")
        cur.execute("SET LOCAL statement_timeout = '45s'")
    settings = (
        "SELECT current_setting('role'), current_setting('lock_timeout'), "
        "current_setting('statement_timeout')"
    )
    with database.conn.cursor() as cur:
        cur.execute(settings)
        before = cur.fetchone()
    install(database.conn, allow_legacy_upgrade=True)
    with database.conn.cursor() as cur:
        cur.execute(settings)
        assert cur.fetchone() == before


def test_existing_transaction_is_never_committed(database: Database) -> None:
    with database.conn.cursor() as cur:
        cur.execute("SAVEPOINT caller_boundary")
    install(database.conn)
    assert database.conn.get_transaction_status() == TRANSACTION_STATUS_INTRANS
    with database.conn.cursor() as cur:
        cur.execute("ROLLBACK TO SAVEPOINT caller_boundary")
    assert (
        scalar(
            database.conn,
            "SELECT to_regprocedure(%s)",
            (scoped_signature(database, "pg_firstaid()"),),
        )
        is None
    )
    assert database.conn.autocommit is False


@pytest.mark.parametrize("broken", [False, True])
def test_autocommit_is_restored_without_committing_caller_transaction(
    database: Database, tmp_path: Path, broken: bool
) -> None:
    # Explicit BEGIN exercises the same caller boundary with autocommit enabled.
    conn = psycopg2.connect(os.environ["PGFA_CI_INSTALL_TEST_DSN"])
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute("BEGIN")
            cur.execute("CREATE SCHEMA autocommit_caller")
            cur.execute("SET LOCAL search_path TO autocommit_caller, public")
        source = CANONICAL
        if broken:
            source = tmp_path / "bad.sql"
            source.write_text("SELECT ci_install_missing_symbol;")
            with pytest.raises(psycopg2.errors.UndefinedColumn):
                install(conn, source)
        else:
            install(conn, source)
        assert conn.autocommit is True
        assert conn.get_transaction_status() == TRANSACTION_STATUS_INTRANS
        with conn.cursor() as cur:
            cur.execute("ROLLBACK")
        assert scalar(conn, "SELECT to_regnamespace('autocommit_caller')") is None
    finally:
        with conn.cursor() as cur:
            cur.execute("ROLLBACK")
        conn.close()


def test_revoked_owner_is_not_added_as_a_helper_caller(database: Database) -> None:
    legacy(database)
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL("REVOKE EXECUTE ON FUNCTION pg_firstaid() FROM {} RESTRICT").format(
                sql.Identifier(database.owner)
            )
        )
    before = acl(database.conn)
    assert not scalar(
        database.conn,
        "SELECT has_function_privilege(%s, 'pg_firstaid()', 'EXECUTE')",
        (database.owner,),
    )
    install(database.conn, allow_legacy_upgrade=True)
    assert acl(database.conn) == before
    assert not scalar(
        database.conn,
        "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
        (database.owner, f"pgfirstaid_agent_prompt({HELPER_ARGS})"),
    )


def test_new_default_grants_do_not_broaden_legacy_access(database: Database) -> None:
    legacy(database)
    with database.conn.cursor() as cur:
        cur.execute(
            sql.SQL("ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO {}").format(
                sql.Identifier(database.outsider)
            )
        )
    before = acl(database.conn)
    install(database.conn, allow_legacy_upgrade=True)
    assert acl(database.conn) == before
    assert not scalar(
        database.conn,
        "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
        (database.outsider, f"pgfirstaid_agent_prompt({HELPER_ARGS})"),
    )


@pytest.mark.parametrize("autocommit", [False, True])
@pytest.mark.parametrize("broken", [False, True])
def test_idle_connection_owns_only_its_upgrade_transaction(
    database: Database, tmp_path: Path, autocommit: bool, broken: bool
) -> None:
    conn = psycopg2.connect(os.environ["PGFA_CI_INSTALL_TEST_DSN"])
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            # Session-temporary objects avoid persistent setup or cleanup commits.
            cur.execute("CREATE TEMP TABLE ci_install_session (id integer)")
            cur.execute("SET search_path TO pg_temp, public")
            cur.execute("SELECT current_schema()")
            schema = cur.fetchone()[0]
            columns = sql.SQL(", ").join(
                sql.SQL("{} text").format(sql.Identifier(name)) for name in COLUMNS
            )
            cur.execute(
                sql.SQL(
                    "CREATE FUNCTION pg_firstaid() RETURNS TABLE ({}) "
                    "LANGUAGE sql AS 'SELECT NULL::text, NULL::text, NULL::text, "
                    "NULL::text, NULL::text, NULL::text, NULL::text, "
                    "NULL::text WHERE false'"
                ).format(columns)
            )
            cur.execute(
                sql.SQL(
                    "REVOKE EXECUTE ON FUNCTION {}.pg_firstaid() FROM PUBLIC"
                ).format(sql.Identifier(schema))
            )
            cur.execute(
                "SELECT oid FROM pg_proc WHERE pronamespace = %s::regnamespace "
                "AND proname = 'pg_firstaid'",
                (schema,),
            )
            old_oid = cur.fetchone()[0]
        conn.autocommit = autocommit
        source = CANONICAL
        if broken:
            source = tmp_path / "bad_idle.sql"
            source.write_text(CANONICAL.read_text() + "\nSELECT missing_ci_symbol;")
            with pytest.raises(psycopg2.errors.UndefinedColumn):
                install(conn, source, allow_legacy_upgrade=True)
        else:
            install(conn, source, allow_legacy_upgrade=True)
        assert conn.autocommit is autocommit
        assert conn.get_transaction_status() == TRANSACTION_STATUS_IDLE
        with conn.cursor() as cur:
            cur.execute(
                "SELECT oid, proargnames FROM pg_proc "
                "WHERE pronamespace = %s::regnamespace AND proname = 'pg_firstaid'",
                (schema,),
            )
            new_oid, names = cur.fetchone()
        assert (new_oid == old_oid) is broken
        assert names == (list(COLUMNS) if broken else [*COLUMNS, "agent_prompt"])
    finally:
        conn.rollback()
        conn.close()


@pytest.mark.parametrize("invalid_encoding", [False, True])
def test_cli_unreadable_sql_fails_without_traceback(
    database: Database, tmp_path: Path, invalid_encoding: bool
) -> None:
    source = tmp_path / "missing.sql"
    if invalid_encoding:
        source.write_bytes(b"\xff")
    env = dict(
        os.environ,
        CI_INSTALL_PRIVATE_DSN=os.environ["PGFA_CI_INSTALL_TEST_DSN"],
    )
    result = subprocess.run(
        [
            "uv",
            "run",
            "python",
            "testing/ci_install.py",
            "--sql",
            str(source),
            "--dsn-env",
            "CI_INSTALL_PRIVATE_DSN",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert "Traceback" not in result.stderr
    assert "check" in result.stderr.lower()


def test_cli_connection_error_does_not_disclose_dsn() -> None:
    secret = "ci-password-must-not-appear"
    env = dict(os.environ, CI_INSTALL_PRIVATE_DSN=f"invalid-option={secret}")
    result = subprocess.run(
        [
            "uv",
            "run",
            "python",
            "testing/ci_install.py",
            "--dsn-env",
            "CI_INSTALL_PRIVATE_DSN",
        ],
        cwd=ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 1
    assert secret not in result.stdout + result.stderr
    assert "Traceback" not in result.stderr
    assert "connection" in result.stderr.lower()
