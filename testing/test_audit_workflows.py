from __future__ import annotations

import importlib.util
import os
import re
import shutil
import subprocess
from pathlib import Path
from types import ModuleType
from uuid import uuid4

import psycopg2
import pytest
import yaml
from psycopg2.extensions import parse_dsn

ROOT = Path(__file__).resolve().parents[1]


def installation_scripts() -> list[tuple[str, str]]:
    scripts = []
    for path in sorted((ROOT / "workflows").glob("*.yml")):
        document = yaml.safe_load(path.read_text())
        for job_name, job in document.get("jobs", {}).items():
            for step in job.get("steps", []):
                script = step.get("run", "")
                if "\\i pgFirstAid.sql" in script:
                    scripts.append((f"{path.name}:{job_name}", script))
    return scripts


@pytest.fixture
def audit_module() -> ModuleType:
    spec = importlib.util.spec_from_file_location(
        "pgfirstaid_audit_under_test", ROOT / "workflows" / "pgfirstaid_audit.py"
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture
def audit_dsn() -> str:
    dsn = os.getenv("PGFA_PROMPT_TEST_DSN")
    if dsn:
        return dsn
    if all(os.getenv(name) for name in ("PGHOST", "PGUSER", "PGDATABASE")):
        return ""
    pytest.skip("Set PGFA_PROMPT_TEST_DSN or PG* for a disposable PostgreSQL database")


def test_legacy_audit_install_reports_explicit_upgrade(
    audit_module: ModuleType,
    audit_dsn: str,
    caplog: pytest.LogCaptureFixture,
) -> None:
    schema = f"legacy_audit_{uuid4().hex[:8]}"
    legacy = (
        f"CREATE SCHEMA {schema}; SET LOCAL search_path TO {schema}, public; "
        "CREATE FUNCTION pg_firstaid() RETURNS TABLE (severity text, category text, "
        "check_name text, object_name text, issue_description text, current_value text, "
        "recommended_action text, documentation_link text) LANGUAGE sql "
        "AS $$ SELECT 'INFO', 'Test', 'Legacy', 'System', NULL::text, "
        "NULL::text, NULL::text, NULL::text $$;\n"
    )
    with pytest.raises(SystemExit) as error:
        audit_module.run_audit(
            audit_dsn, legacy + (ROOT / "pgFirstAid.sql").read_text()
        )
    assert error.value.code == 1
    assert "explicit upgrade" in caplog.text.lower()
    assert "agent-prompts.md" in caplog.text
    with psycopg2.connect(audit_dsn) as conn, conn.cursor() as cur:
        cur.execute("SELECT to_regnamespace(%s)", (schema,))
        assert cur.fetchone()[0] is None


def test_audit_sql_errors_exit_without_an_unhandled_traceback(
    audit_module: ModuleType,
    audit_dsn: str,
    caplog: pytest.LogCaptureFixture,
) -> None:
    with pytest.raises(SystemExit) as error:
        audit_module.run_audit(audit_dsn, "SELECT * FROM pgfirstaid_missing_relation")
    assert error.value.code == 1
    assert "Database audit failed" in caplog.text


@pytest.mark.parametrize(
    ("name", "script"),
    installation_scripts(),
    ids=[name for name, _ in installation_scripts()],
)
def test_workflow_installation_stops_on_sql_error(
    name: str,
    script: str,
    audit_dsn: str,
    tmp_path: Path,
) -> None:
    if shutil.which("psql") is None:
        pytest.skip("Install psql to exercise workflow error handling")
    match = re.search(r"(psql\b[\s\S]*?)<<['\"]?(\w+)['\"]?\s*\n", script)
    assert match is not None, name

    def connection_variable(value: re.Match[str]) -> str:
        expression = value[1].strip()
        name = expression.rsplit(".", 1)[-1]
        if name == "host":
            name = "PGHOST"
        elif name.endswith("_USER"):
            name = "PGUSER"
        assert name in {"PGHOST", "PGUSER", "PGDATABASE"}, expression
        return "${" + name + "}"

    command = re.sub(r"\$\{\{(.*?)\}\}", connection_variable, match[1])
    command = command.replace("-d postgres", '-d "${PGDATABASE}"')
    command = command.replace(
        '"$DB_URL"',
        '-h "${PGHOST}" -p "${PGPORT:-5432}" -U "${PGUSER}" -d "${PGDATABASE}"',
    )
    parameters = parse_dsn(audit_dsn)
    env = os.environ.copy()
    for parameter, variable in [
        ("host", "PGHOST"),
        ("port", "PGPORT"),
        ("user", "PGUSER"),
        ("dbname", "PGDATABASE"),
        ("password", "PGPASSWORD"),
        ("sslmode", "PGSSLMODE"),
    ]:
        if parameter in parameters:
            env[variable] = parameters[parameter]
    command = command.replace("psql", "psql --no-psqlrc", 1)
    invocation = (
        command + "<<'PGFA_TEST'\nBEGIN;\n"
        "DO $$ BEGIN RAISE EXCEPTION 'installer_regression_failure'; END $$;\n"
        "SELECT 'continued_after_install_error';\nROLLBACK;\nPGFA_TEST\n"
    )
    result = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", invocation],
        cwd=tmp_path,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert "installer_regression_failure" in result.stderr, (name, result.stderr)
    assert result.returncode != 0, (name, result.stdout, result.stderr)
    assert "continued_after_install_error" not in result.stdout, name
