from __future__ import annotations

import argparse
import os
import sys
import zlib  # noqa: F401 - Preload Nix's libz for psycopg2's binary wheel.
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

import psycopg2
from psycopg2 import sql
from psycopg2.extensions import TRANSACTION_STATUS_IDLE, TRANSACTION_STATUS_INTRANS
from psycopg2.extensions import connection as PgConnection
from psycopg2.extensions import cursor as PgCursor

LEGACY_COLUMNS = [
    "severity",
    "category",
    "check_name",
    "object_name",
    "issue_description",
    "current_value",
    "recommended_action",
    "documentation_link",
]
MANUAL = (
    "Manual upgrade required: inventory dependencies, ownership and complete grants; "
    "follow docs/health-checks/agent-prompts.md#upgrade-an-existing-installation. "
    "Do not use CASCADE."
)


@dataclass(frozen=True)
class ExecuteGrant:
    grantor: str
    grantee: str | None
    grantable: bool


def _oid(cur: PgCursor, schema: str, name: str, inputs: int = 0) -> int | None:
    cur.execute(
        "SELECT p.oid FROM pg_proc p "
        "JOIN pg_namespace n ON n.oid = p.pronamespace "
        "WHERE n.nspname = %s AND p.proname = %s AND p.proargtypes = %s::oidvector",
        (schema, name, " ".join(["25"] * inputs)),
    )
    row = cur.fetchone()
    return row[0] if row else None


def _acl(cur: PgCursor, oid: int) -> set[ExecuteGrant]:
    cur.execute(
        "SELECT pg_get_userbyid(a.grantor), "
        "CASE WHEN a.grantee = 0 THEN NULL ELSE pg_get_userbyid(a.grantee) END, "
        "a.is_grantable FROM pg_proc p CROSS JOIN LATERAL "
        "aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a "
        "WHERE p.oid = %s AND a.privilege_type = 'EXECUTE'",
        (oid,),
    )
    return {ExecuteGrant(*row) for row in cur.fetchall()}


def _recipient(role: str | None) -> sql.Composable:
    return sql.SQL("PUBLIC") if role is None else sql.Identifier(role)


def _clear_acl(cur: PgCursor, target: sql.Composable, oid: int) -> None:
    grants = _acl(cur, oid)
    if grants:
        recipients = sql.SQL(", ").join(
            _recipient(role) for role in {grant.grantee for grant in grants}
        )
        cur.execute(
            sql.SQL("REVOKE ALL PRIVILEGES ON FUNCTION {} FROM {} RESTRICT").format(
                target, recipients
            )
        )


def _restore_acl(
    cur: PgCursor,
    target: sql.Composable,
    oid: int,
    owner: str,
    original_role_setting: str,
    grants: set[ExecuteGrant],
) -> None:
    pending = set(grants)
    authorized_grantors = {owner}
    while pending:
        ready = {grant for grant in pending if grant.grantor in authorized_grantors}
        if not ready:
            raise RuntimeError(f"Cannot replay the legacy ACL grant chain. {MANUAL}")
        for grant in ready:
            # SET ROLE retains the recorded grantor instead of flattening grant chains.
            cur.execute(
                sql.SQL("SET LOCAL ROLE {}").format(sql.Identifier(grant.grantor))
            )
            option = sql.SQL(" WITH GRANT OPTION" if grant.grantable else "")
            cur.execute(
                sql.SQL("GRANT EXECUTE ON FUNCTION {} TO {}{}").format(
                    target, _recipient(grant.grantee), option
                )
            )
            if grant.grantable and grant.grantee is not None:
                authorized_grantors.add(grant.grantee)
        pending -= ready
    cur.execute("SELECT set_config('role', %s, true)", (original_role_setting,))
    if _acl(cur, oid) != grants:
        raise RuntimeError(
            f"Legacy ACL grantors could not be preserved exactly. {MANUAL}"
        )


def _install(cur: PgCursor, source: str, allow_legacy_upgrade: bool) -> None:
    cur.execute("SELECT current_schema(), current_setting('role')")
    schema, original_role_setting = cur.fetchone()
    if schema is None:
        raise RuntimeError("No creation schema is selected; set a valid search_path.")
    oid = _oid(cur, schema, "pg_firstaid")
    if oid is None:
        cur.execute(source)
        return
    cur.execute(
        "SELECT proargnames, proallargtypes, proargmodes, proretset, "
        "prorettype = 'record'::regtype, prokind = 'f', "
        "pg_get_userbyid(proowner), obj_description(oid, 'pg_proc'), "
        "proconfig IS NOT NULL OR prosecdef OR proleakproof OR proisstrict "
        "OR provolatile <> 'v' OR proparallel <> 'u' "
        "OR procost <> 100 OR prorows <> 1000 OR prosupport <> 0 "
        "OR cardinality(protrftypes) > 0 "
        "OR EXISTS (SELECT 1 FROM pg_seclabel s "
        "WHERE s.classoid = 'pg_proc'::regclass AND s.objoid = pg_proc.oid) "
        "FROM pg_proc WHERE oid = %s",
        (oid,),
    )
    names, types, modes, retset, record, function, owner, comment, unsupported = (
        cur.fetchone()
    )
    known_shape = (
        names in (LEGACY_COLUMNS, [*LEGACY_COLUMNS, "agent_prompt"])
        and types == [25] * len(names)
        and modes == ["t"] * len(names)
        and retset
        and record
        and function
    )
    if not known_shape:
        raise RuntimeError(
            f"Unknown pg_firstaid() return shape; nothing dropped. {MANUAL}"
        )
    if names == [*LEGACY_COLUMNS, "agent_prompt"]:
        cur.execute(source)
        return
    if not allow_legacy_upgrade:
        raise RuntimeError(
            "Legacy pg_firstaid() requires explicit CI-only opt-in: "
            "pass allow_legacy_upgrade=True or --allow-legacy-upgrade. " + MANUAL
        )
    if unsupported:
        raise RuntimeError(f"Legacy function has unsupported custom metadata. {MANUAL}")

    target = sql.SQL("{}.pg_firstaid()").format(sql.Identifier(schema))
    helper = sql.SQL("{}.pgfirstaid_agent_prompt({})").format(
        sql.Identifier(schema), sql.SQL(", ").join([sql.SQL("text")] * 8)
    )
    old_grants = _acl(cur, oid)
    helper_oid = _oid(cur, schema, "pgfirstaid_agent_prompt", 8)
    helper_grants = _acl(cur, helper_oid) if helper_oid is not None else None
    cur.execute(sql.SQL("DROP FUNCTION {} RESTRICT").format(target))
    cur.execute(source)
    new_oid = _oid(cur, schema, "pg_firstaid")
    if new_oid is None:
        raise RuntimeError(
            "Installer did not recreate pg_firstaid(); upgrade rolled back."
        )
    _clear_acl(cur, target, new_oid)
    cur.execute(
        sql.SQL("ALTER FUNCTION {} OWNER TO {}").format(target, sql.Identifier(owner))
    )
    _restore_acl(cur, target, new_oid, owner, original_role_setting, old_grants)
    cur.execute(sql.SQL("COMMENT ON FUNCTION {} IS %s").format(target), (comment,))

    new_helper_oid = _oid(cur, schema, "pgfirstaid_agent_prompt", 8)
    if new_helper_oid is None:
        raise RuntimeError(
            "Installer did not create the prompt helper; upgrade rolled back."
        )
    if helper_grants is not None:
        if new_helper_oid != helper_oid or _acl(cur, new_helper_oid) != helper_grants:
            raise RuntimeError(f"Installer changed the existing helper ACL. {MANUAL}")
    else:
        # Creation defaults must not expose a restricted legacy installation.
        _clear_acl(cur, helper, new_helper_oid)
    callers = {grant.grantee for grant in old_grants}
    for role in callers:
        if role is None:
            permitted = any(
                grant.grantee is None for grant in _acl(cur, new_helper_oid)
            )
        else:
            cur.execute(
                "SELECT has_function_privilege(%s, %s, 'EXECUTE')",
                (role, new_helper_oid),
            )
            permitted = cur.fetchone()[0]
        if not permitted:
            cur.execute(
                sql.SQL("GRANT EXECUTE ON FUNCTION {} TO {}").format(
                    helper, _recipient(role)
                )
            )


def install_pgfirstaid(
    conn: PgConnection,
    sql_path: Path,
    *,
    allow_legacy_upgrade: bool = False,
) -> None:
    # This test-only entry point never commits or aborts an existing caller transaction.
    source = sql_path.read_text(encoding="utf-8")
    status = conn.get_transaction_status()
    if status not in (TRANSACTION_STATUS_IDLE, TRANSACTION_STATUS_INTRANS):
        raise RuntimeError(
            "Connection is busy or failed; use a healthy idle connection."
        )
    own_transaction = status == TRANSACTION_STATUS_IDLE
    original_autocommit = conn.autocommit
    savepoint = sql.Identifier(f"ci_install_{uuid4().hex}")
    if own_transaction and original_autocommit:
        conn.autocommit = False
    try:
        with conn.cursor() as cur:
            if not own_transaction:
                cur.execute(sql.SQL("SAVEPOINT {}").format(savepoint))
            try:
                # These SQL limits are independent of any external provider API timeout.
                cur.execute("SHOW lock_timeout")
                lock_timeout = cur.fetchone()[0]
                cur.execute("SHOW statement_timeout")
                statement_timeout = cur.fetchone()[0]
                cur.execute("SET LOCAL lock_timeout = '2s'")
                cur.execute("SET LOCAL statement_timeout = '30s'")
                _install(cur, source, allow_legacy_upgrade)
                cur.execute(
                    "SELECT set_config('lock_timeout', %s, true), "
                    "set_config('statement_timeout', %s, true)",
                    (lock_timeout, statement_timeout),
                )
                if not own_transaction:
                    cur.execute(sql.SQL("RELEASE SAVEPOINT {}").format(savepoint))
            except BaseException:
                if not own_transaction:
                    cur.execute(sql.SQL("ROLLBACK TO SAVEPOINT {}").format(savepoint))
                    cur.execute(sql.SQL("RELEASE SAVEPOINT {}").format(savepoint))
                raise
        if own_transaction:
            conn.commit()
    except BaseException:
        if own_transaction:
            conn.rollback()
        raise
    finally:
        if own_transaction and original_autocommit:
            conn.autocommit = True


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install pgFirstAid in CI; legacy upgrades require explicit opt-in."
    )
    parser.add_argument("--allow-legacy-upgrade", action="store_true")
    parser.add_argument(
        "--sql",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "pgFirstAid.sql",
    )
    parser.add_argument("--dsn-env", help="Read a DSN from this environment variable")
    args = parser.parse_args()
    dsn = ""
    if args.dsn_env:
        dsn = os.getenv(args.dsn_env, "")
        if not dsn:
            print(
                "CI install failed: --dsn-env variable is unset or empty.",
                file=sys.stderr,
            )
            return 1
    try:
        conn = psycopg2.connect(dsn)
    except psycopg2.Error:
        print(
            "CI install connection failed: check PG* or --dsn-env settings and access.",
            file=sys.stderr,
        )
        return 1
    try:
        conn.autocommit = True
        install_pgfirstaid(
            conn, args.sql, allow_legacy_upgrade=args.allow_legacy_upgrade
        )
    except RuntimeError as error:
        print(f"CI install refused: {error}", file=sys.stderr)
        return 1
    except (OSError, UnicodeError):
        print(
            "CI install failed: check that --sql names a readable UTF-8 SQL file.",
            file=sys.stderr,
        )
        return 1
    except psycopg2.Error as error:
        # Server diagnostics may contain connection details or supplied SQL literals.
        reason = {
            "2BP01": "Dependent objects block RESTRICT; plan a manual upgrade.",
            "42501": "Check ownership, schema access and SET ROLE for ACL grantors.",
            "42P13": "Check the function shape and the supplied installer version.",
        }.get(
            error.pgcode,
            "Check installer SQL and database privileges in the test database.",
        )
        print(
            f"CI install failed (SQLSTATE {error.pgcode or 'unavailable'}). "
            f"{reason} No upgrade was committed.",
            file=sys.stderr,
        )
        return 1
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
