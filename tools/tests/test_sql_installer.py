from __future__ import annotations

import importlib
import re
import subprocess
import sys
from pathlib import Path
from types import ModuleType

import pytest

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))


def wrapper() -> ModuleType:
    assert (TOOLS / "sql_installer.py").exists(), "shared atomic wrapper is missing"
    return importlib.import_module("sql_installer")


@pytest.mark.parametrize(
    "body",
    [
        b"SELECT 'caf\xc3\xa9';\r\n-- trailing comment",
        b"SELECT '$pgfirstaid_install$';\n-- $pgfirstaid_install_1$\n",
        b"DO $$ BEGIN PERFORM '$pgfirstaid_install$'; END; $$;\n",
    ],
)
def test_wrapper_is_one_command_and_preserves_every_body_byte(body: bytes) -> None:
    api = wrapper()
    rendered = api.wrap_installer(body)
    tag = re.search(rb"\nDO (\$[a-z0-9_]+\$)\nBEGIN\n", rendered)[1]
    assert tag not in body
    assert rendered.count(tag) == 2
    assert rendered.endswith(b"\nEND;\n" + tag + b";\n")
    assert api.unwrap_installer(rendered) == body
    assert api.refresh_installer(rendered) == rendered
    assert api.wrap_installer(body) == rendered


@pytest.mark.parametrize(
    "payload",
    [b"$pgfirstaid_install$", b"\nEND;\n$pgfirstaid_install$;\nSELECT 'untrusted'"],
)
def test_refresh_uses_final_boundary_when_body_contains_old_delimiter(
    payload: bytes,
) -> None:
    api = wrapper()
    rendered = api.wrap_installer(b"SELECT 'original';")
    edited = rendered.replace(b"'original'", b"'" + payload + b"'")
    refreshed = api.refresh_installer(edited)
    assert refreshed.startswith(
        b"-- pgFirstAid atomic installer v1\nDO $pgfirstaid_install_1$\n"
    )
    assert api.unwrap_installer(refreshed) == b"SELECT '" + payload + b"';"


@pytest.mark.parametrize(
    "broken",
    [
        b"-- pgFirstAid atomic installer v1\nSELECT 1;",
        b"-- pgFirstAid atomic installer v1\nDO $pgfirstaid_install$\nBEGIN\nSELECT 1;",
        b"-- pgFirstAid atomic installer v2\nSELECT 1;",
    ],
)
def test_malformed_owned_wrapper_refuses_to_guess(broken: bytes) -> None:
    api = wrapper()
    with pytest.raises(ValueError, match="malformed.*wrapper"):
        api.unwrap_installer(broken)


@pytest.mark.parametrize("name", ["sync_sql_helpers.py", "generate_cve_sql.py"])
def test_codegen_importlib_loading_does_not_depend_on_working_directory(
    tmp_path: Path, name: str
) -> None:
    code = (
        "import importlib.util, sys; "
        "spec = importlib.util.spec_from_file_location('codegen_under_test', sys.argv[1]); "
        "module = importlib.util.module_from_spec(spec); "
        "sys.modules[spec.name] = module; spec.loader.exec_module(module)"
    )
    result = subprocess.run(
        [sys.executable, "-c", code, str(TOOLS / name)],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_refresh_leaves_unwrapped_fixtures_unchanged() -> None:
    api = wrapper()
    raw = b"SELECT '$pgfirstaid_install$';\n"
    assert api.refresh_installer(raw) == raw
    assert api.unwrap_installer(raw) == raw


@pytest.mark.parametrize(
    "name", ["pgFirstAid.sql", "view_pgFirstAid.sql", "view_pgFirstAid_managed.sql"]
)
def test_real_installers_pin_one_backend_for_preparation_apply_and_cleanup(
    name: str,
) -> None:
    data = (TOOLS.parent / name).read_bytes()
    assert data.startswith(b"-- pgFirstAid atomic installer v1\nDO ")
    api = wrapper()
    body = api.unwrap_installer(data)
    assert api.wrap_installer(body) == data
    assert b"CREATE OR REPLACE FUNCTION" in body
    if name != "pgFirstAid.sql":
        assert body.endswith(
            b"PERFORM _pgfirstaid_install_view('pg_temp._pgfirstaid_view_stage'::regclass);\n"
            b"DROP VIEW pg_temp._pgfirstaid_view_stage RESTRICT;\n"
        )
