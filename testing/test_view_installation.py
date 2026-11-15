from __future__ import annotations

import os
from collections.abc import Iterator
from pathlib import Path
from uuid import uuid4

import psycopg2
import pytest
from psycopg2 import sql
from psycopg2.extensions import connection as PgConnection

ROOT = Path(__file__).resolve().parents[1]
INSTALLERS = ["view_pgFirstAid.sql", "view_pgFirstAid_managed.sql"]
COLUMNS = [
    "severity",
    "category",
    "check_name",
    "object_name",
    "issue_description",
    "current_value",
    "recommended_action",
    "documentation_link",
    "severity_order",
]


@pytest.fixture
def database() -> Iterator[PgConnection]:
    dsn = os.getenv("PGFA_PROMPT_TEST_DSN")
    if not dsn and not all(os.getenv(k) for k in ("PGHOST", "PGUSER", "PGDATABASE")):
        pytest.skip("Set PGFA_PROMPT_TEST_DSN or PG* for a disposable database")
    conn = psycopg2.connect(dsn or "")
    with conn.cursor() as cur:
        schema = f'Installer "Tests.{uuid4().hex[:8]}'
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


def execute(conn: PgConnection, statement: str) -> None:
    with conn.cursor() as cur:
        cur.execute(statement)


def scalar(conn: PgConnection, statement: str) -> object:
    with conn.cursor() as cur:
        cur.execute(statement)
        return cur.fetchone()[0]


def install(conn: PgConnection, filename: str) -> None:
    execute(conn, (ROOT / filename).read_text())


def old_view(conn: PgConnection, kind: str = "text") -> None:
    expressions = [f"'old'::text AS {name}" for name in COLUMNS]
    if kind == "numeric":
        expressions[0] = "1::numeric AS severity"
    elif kind == "collation":
        expressions[0] = "'old'::text COLLATE \"C\" AS severity"
    elif kind == "layout":
        expressions[0], expressions[1] = expressions[1], expressions[0]
    elif kind == "rename":
        expressions[0] = "'old'::text AS legacy_severity"
    execute(conn, "CREATE VIEW v_pgfirstaid AS SELECT " + ", ".join(expressions))


def snapshot(conn: PgConnection) -> object:
    return scalar(
        conn,
        """
        SELECT jsonb_build_array(c.oid, pg_get_viewdef(c.oid), c.relowner,
            c.relacl::text, c.reloptions, obj_description(c.oid, 'pg_class'))
        FROM pg_class c WHERE c.oid = 'v_pgfirstaid'::regclass
    """,
    )


@pytest.mark.parametrize("filename", INSTALLERS)
@pytest.mark.parametrize("kind", ["text", "numeric", "collation", "layout", "rename"])
def test_recovers_old_layout(database: PgConnection, filename: str, kind: str) -> None:
    old_view(database, kind)
    install(database, filename)
    assert (
        scalar(
            database,
            "SELECT count(*) FROM pg_attribute WHERE "
            "attrelid='v_pgfirstaid'::regclass AND attnum > 0",
        )
        == 10
    )
    assert (
        scalar(database, "SELECT to_regclass('pg_temp._pgfirstaid_view_stage')") is None
    )
    assert scalar(database, "SHOW lock_timeout") == "0"
    assert not scalar(
        database,
        "SELECT EXISTS (SELECT 1 FROM pg_locks "
        "WHERE pid=pg_backend_pid() AND mode='AccessExclusiveLock' "
        "AND relation IN ('pg_class'::regclass, 'pg_attribute'::regclass))",
    )


@pytest.mark.parametrize("filename", INSTALLERS)
def test_recovery_preserves_the_callers_role_setting(
    database: PgConnection,
    filename: str,
) -> None:
    old_view(database)
    before = scalar(database, "SELECT current_setting('role')")
    install(database, filename)
    assert scalar(database, "SELECT current_setting('role')") == before


@pytest.mark.parametrize("filename", INSTALLERS)
def test_compatible_append_retains_oid_and_dependents(
    database: PgConnection,
    filename: str,
) -> None:
    expressions = [
        "'old'::text" + (' COLLATE "C"' if name in COLUMNS[3:7] else "") + f" AS {name}"
        for name in COLUMNS[:-1]
    ]
    expressions.append("1::integer AS severity_order")
    execute(database, "CREATE VIEW v_pgfirstaid AS SELECT " + ", ".join(expressions))
    execute(
        database,
        "GRANT SELECT ON v_pgfirstaid TO PUBLIC; "
        "COMMENT ON VIEW v_pgfirstaid IS 'keep compatible metadata'; "
        "CREATE VIEW dependent AS SELECT severity FROM v_pgfirstaid",
    )
    oid = scalar(database, "SELECT 'v_pgfirstaid'::regclass::oid")
    install(database, filename)
    assert scalar(database, "SELECT 'v_pgfirstaid'::regclass::oid") == oid
    assert scalar(database, "SELECT to_regclass('dependent')") is not None
    assert scalar(
        database, "SELECT has_table_privilege('public', 'v_pgfirstaid', 'SELECT')"
    )
    assert scalar(database, "SELECT obj_description('v_pgfirstaid'::regclass)") == (
        "keep compatible metadata"
    )
    before = snapshot(database)
    install(database, filename)
    assert snapshot(database) == before


@pytest.mark.parametrize("filename", INSTALLERS)
@pytest.mark.parametrize(
    "options",
    [
        "security_invoker=true",
        "security_barrier=true",
        "security_invoker=true, security_barrier=true",
    ],
)
def test_compatible_reinstall_preserves_security_options(
    database: PgConnection,
    filename: str,
    options: str,
) -> None:
    install(database, filename)
    execute(database, f"ALTER VIEW v_pgfirstaid SET ({options})")
    before = snapshot(database)
    install(database, filename)
    assert snapshot(database) == before


def test_compatible_replacement_keeps_invoker_permission_checks(
    database: PgConnection,
) -> None:
    execute(database, (ROOT / "data/view_installer.sql").read_text())
    reader = f"view_reader_{uuid4().hex[:8]}"
    with database.cursor() as cur:
        cur.execute(sql.SQL("CREATE ROLE {}").format(sql.Identifier(reader)))
        cur.execute(
            sql.SQL("GRANT USAGE ON SCHEMA {} TO {}").format(
                sql.Identifier(scalar(database, "SELECT current_schema()")),
                sql.Identifier(reader),
            )
        )
        cur.execute(
            "CREATE TABLE sensitive_source (secret text); "
            "INSERT INTO sensitive_source VALUES ('owner-only fixture data'); "
            "REVOKE ALL ON sensitive_source FROM PUBLIC; "
            "CREATE VIEW v_pgfirstaid WITH (security_invoker=true) AS "
            "SELECT secret FROM sensitive_source"
        )
        cur.execute(
            sql.SQL("GRANT SELECT ON v_pgfirstaid TO {}").format(sql.Identifier(reader))
        )
        cur.execute(
            "CREATE TEMP VIEW _pgfirstaid_view_stage AS "
            "SELECT secret FROM sensitive_source"
        )
        cur.execute(
            "SELECT _pgfirstaid_install_view('pg_temp._pgfirstaid_view_stage'::regclass)"
        )
        cur.execute("SAVEPOINT reader_access")
        cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(reader)))
        with pytest.raises(psycopg2.errors.InsufficientPrivilege):
            cur.execute("SELECT secret FROM v_pgfirstaid")
        cur.execute("ROLLBACK TO SAVEPOINT reader_access")


@pytest.mark.parametrize("filename", INSTALLERS)
def test_incompatible_dependency_rolls_back(
    database: PgConnection, filename: str
) -> None:
    old_view(database)
    execute(
        database,
        "GRANT SELECT ON v_pgfirstaid TO PUBLIC; "
        "COMMENT ON VIEW v_pgfirstaid IS 'dependent original'; "
        "CREATE VIEW dependent AS SELECT severity FROM v_pgfirstaid",
    )
    before = snapshot(database)
    execute(database, "SAVEPOINT installation")
    with pytest.raises(psycopg2.errors.DependentObjectsStillExist):
        install(database, filename)
    execute(database, "ROLLBACK TO SAVEPOINT installation")
    assert snapshot(database) == before
    assert scalar(database, "SELECT severity FROM dependent") == "old"


@pytest.mark.parametrize("filename", INSTALLERS)
def test_preserves_owner_acl_comments_options(
    database: PgConnection, filename: str
) -> None:
    token = uuid4().hex[:8]
    owner, reader, leaf = [f'{name} "{token}' for name in ("owner", "reader", "leaf")]
    with database.cursor() as cur:
        for role in (owner, reader, leaf):
            cur.execute(sql.SQL("CREATE ROLE {}").format(sql.Identifier(role)))
        for role in (owner, reader, leaf):
            cur.execute(
                sql.SQL("GRANT USAGE ON SCHEMA {} TO {}").format(
                    sql.Identifier(scalar(database, "SELECT current_schema()")),
                    sql.Identifier(role),
                )
            )
        cur.execute(
            sql.SQL("GRANT CREATE ON SCHEMA {} TO {}").format(
                sql.Identifier(scalar(database, "SELECT current_schema()")),
                sql.Identifier(owner),
            )
        )
    old_view(database)
    execute(
        database,
        "COMMENT ON VIEW v_pgfirstaid IS 'view comment'; "
        "COMMENT ON COLUMN v_pgfirstaid.severity IS 'column comment'; "
        "ALTER VIEW v_pgfirstaid SET (security_barrier=true, security_invoker=true)",
    )
    with database.cursor() as cur:
        cur.execute(
            sql.SQL("ALTER VIEW v_pgfirstaid OWNER TO {}").format(sql.Identifier(owner))
        )
        cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(owner)))
        cur.execute(
            sql.SQL("GRANT SELECT ON v_pgfirstaid TO {} WITH GRANT OPTION").format(
                sql.Identifier(reader)
            )
        )
        cur.execute(
            sql.SQL(
                "GRANT UPDATE (severity) ON v_pgfirstaid TO {} WITH GRANT OPTION"
            ).format(sql.Identifier(reader))
        )
        cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(reader)))
        cur.execute(
            sql.SQL("GRANT SELECT ON v_pgfirstaid TO {}").format(sql.Identifier(leaf))
        )
        cur.execute(
            sql.SQL("GRANT UPDATE (severity) ON v_pgfirstaid TO {}").format(
                sql.Identifier(leaf)
            )
        )
        cur.execute("RESET ROLE")
        cur.execute(
            sql.SQL("ALTER DEFAULT PRIVILEGES GRANT INSERT ON TABLES TO {}").format(
                sql.Identifier(leaf)
            )
        )
        cur.execute("ALTER DEFAULT PRIVILEGES GRANT SELECT ON TABLES TO PUBLIC")
    before = scalar(
        database, "SELECT relacl::text FROM pg_class WHERE oid='v_pgfirstaid'::regclass"
    )
    owner_before = scalar(
        database, "SELECT relowner FROM pg_class WHERE oid='v_pgfirstaid'::regclass"
    )
    column_acl_before = scalar(
        database,
        "SELECT attacl::text FROM pg_attribute WHERE "
        "attrelid='v_pgfirstaid'::regclass AND attname='severity'",
    )
    install(database, filename)
    assert (
        scalar(
            database, "SELECT relowner FROM pg_class WHERE oid='v_pgfirstaid'::regclass"
        )
        == owner_before
    )
    assert (
        scalar(
            database,
            "SELECT relacl::text FROM pg_class WHERE oid='v_pgfirstaid'::regclass",
        )
        == before
    )
    assert scalar(database, "SELECT obj_description('v_pgfirstaid'::regclass)") == (
        "view comment"
    )
    assert scalar(database, "SELECT col_description('v_pgfirstaid'::regclass, 1)") == (
        "column comment"
    )
    assert (
        scalar(
            database,
            "SELECT attacl::text FROM pg_attribute WHERE "
            "attrelid='v_pgfirstaid'::regclass AND attname='severity'",
        )
        == column_acl_before
    )
    assert scalar(
        database,
        "SELECT reloptions @> ARRAY['security_barrier=true', "
        "'security_invoker=true'] FROM pg_class "
        "WHERE oid='v_pgfirstaid'::regclass",
    )
    assert not scalar(
        database, "SELECT has_table_privilege('public', 'v_pgfirstaid', 'SELECT')"
    )
    with database.cursor() as cur:
        cur.execute("SELECT has_table_privilege(%s, 'v_pgfirstaid', 'INSERT')", (leaf,))
        assert not cur.fetchone()[0]


@pytest.mark.parametrize(
    "metadata",
    [
        "default",
        "rule",
        "trigger",
        "removed_comment",
        "removed_acl",
    ],
)
def test_refuses_unsupported_metadata(database: PgConnection, metadata: str) -> None:
    old_view(database, "rename" if metadata.startswith("removed_") else "text")
    if metadata == "default":
        execute(
            database, "ALTER VIEW v_pgfirstaid ALTER COLUMN severity SET DEFAULT 'x'"
        )
    elif metadata == "rule":
        execute(
            database,
            "CREATE RULE keep_rule AS ON UPDATE TO v_pgfirstaid DO INSTEAD NOTHING",
        )
    elif metadata == "trigger":
        execute(
            database,
            "CREATE FUNCTION keep_trigger() RETURNS trigger "
            "LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$; "
            "CREATE TRIGGER keep_trigger INSTEAD OF UPDATE ON v_pgfirstaid "
            "FOR EACH ROW EXECUTE FUNCTION keep_trigger()",
        )
    elif metadata == "removed_acl":
        execute(database, "GRANT SELECT (legacy_severity) ON v_pgfirstaid TO PUBLIC")
    else:
        execute(database, "COMMENT ON COLUMN v_pgfirstaid.legacy_severity IS 'keep'")
    before = snapshot(database)
    execute(database, "SAVEPOINT installation")
    with pytest.raises(psycopg2.Error, match="manual"):
        install(database, INSTALLERS[0])
    execute(database, "ROLLBACK TO SAVEPOINT installation")
    assert snapshot(database) == before


def test_canonical_helper_handles_dollar_tags(database: PgConnection) -> None:
    path = ROOT / "data/view_installer.sql"
    assert path.exists(), "canonical atomic installer is missing"
    execute(database, path.read_text())
    old_view(database)
    execute(
        database,
        "CREATE TEMP VIEW _pgfirstaid_view_stage AS "
        "SELECT '$view_install$; DROP VIEW v_pgfirstaid; --'::text AS evidence",
    )
    execute(
        database,
        "SELECT _pgfirstaid_install_view('pg_temp._pgfirstaid_view_stage'::regclass)",
    )
    assert scalar(database, "SELECT evidence FROM v_pgfirstaid") == (
        "$view_install$; DROP VIEW v_pgfirstaid; --"
    )


@pytest.mark.parametrize("tag", ["CREATE VIEW", "COMMENT"])
def test_recreation_or_restore_failure_is_one_atomic_statement(
    database: PgConnection,
    tag: str,
) -> None:
    execute(database, (ROOT / "data/view_installer.sql").read_text())
    old_view(database)
    execute(
        database,
        "GRANT SELECT ON v_pgfirstaid TO PUBLIC; "
        "COMMENT ON VIEW v_pgfirstaid IS 'original'; "
        "CREATE TEMP VIEW _pgfirstaid_view_stage AS SELECT 42 AS severity",
    )
    fallback = f"fallback_{uuid4().hex[:8]}"
    with database.cursor() as cur:
        schema = str(scalar(database, "SELECT current_schema()"))
        cur.execute(sql.SQL("CREATE SCHEMA {}").format(sql.Identifier(fallback)))
        cur.execute(
            sql.SQL(
                "CREATE VIEW {}.v_pgfirstaid AS SELECT 'unrelated'::text AS marker"
            ).format(sql.Identifier(fallback))
        )
        cur.execute(
            sql.SQL("SET LOCAL search_path TO {}, {}, public").format(
                sql.Identifier(schema), sql.Identifier(fallback)
            )
        )
    before = snapshot(database)
    with database.cursor() as cur:
        cur.execute(
            sql.SQL("""
            CREATE FUNCTION fail_installation() RETURNS event_trigger
            LANGUAGE plpgsql AS $failure$
            BEGIN
                IF TG_TAG = 'COMMENT' OR to_regclass(
                    format('%I.v_pgfirstaid', current_schema())) IS NULL THEN
                    RAISE EXCEPTION 'injected installation failure'
                        USING ERRCODE='P7777';
                END IF;
            END;
            $failure$;
            CREATE EVENT TRIGGER {} ON ddl_command_start WHEN TAG IN ({})
            EXECUTE FUNCTION fail_installation()
        """).format(sql.Identifier("fail_" + uuid4().hex[:8]), sql.Literal(tag))
        )
    execute(
        database,
        """
        DO $failure$
        BEGIN
            PERFORM _pgfirstaid_install_view(
                'pg_temp._pgfirstaid_view_stage'::regclass);
            RAISE EXCEPTION 'expected injected failure';
        EXCEPTION WHEN SQLSTATE 'P7777' THEN
            NULL;
        END;
        $failure$
    """,
    )
    assert snapshot(database) == before
    assert scalar(database, "SHOW lock_timeout") == "0"
    assert scalar(database, "SELECT current_user = session_user")
    with database.cursor() as cur:
        cur.execute(
            sql.SQL("SELECT marker FROM {}.v_pgfirstaid").format(
                sql.Identifier(fallback)
            )
        )
        assert cur.fetchone()[0] == "unrelated"


@pytest.mark.parametrize("filename", INSTALLERS)
def test_existing_helper_acls_are_unchanged(
    database: PgConnection, filename: str
) -> None:
    install(database, filename)
    execute(
        database,
        "REVOKE EXECUTE ON FUNCTION "
        "_pgfirstaid_install_view(regclass) FROM PUBLIC; "
        "REVOKE EXECUTE ON FUNCTION pgfirstaid_agent_prompt("
        "text,text,text,text,text,text,text,text) FROM PUBLIC",
    )
    query = (
        "SELECT jsonb_agg(proacl::text ORDER BY proname) FROM pg_proc "
        "WHERE pronamespace=(SELECT oid FROM pg_namespace "
        "WHERE nspname=current_schema()) "
        "AND proname IN "
        "('_pgfirstaid_install_view', 'pgfirstaid_agent_prompt')"
    )
    before = scalar(database, query)
    install(database, filename)
    assert scalar(database, query) == before


def test_wrong_object_kind_is_refused(database: PgConnection) -> None:
    execute(database, "CREATE TABLE v_pgfirstaid (evidence text)")
    oid = scalar(database, "SELECT 'v_pgfirstaid'::regclass::oid")
    execute(database, "SAVEPOINT installation")
    with pytest.raises(psycopg2.Error, match="not an ordinary view"):
        install(database, INSTALLERS[0])
    execute(database, "ROLLBACK TO SAVEPOINT installation")
    assert scalar(database, "SELECT 'v_pgfirstaid'::regclass::oid") == oid


@pytest.mark.parametrize("timeout", ["123ms", "7s"])
def test_locking_is_bounded_restored_and_not_recursive(
    database: PgConnection,
    timeout: str,
) -> None:
    execute(database, (ROOT / "data/view_installer.sql").read_text())
    execute(
        database,
        "CREATE VIEW v_pgfirstaid AS SELECT relname::varchar AS name "
        "FROM pg_class; CREATE TEMP VIEW _pgfirstaid_view_stage AS "
        "SELECT relname::text AS name FROM pg_class",
    )
    with database.cursor() as cur:
        cur.execute("SELECT set_config('lock_timeout', %s, true)", (timeout,))
    execute(
        database,
        "SELECT _pgfirstaid_install_view('pg_temp._pgfirstaid_view_stage'::regclass)",
    )
    assert scalar(database, "SHOW lock_timeout") == timeout
    assert not scalar(
        database,
        "SELECT EXISTS (SELECT 1 FROM pg_locks "
        "WHERE pid=pg_backend_pid() AND "
        "relation='pg_class'::regclass AND mode='AccessExclusiveLock')",
    )


@pytest.mark.parametrize("filename", INSTALLERS)
def test_reserved_stage_retry_and_dollar_tag_in_installer(
    database: PgConnection,
    filename: str,
) -> None:
    execute(database, "CREATE TEMP VIEW _pgfirstaid_view_stage AS SELECT 1 AS stale")
    source = (ROOT / filename).read_text()
    assert "'Missing Primary Key' as check_name" in source
    source = source.replace(
        "'Missing Primary Key' as check_name",
        "'$view_install$; SELECT unsafe(); --' as check_name",
        1,
    )
    execute(database, source)
    assert scalar(
        database,
        "SELECT pg_get_viewdef('v_pgfirstaid'::regclass) "
        "LIKE '%$view_install$; SELECT unsafe(); --%'",
    )
    assert (
        scalar(database, "SELECT to_regclass('pg_temp._pgfirstaid_view_stage')") is None
    )


def test_unavailable_grantor_refuses_before_drop(database: PgConnection) -> None:
    execute(database, (ROOT / "data/view_installer.sql").read_text())
    token = uuid4().hex[:8]
    owner, grantor, reader = [
        f"{name}_{token}" for name in ("owner", "grantor", "reader")
    ]
    schema = scalar(database, "SELECT current_schema()")
    with database.cursor() as cur:
        for role in (owner, grantor, reader):
            cur.execute(sql.SQL("CREATE ROLE {}").format(sql.Identifier(role)))
            cur.execute(
                sql.SQL("GRANT USAGE ON SCHEMA {} TO {}").format(
                    sql.Identifier(schema),
                    sql.Identifier(role),
                )
            )
        cur.execute(
            sql.SQL("GRANT CREATE ON SCHEMA {} TO {}").format(
                sql.Identifier(schema),
                sql.Identifier(owner),
            )
        )
    old_view(database)
    with database.cursor() as cur:
        cur.execute(
            sql.SQL("ALTER VIEW v_pgfirstaid OWNER TO {}; SET LOCAL ROLE {}").format(
                sql.Identifier(owner),
                sql.Identifier(owner),
            )
        )
        cur.execute(
            sql.SQL("GRANT SELECT ON v_pgfirstaid TO {} WITH GRANT OPTION").format(
                sql.Identifier(grantor)
            )
        )
        cur.execute("RESET ROLE")
        cur.execute(sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(grantor)))
        cur.execute(
            sql.SQL("GRANT SELECT ON v_pgfirstaid TO {}").format(sql.Identifier(reader))
        )
        cur.execute("RESET ROLE")
        cur.execute(
            sql.SQL("SET SESSION AUTHORIZATION {}").format(sql.Identifier(owner))
        )
    execute(
        database, "CREATE TEMP VIEW _pgfirstaid_view_stage AS SELECT 42 AS severity"
    )
    before = snapshot(database)
    execute(
        database,
        """
        DO $failure$
        BEGIN
            PERFORM _pgfirstaid_install_view(
                'pg_temp._pgfirstaid_view_stage'::regclass);
            RAISE EXCEPTION 'expected unavailable grantor failure';
        EXCEPTION WHEN insufficient_privilege THEN
            NULL;
        END;
        $failure$
    """,
    )
    assert snapshot(database) == before
    assert scalar(database, "SELECT current_user") == owner
    execute(database, "RESET SESSION AUTHORIZATION")


@pytest.mark.parametrize("filename", INSTALLERS)
def test_preserves_public_column_acl_and_empty_owner_acl(
    database: PgConnection,
    filename: str,
) -> None:
    old_view(database)
    execute(
        database,
        "REVOKE ALL ON v_pgfirstaid FROM CURRENT_USER; "
        "GRANT SELECT (severity) ON v_pgfirstaid TO PUBLIC",
    )
    before = scalar(
        database,
        "SELECT attacl::text FROM pg_attribute WHERE "
        "attrelid='v_pgfirstaid'::regclass AND attname='severity'",
    )
    install(database, filename)
    assert (
        scalar(
            database,
            "SELECT relacl::text FROM pg_class WHERE oid='v_pgfirstaid'::regclass",
        )
        == "{}"
    )
    assert (
        scalar(
            database,
            "SELECT attacl::text FROM pg_attribute WHERE "
            "attrelid='v_pgfirstaid'::regclass AND attname='severity'",
        )
        == before
    )


@pytest.mark.parametrize("filename", INSTALLERS)
def test_retained_column_metadata_follows_names_not_positions(
    database: PgConnection,
    filename: str,
) -> None:
    old_view(database, "layout")
    execute(
        database,
        "COMMENT ON COLUMN v_pgfirstaid.severity IS 'severity metadata'; "
        "GRANT SELECT (severity) ON v_pgfirstaid TO PUBLIC",
    )
    before = scalar(
        database,
        "SELECT attacl::text FROM pg_attribute WHERE "
        "attrelid='v_pgfirstaid'::regclass AND attname='severity'",
    )
    install(database, filename)
    assert scalar(database, "SELECT col_description('v_pgfirstaid'::regclass, 1)") == (
        "severity metadata"
    )
    assert (
        scalar(
            database,
            "SELECT attacl::text FROM pg_attribute WHERE "
            "attrelid='v_pgfirstaid'::regclass AND attname='severity'",
        )
        == before
    )


def test_temporary_dependency_refuses_atomically(database: PgConnection) -> None:
    execute(database, (ROOT / "data/view_installer.sql").read_text())
    old_view(database)
    execute(
        database,
        "CREATE TEMP TABLE temporary_evidence (evidence integer); "
        "CREATE TEMP VIEW _pgfirstaid_view_stage AS SELECT * FROM temporary_evidence",
    )
    before = snapshot(database)
    execute(
        database,
        """
        DO $failure$
        BEGIN
            PERFORM _pgfirstaid_install_view(
                'pg_temp._pgfirstaid_view_stage'::regclass);
            RAISE EXCEPTION 'expected temporary dependency failure';
        EXCEPTION WHEN invalid_table_definition THEN
            NULL;
        END;
        $failure$
    """,
    )
    assert snapshot(database) == before


def test_embedded_helpers_match_canonical() -> None:
    canonical = (ROOT / "data/view_installer.sql").read_text()
    for filename in INSTALLERS:
        assert canonical in (ROOT / filename).read_text()
