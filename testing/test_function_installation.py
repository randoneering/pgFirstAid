from __future__ import annotations

import os
import subprocess
import time
from collections.abc import Iterator
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any
from uuid import uuid4

import psycopg2
import pytest
from psycopg2 import sql
from psycopg2.extensions import TRANSACTION_STATUS_INTRANS
from psycopg2.extensions import connection as PgConnection

ROOT = Path(__file__).resolve().parents[1]
COLUMNS = [
    "severity",
    "category",
    "check_name",
    "object_name",
    "issue_description",
    "current_value",
    "recommended_action",
    "documentation_link",
]
ARGS = ",".join(["text"] * 8)
HELPER = f"pgfirstaid_agent_prompt({ARGS})"


def source() -> str:
    return (ROOT / "pgFirstAid.sql").read_text()


def connect() -> PgConnection:
    dsn = os.getenv("PGFA_PROMPT_TEST_DSN")
    if not dsn and not os.getenv("PGPORT"):
        pytest.skip("Set PGFA_PROMPT_TEST_DSN to a disposable PostgreSQL database")
    return psycopg2.connect(dsn or "")


@pytest.fixture
def db() -> Iterator[PgConnection]:
    conn = connect()
    schema = f'Install ( $function_install$ . "{uuid4().hex[:12]}"'
    with conn.cursor() as cur:
        cur.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(schema)))
        cur.execute(
            sql.SQL("SET LOCAL search_path TO {}, public").format(
                sql.Identifier(schema)
            )
        )
    try:
        yield conn
    finally:
        conn.rollback()
        conn.close()


def value(conn: PgConnection, query: str, params: tuple[Any, ...] = ()) -> Any:
    with conn.cursor() as cur:
        cur.execute(query, params or None)
        return cur.fetchone()[0]


def run(conn: PgConnection, text: str | None = None) -> None:
    with conn.cursor() as cur:
        cur.execute(source() if text is None else text)


def legacy(conn: PgConnection) -> None:
    columns = ", ".join(f"{name} text" for name in COLUMNS)
    run(
        conn,
        f"CREATE FUNCTION pg_firstaid() RETURNS TABLE ({columns}) "
        "LANGUAGE sql AS 'SELECT NULL::text, NULL::text, NULL::text, "
        "NULL::text, NULL::text, NULL::text, NULL::text, NULL::text WHERE false'",
    )


def acl(conn: PgConnection, signature: str = "pg_firstaid()") -> Any:
    return value(
        conn,
        "SELECT jsonb_agg(to_jsonb(a) ORDER BY a.grantor, a.grantee) "
        "FROM pg_proc p CROSS JOIN LATERAL "
        "aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a "
        "WHERE p.oid = %s::regprocedure",
        (signature,),
    )


def snapshot(conn: PgConnection) -> Any:
    return value(
        conn,
        "SELECT jsonb_agg(jsonb_build_array(p.oid, pg_get_functiondef(p.oid), "
        "p.proowner, p.proacl, obj_description(p.oid, 'pg_proc')) ORDER BY p.oid) "
        "FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = current_schema() AND p.proname IN "
        "('pg_firstaid', 'pgfirstaid_agent_prompt', "
        "'pgfirstaid_pg_stat_statements_checks', '_pg_firstaid_checkpoint_stats')",
    )


def settings(conn: PgConnection) -> Any:
    return value(
        conn,
        "SELECT ARRAY[current_setting('role'), current_setting('search_path'), "
        "current_setting('lock_timeout'), current_setting('statement_timeout')]",
    )


def role(conn: PgConnection, name: str) -> str:
    return sql.Identifier(name).as_string(conn)


def test_same_file_upgrades_known_eight_columns(db: PgConnection) -> None:
    legacy(db)
    run(db)
    assert value(
        db,
        "SELECT proargnames FROM pg_proc WHERE oid = 'pg_firstaid()'::regprocedure",
    ) == [*COLUMNS, "agent_prompt"]
    assert value(
        db,
        "SELECT count(*) FILTER (WHERE agent_prompt IS NOT NULL) > 0 FROM pg_firstaid()",
    )


def test_known_legacy_upgrade_works_without_superuser(db: PgConnection) -> None:
    installer = f'plain installer "{uuid4().hex[:10]}"'
    run(db, f"CREATE ROLE {role(db, installer)} NOSUPERUSER")
    schema = str(value(db, "SELECT current_schema()"))
    run(db, f"ALTER SCHEMA {role(db, schema)} OWNER TO {role(db, installer)}")
    run(db, f"SET LOCAL SESSION AUTHORIZATION {role(db, installer)}")
    try:
        legacy(db)
        before_acl = acl(db)
        run(db)
        assert value(db, "SELECT current_user") == installer
        assert not value(db, "SELECT rolsuper FROM pg_roles WHERE rolname=current_user")
        assert value(
            db,
            "SELECT proargnames FROM pg_proc WHERE oid='pg_firstaid()'::regprocedure",
        ) == [*COLUMNS, "agent_prompt"]
        assert acl(db) == before_acl
    finally:
        run(db, "RESET SESSION AUTHORIZATION")


def test_upgrade_keeps_old_callers_working_with_private_function_defaults(
    db: PgConnection,
) -> None:
    reader, outsider = [f"{kind}_{uuid4().hex[:10]}" for kind in ("reader", "outsider")]
    for name in (reader, outsider):
        run(db, f"CREATE ROLE {role(db, name)}")
        run(
            db,
            f"GRANT USAGE ON SCHEMA {role(db, value(db, 'SELECT current_schema()'))} "
            f"TO {role(db, name)}",
        )
    run(db, "ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC")
    legacy(db)
    run(db, f"GRANT EXECUTE ON FUNCTION pg_firstaid() TO {role(db, reader)}")
    run(db)
    signatures = [
        "pgfirstaid_pg_stat_statements_checks()",
        "_pg_firstaid_checkpoint_stats()",
        HELPER,
    ]
    for signature in signatures:
        assert value(
            db, "SELECT has_function_privilege(%s, %s, 'EXECUTE')", (reader, signature)
        ), signature
        assert not value(
            db,
            "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
            (outsider, signature),
        ), signature


def test_installer_owner_needs_no_default_execute_grants(db: PgConnection) -> None:
    installer = f"restricted_installer_{uuid4().hex[:10]}"
    run(db, f"CREATE ROLE {role(db, installer)} NOSUPERUSER")
    schema = str(value(db, "SELECT current_schema()"))
    run(db, f"ALTER SCHEMA {role(db, schema)} OWNER TO {role(db, installer)}")
    run(db, f"SET LOCAL SESSION AUTHORIZATION {role(db, installer)}")
    try:
        run(db, "ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC")
        run(
            db,
            f"ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM {role(db, installer)}",
        )
        legacy(db)
        before_acl = acl(db)
        run(db)
        assert acl(db) == before_acl
        assert value(
            db,
            "SELECT proargnames FROM pg_proc WHERE oid='pg_firstaid()'::regprocedure",
        ) == [*COLUMNS, "agent_prompt"]
    finally:
        run(db, "RESET SESSION AUTHORIZATION")


def test_stale_private_collector_cannot_be_published_as_an_upgrade(
    db: PgConnection,
) -> None:
    legacy(db)
    before = snapshot(db)
    preparation = source().split("-- Cleanup shares the apply statement:", 1)[0]
    run(db, preparation)
    columns = ", ".join(f"{name} text" for name in COLUMNS)
    run(
        db,
        "DROP FUNCTION pg_temp._pgfirstaid_stage_main() RESTRICT; "
        f"CREATE FUNCTION pg_temp._pgfirstaid_stage_main() RETURNS TABLE ({columns}) "
        "LANGUAGE sql AS 'SELECT NULL::text, NULL::text, NULL::text, NULL::text, "
        "NULL::text, NULL::text, NULL::text, NULL::text WHERE false'",
    )
    run(db, "SAVEPOINT incomplete_stage")
    with pytest.raises(psycopg2.Error, match="Invalid private collector stage"):
        run(db, "SELECT pg_temp._pgfirstaid_install_function(current_schema())")
    run(db, "ROLLBACK TO SAVEPOINT incomplete_stage")
    assert snapshot(db) == before


@pytest.mark.parametrize("kind", ["defaulted", "variadic"])
def test_overlapping_prompt_overload_refuses_the_upgrade_atomically(
    db: PgConnection,
    kind: str,
) -> None:
    legacy(db)
    if kind == "defaulted":
        arguments = ", ".join(f"p{i} text" for i in range(9)) + " DEFAULT NULL"
    else:
        arguments = "VARIADIC values_ text[]"
    run(
        db,
        f"CREATE FUNCTION pgfirstaid_agent_prompt({arguments}) RETURNS text "
        "LANGUAGE sql AS 'SELECT ''custom overload''::text'",
    )
    before = snapshot(db)
    run(db, "SAVEPOINT unsafe_overload")
    with pytest.raises(psycopg2.Error, match="Overlapping.*overload"):
        run(db)
    run(db, "ROLLBACK TO SAVEPOINT unsafe_overload")
    assert snapshot(db) == before


def test_defaulted_main_overload_cannot_make_the_public_call_ambiguous(
    db: PgConnection,
) -> None:
    legacy(db)
    run(
        db,
        "CREATE FUNCTION pg_firstaid(extra text DEFAULT NULL) RETURNS text "
        "LANGUAGE sql AS 'SELECT ''custom overload''::text'",
    )
    before = snapshot(db)
    run(db, "SAVEPOINT main_overload")
    with pytest.raises(psycopg2.Error, match="Overlapping.*overload"):
        run(db)
    run(db, "ROLLBACK TO SAVEPOINT main_overload")
    assert snapshot(db) == before


def test_unrelated_defaulted_overload_does_not_block_upgrade(db: PgConnection) -> None:
    legacy(db)
    arguments = ", ".join(f"p{i} integer" for i in range(9)) + " DEFAULT NULL"
    run(
        db,
        f"CREATE FUNCTION pgfirstaid_agent_prompt({arguments}) RETURNS text "
        "LANGUAGE sql AS 'SELECT ''unrelated overload''::text'",
    )
    run(db)
    assert value(
        db,
        "SELECT count(*) FILTER (WHERE agent_prompt IS NOT NULL) > 0 FROM pg_firstaid()",
    )


def test_same_file_reinstall_keeps_oid_and_dependents(db: PgConnection) -> None:
    run(db)
    oid = value(db, "SELECT 'pg_firstaid()'::regprocedure::oid")
    run(db, "CREATE VIEW consumer AS SELECT * FROM pg_firstaid()")
    run(db)
    assert value(db, "SELECT 'pg_firstaid()'::regprocedure::oid") == oid
    assert value(db, "SELECT count(*) FROM consumer") > 0
    assert (
        value(
            db,
            "SELECT count(*) FROM pg_proc WHERE pronamespace = "
            "pg_my_temp_schema() AND proname LIKE '_pgfirstaid_%'",
        )
        == 0
    )
    assert (
        value(db, "SELECT to_regclass('pg_temp._pgfirstaid_install_context')") is None
    )


@pytest.mark.parametrize("public", [False, True])
def test_upgrade_preserves_comment_acl_and_settings(
    db: PgConnection, public: bool
) -> None:
    legacy(db)
    token = uuid4().hex[:10]
    owner, reader, delegate, outsider = [
        f'Install {name}. "{token}"'
        for name in ("owner", "reader", "delegate", "outsider")
    ]
    for name in (owner, reader, delegate, outsider):
        run(db, f"CREATE ROLE {role(db, name)}")
        run(
            db,
            f"GRANT USAGE ON SCHEMA {role(db, value(db, 'SELECT current_schema()'))} "
            f"TO {role(db, name)}",
        )
    run(db, f"ALTER FUNCTION pg_firstaid() OWNER TO {role(db, owner)}")
    if not public:
        run(db, "REVOKE ALL ON FUNCTION pg_firstaid() FROM PUBLIC")
    run(db, "COMMENT ON FUNCTION pg_firstaid() IS 'preserve me'")
    run(db, f"SET LOCAL ROLE {role(db, owner)}")
    run(
        db,
        f"GRANT EXECUTE ON FUNCTION pg_firstaid() TO {role(db, reader)} "
        "WITH GRANT OPTION",
    )
    run(db, f"SET LOCAL ROLE {role(db, reader)}")
    run(db, f"GRANT EXECUTE ON FUNCTION pg_firstaid() TO {role(db, delegate)}")
    run(db, "RESET ROLE")
    run(
        db,
        f"ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO {role(db, outsider)}",
    )
    before = acl(db)
    saved = settings(db)
    run(db)
    assert acl(db) == before
    assert (
        value(db, "SELECT obj_description('pg_firstaid()'::regprocedure, 'pg_proc')")
        == "preserve me"
    )
    assert (
        value(
            db,
            "SELECT pg_get_userbyid(proowner) FROM pg_proc "
            "WHERE oid = 'pg_firstaid()'::regprocedure",
        )
        == owner
    )
    assert settings(db) == saved
    for name in (owner, reader, delegate):
        assert value(
            db, "SELECT has_function_privilege(%s, %s, 'EXECUTE')", (name, HELPER)
        )
    for signature in ("pg_firstaid()", HELPER):
        assert (
            value(
                db,
                "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                (outsider, signature),
            )
            is public
        )


@pytest.mark.parametrize("problem", ["shape", "security", "config", "dependency"])
def test_refusal_leaves_all_public_functions_intact(
    db: PgConnection, problem: str
) -> None:
    legacy(db)
    if problem == "shape":
        run(
            db,
            "DROP FUNCTION pg_firstaid() RESTRICT; CREATE FUNCTION pg_firstaid() "
            "RETURNS text LANGUAGE sql AS 'SELECT NULL::text'",
        )
    elif problem == "security":
        run(db, "ALTER FUNCTION pg_firstaid() SECURITY DEFINER")
    elif problem == "config":
        run(db, "ALTER FUNCTION pg_firstaid() SET work_mem = '8MB'")
    else:
        run(db, "CREATE VIEW consumer AS SELECT * FROM pg_firstaid()")
    before = snapshot(db)
    run(db, "SAVEPOINT expected_failure")
    with pytest.raises(psycopg2.Error):
        run(db)
    run(db, "ROLLBACK TO SAVEPOINT expected_failure")
    assert snapshot(db) == before


@pytest.mark.parametrize("version", [8, 9])
def test_existing_helper_keeps_acl_and_gets_missing_old_callers(
    db: PgConnection, version: int
) -> None:
    run(db)
    run(db, f"REVOKE ALL ON FUNCTION {HELPER} FROM PUBLIC")
    token = uuid4().hex[:10]
    reader, outsider = f"reader_{token}", f"outsider_{token}"
    for name in (reader, outsider):
        run(db, f"CREATE ROLE {name}")
    run(db, "REVOKE ALL ON FUNCTION pg_firstaid() FROM PUBLIC")
    run(db, f"GRANT EXECUTE ON FUNCTION pg_firstaid() TO {reader}")
    run(db, f"GRANT EXECUTE ON FUNCTION {HELPER} TO {outsider} WITH GRANT OPTION")
    if version == 8:
        run(db, "DROP FUNCTION pg_firstaid() RESTRICT")
        legacy(db)
        run(db, "REVOKE ALL ON FUNCTION pg_firstaid() FROM PUBLIC")
        run(db, f"GRANT EXECUTE ON FUNCTION pg_firstaid() TO {reader}")
    old = acl(db, HELPER)
    run(db)
    assert all(item in acl(db, HELPER) for item in old)
    assert value(
        db, "SELECT has_function_privilege(%s, %s, 'EXECUTE')", (reader, HELPER)
    )
    assert not any(item["grantee"] == 0 for item in acl(db, HELPER))


def test_fresh_main_does_not_expand_existing_helper_policy(db: PgConnection) -> None:
    run(db)
    run(db, f"REVOKE ALL ON FUNCTION {HELPER} FROM PUBLIC")
    old = acl(db, HELPER)
    run(db, "DROP FUNCTION pg_firstaid() RESTRICT")
    run(db)
    assert acl(db, HELPER) == old


@pytest.mark.parametrize(
    "failure",
    [
        "recreate",
        "acl",
        "cleanup",
        "cleanup_dependency",
        "shape",
        "security",
        "config",
        "dependency",
    ],
)
def test_apply_is_atomic_with_autocommit_and_retry(failure: str) -> None:
    conn = connect()
    conn.autocommit = True
    try:
        # All fixtures live in this session's temporary schema, including catalog DDL.
        run(conn, "CREATE TEMP VIEW fixture AS SELECT 1 AS id")
        run(conn, "SET search_path TO pg_temp, public")
        run(conn)
        run(conn, "DROP FUNCTION pg_temp.pg_firstaid() RESTRICT")
        legacy(conn)
        if failure == "shape":
            run(conn, "ALTER FUNCTION pg_temp.pg_firstaid() RENAME TO original_main")
            run(
                conn,
                "CREATE FUNCTION pg_firstaid() RETURNS text LANGUAGE sql "
                "AS 'SELECT NULL::text'",
            )
        if failure == "security":
            run(conn, "ALTER FUNCTION pg_temp.pg_firstaid() SECURITY DEFINER")
        elif failure == "config":
            run(conn, "ALTER FUNCTION pg_temp.pg_firstaid() SET work_mem = '8MB'")
        elif failure == "dependency":
            run(
                conn, "CREATE TEMP VIEW consumer AS SELECT * FROM pg_temp.pg_firstaid()"
            )
        old = snapshot(conn)
        text = source()
        if failure == "recreate":
            text = text.replace(
                "        EXECUTE definition;",
                "        IF i = 4 THEN RAISE EXCEPTION 'injected recreation'; END IF;\n"
                "        EXECUTE definition;",
            )
        elif failure == "acl":
            text = text.replace(
                "        pending := old_acl;",
                "        RAISE EXCEPTION 'injected ACL';\n        pending := old_acl;",
            )
        elif failure == "cleanup":
            text = text.replace(
                "    DROP VIEW pg_temp._pgfirstaid_install_context RESTRICT;",
                "    RAISE EXCEPTION 'injected cleanup';",
            )
        prepare, apply = text.split("DO $install_apply$", 1)
        run(conn, prepare)
        if failure == "cleanup_dependency":
            run(
                conn,
                "CREATE TEMP VIEW caller_dependency AS "
                "SELECT * FROM pg_temp._pgfirstaid_install_context",
            )
        assert snapshot(conn) == old
        saved = settings(conn)
        with pytest.raises(psycopg2.Error):
            run(conn, "DO $install_apply$" + apply)
        assert snapshot(conn) == old
        assert settings(conn) == saved
        if failure not in {
            "shape",
            "security",
            "config",
            "dependency",
            "cleanup_dependency",
        }:
            run(conn)
            assert "agent_prompt" in value(
                conn, "SELECT pg_get_functiondef('pg_temp.pg_firstaid()'::regprocedure)"
            )
    finally:
        conn.close()


@pytest.mark.parametrize("version", [0, 8, 9])
def test_outer_transaction_and_set_role_survive(db: PgConnection, version: int) -> None:
    name = f"installer_{uuid4().hex[:10]}"
    schema = value(db, "SELECT current_schema()")
    run(db, f"CREATE ROLE {name}")
    run(db, f"GRANT ALL ON SCHEMA {role(db, schema)} TO {name}")
    run(db, f"SET LOCAL ROLE {name}")
    run(db, "SET LOCAL lock_timeout = '800ms'; SET LOCAL statement_timeout = '40s'")
    saved = settings(db)
    run(db, "SAVEPOINT caller_work")
    if version == 8:
        legacy(db)
    elif version == 9:
        run(db)
    run(db)
    assert settings(db) == saved
    assert db.get_transaction_status() == TRANSACTION_STATUS_INTRANS
    run(db, "ROLLBACK TO SAVEPOINT caller_work")
    assert (
        value(
            db,
            "SELECT count(*) FROM pg_proc p JOIN pg_namespace n "
            "ON n.oid=p.pronamespace WHERE n.nspname=current_schema()",
        )
        == 0
    )


@pytest.mark.parametrize("kind", ["view", "table", "function"])
def test_reserved_temporary_collision_is_not_overwritten(
    db: PgConnection, kind: str
) -> None:
    if kind == "function":
        run(
            db,
            "CREATE FUNCTION pg_temp._pgfirstaid_stage_main() RETURNS text "
            "LANGUAGE sql AS 'SELECT ''caller data''::text'",
        )
    elif kind == "view":
        run(db, "CREATE TEMP VIEW _pgfirstaid_install_context AS SELECT 'caller data'")
    else:
        run(db, "CREATE TEMP TABLE _pgfirstaid_install_context (id integer)")
    run(db, "SAVEPOINT collision")
    with pytest.raises(psycopg2.Error, match="Reserved pgFirstAid temporary name"):
        run(db)
    run(db, "ROLLBACK TO SAVEPOINT collision")
    if kind == "function":
        assert value(db, "SELECT pg_temp._pgfirstaid_stage_main()") == "caller data"
    else:
        assert value(db, "SELECT to_regclass('pg_temp._pgfirstaid_install_context')")


@pytest.mark.parametrize("version", [8, 9])
@pytest.mark.parametrize("metadata", ["SECURITY DEFINER", "IMMUTABLE", "COST 42"])
def test_custom_metadata_refusal_for_both_versions(
    db: PgConnection, version: int, metadata: str
) -> None:
    if version == 8:
        legacy(db)
    else:
        run(db)
    run(db, f"ALTER FUNCTION pg_firstaid() {metadata}")
    before = snapshot(db)
    run(db, "SAVEPOINT custom_metadata")
    with pytest.raises(psycopg2.Error, match="Unsupported custom metadata"):
        run(db)
    run(db, "ROLLBACK TO SAVEPOINT custom_metadata")
    assert snapshot(db) == before


def test_custom_helper_defaults_are_not_silently_removed(db: PgConnection) -> None:
    run(db)
    definition = value(db, "SELECT pg_get_functiondef(%s::regprocedure)", (HELPER,))
    run(
        db,
        definition.replace(
            "p_documentation_link text)", "p_documentation_link text DEFAULT NULL)", 1
        ),
    )
    before = snapshot(db)
    run(db, "SAVEPOINT helper_defaults")
    with pytest.raises(psycopg2.Error, match="Unsupported custom metadata"):
        run(db)
    run(db, "ROLLBACK TO SAVEPOINT helper_defaults")
    assert snapshot(db) == before


def test_upgrade_restores_actual_set_role_setting(db: PgConnection) -> None:
    legacy(db)
    admin = f"admin_{uuid4().hex[:12]}"
    run(db, f"CREATE ROLE {admin} SUPERUSER")
    run(db, f"SET LOCAL ROLE {admin}")
    saved = settings(db)
    run(db)
    assert settings(db) == saved


@pytest.mark.parametrize("legacy_first", [False, True])
def test_entire_file_in_psql_autocommit(legacy_first: bool) -> None:
    container = os.getenv("PGFA_SQL_TEST_CONTAINER")
    if container not in {"pgfirstaid-prompts-test", "pgfirstaid-prompts-test18"}:
        pytest.skip("Set PGFA_SQL_TEST_CONTAINER to an approved disposable container")
    setup = (
        "CREATE TEMP VIEW fixture AS SELECT 1 AS id; SET search_path=pg_temp,public;"
    )
    if legacy_first:
        columns = ", ".join(f"{name} text" for name in COLUMNS)
        setup += (
            f"CREATE FUNCTION pg_temp.pg_firstaid() RETURNS TABLE ({columns}) "
            "LANGUAGE sql AS 'SELECT NULL::text, NULL::text, NULL::text, "
            "NULL::text, NULL::text, NULL::text, NULL::text, NULL::text WHERE false';"
            "REVOKE EXECUTE ON FUNCTION pg_temp.pg_firstaid() FROM PUBLIC;"
        )
    checks = """
DO $assert_install$
BEGIN
    IF (SELECT proargnames FROM pg_proc WHERE oid =
        'pg_temp.pg_firstaid()'::regprocedure) <>
        ARRAY['severity','category','check_name','object_name','issue_description',
        'current_value','recommended_action','documentation_link','agent_prompt']
        OR to_regclass('pg_temp._pgfirstaid_install_context') IS NOT NULL THEN
        RAISE EXCEPTION 'installation or cleanup failed';
    END IF;
END;
$assert_install$;
"""
    result = subprocess.run(
        [
            "docker",
            "exec",
            "--interactive",
            container,
            "psql",
            "--username=postgres",
            "--dbname=postgres",
            "--no-psqlrc",
            "--quiet",
            "--set=ON_ERROR_STOP=1",
        ],
        input=setup + source() + checks + source() + checks,
        text=True,
        capture_output=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_preflight_lock_excludes_concurrent_acl_changes() -> None:
    conn, other = connect(), connect()
    conn.autocommit = True
    barrier = int(uuid4().hex[:8], 16)
    try:
        run(conn, "CREATE TEMP VIEW fixture AS SELECT 1 AS id")
        run(conn, "SET search_path TO pg_temp, public")
        run(conn)
        schema = value(conn, "SELECT current_schema()")
        target = f"{role(conn, schema)}.pg_firstaid()"
        run(other, f"SELECT pg_advisory_lock({barrier})")
        text = source().replace(
            "    old_main := existing[4];",
            f"    PERFORM pg_advisory_xact_lock({barrier});\n"
            "    old_main := existing[4];",
        )
        conn.autocommit = False
        with ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(run, conn, text)
            try:
                deadline = time.monotonic() + 3
                while not value(
                    other,
                    "SELECT EXISTS (SELECT FROM pg_locks WHERE pid=%s "
                    "AND locktype='advisory' AND NOT granted)",
                    (conn.get_backend_pid(),),
                ):
                    assert time.monotonic() < deadline, (
                        "installer did not reach barrier"
                    )
                    time.sleep(0.01)
                run(other, "SET LOCAL lock_timeout = '200ms'")
                with pytest.raises(psycopg2.errors.LockNotAvailable):
                    run(other, f"REVOKE EXECUTE ON FUNCTION {target} FROM PUBLIC")
            finally:
                other.rollback()
                run(other, f"SELECT pg_advisory_unlock({barrier})")
                future.result(timeout=10)
    finally:
        other.rollback()
        other.close()
        conn.rollback()
        conn.close()
