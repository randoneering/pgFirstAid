from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "sync_sql_helpers.py"
TARGETS = ("pgFirstAid.sql", "view_pgFirstAid.sql", "view_pgFirstAid_managed.sql")
PROMPT = (
    b"CREATE OR REPLACE FUNCTION pgfirstaid_agent_prompt(p_severity text)\n"
    b"RETURNS text LANGUAGE plpgsql STABLE AS $prompt$\n"
    b"BEGIN RETURN 'original prompt'; END;\n"
    b"$prompt$;"
)
VIEW = (
    b"CREATE OR REPLACE FUNCTION _pgfirstaid_install_view(p_sql text)\n"
    b"RETURNS void LANGUAGE plpgsql AS $view_install$\n"
    b"BEGIN EXECUTE p_sql; END;\n"
    b"$view_install$;"
)
FUNCTION = (
    b"CREATE OR REPLACE FUNCTION pg_temp._pgfirstaid_install_function(target_schema text)\n"
    b"RETURNS void LANGUAGE plpgsql AS $function_install$\n"
    b"BEGIN RETURN; END;\n"
    b"$function_install$;"
)
STAGED_PROMPT = PROMPT.replace(
    b"FUNCTION pgfirstaid_agent_prompt(",
    b"FUNCTION pg_temp._pgfirstaid_stage_prompt(",
)
PREFIX = b"-- unrelated header\r\nSELECT 'caf\xc3\xa9';\r\n\r\n"
SUFFIX = (
    b"\r\n\r\n-- GENERATED cves BEGIN (do not edit)\r\n"
    b"('CVE-2026-0001', 8.1),\r\n-- GENERATED cves END\r\n"
    b"-- GENERATED bugs BEGIN\r\n('PG18-TEST', 1)\r\n"
    b"-- GENERATED bugs END\r\nSELECT 'unrelated trailer';"
)


@pytest.fixture
def repo(tmp_path: Path) -> Path:
    data = tmp_path / "data"
    data.mkdir()
    (data / "agent_prompt.sql").write_bytes(PROMPT + b"\n")
    (data / "view_installer.sql").write_bytes(VIEW + b"\n")
    (data / "function_installer.sql").write_bytes(FUNCTION + b"\n")
    for name in TARGETS:
        helpers = PROMPT
        if name != "pgFirstAid.sql":
            helpers += b"\n\n" + VIEW
        else:
            helpers += b"\n\n" + FUNCTION
        (tmp_path / name).write_bytes(PREFIX + helpers + SUFFIX)
    return tmp_path


def run_tool(root: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), "--root", str(root), *args],
        capture_output=True,
        text=True,
        check=False,
    )


def assert_sync(root: Path) -> None:
    result = run_tool(root)
    assert result.returncode == 0, result.stdout + result.stderr


def snapshot(root: Path) -> dict[str, tuple[bytes, int]]:
    return {
        str(path.relative_to(root)): (path.read_bytes(), path.stat().st_mtime_ns)
        for path in root.rglob("*.sql")
    }


def test_bootstrap_wraps_each_helper_and_preserves_unrelated_bytes(repo: Path) -> None:
    assert_sync(repo)
    prompt_block = (
        b"-- GENERATED agent_prompt BEGIN\n"
        + PROMPT
        + b"\n-- GENERATED agent_prompt END"
    )
    view_block = (
        b"-- GENERATED view_installer BEGIN\n"
        + VIEW
        + b"\n-- GENERATED view_installer END"
    )
    for name in TARGETS:
        expected = prompt_block
        if name != "pgFirstAid.sql":
            expected += b"\n\n" + view_block
        else:
            expected = expected.replace(PROMPT, STAGED_PROMPT)
            expected += (
                b"\n\n-- GENERATED function_installer BEGIN\n"
                + FUNCTION
                + b"\n-- GENERATED function_installer END"
            )
        assert (repo / name).read_bytes() == PREFIX + expected + SUFFIX


@pytest.mark.parametrize(
    "kind", ["agent_prompt", "view_installer", "function_installer"]
)
def test_canonical_edit_updates_every_mapped_copy(repo: Path, kind: str) -> None:
    assert_sync(repo)
    source = repo / "data" / f"{kind}.sql"
    original = {
        "agent_prompt": PROMPT,
        "view_installer": VIEW,
        "function_installer": FUNCTION,
    }[kind]
    updated = original.replace(b"END;", b"RAISE NOTICE 'updated'; END;")
    source.write_bytes(updated + b"\n")
    before = {name: (repo / name).read_bytes() for name in TARGETS}
    assert_sync(repo)
    for name in TARGETS:
        expected = before[name]
        if kind == "agent_prompt" and name == "pgFirstAid.sql":
            expected = expected.replace(
                STAGED_PROMPT,
                STAGED_PROMPT.replace(b"END;", b"RAISE NOTICE 'updated'; END;"),
            )
        elif (
            kind == "agent_prompt"
            or (kind == "view_installer" and name != "pgFirstAid.sql")
            or (kind == "function_installer" and name == "pgFirstAid.sql")
        ):
            expected = expected.replace(original, updated)
        assert (repo / name).read_bytes() == expected
    assert run_tool(repo, "--check").returncode == 0


@pytest.mark.parametrize("name", TARGETS)
def test_manual_artifact_edit_fails_read_only_check(repo: Path, name: str) -> None:
    assert_sync(repo)
    target = repo / name
    target.write_bytes(target.read_bytes().replace(b"original prompt", b"manual edit"))
    before = snapshot(repo)
    result = run_tool(repo, "--check")
    assert result.returncode != 0
    assert name in result.stdout + result.stderr
    assert "sync_sql_helpers.py" in result.stdout + result.stderr
    assert snapshot(repo) == before
    assert_sync(repo)
    assert b"manual edit" not in target.read_bytes()


def test_canonical_helper_comments_are_embedded_inside_generated_block(
    repo: Path,
) -> None:
    comment = b"-- Explain why the helper is separate.\n"
    (repo / "data/view_installer.sql").write_bytes(comment + VIEW + b"\n")
    assert_sync(repo)
    for name in TARGETS[1:]:
        assert (
            b"-- GENERATED view_installer BEGIN\n"
            + comment
            + VIEW
            + b"\n-- GENERATED view_installer END"
        ) in (repo / name).read_bytes()
    assert run_tool(repo, "--check").returncode == 0


def test_check_reports_bootstrap_drift_without_writing(repo: Path) -> None:
    before = snapshot(repo)
    result = run_tool(repo, "--check")
    assert result.returncode != 0
    for name in TARGETS:
        assert name in result.stdout + result.stderr
    assert snapshot(repo) == before


def test_check_reports_canonical_drift_without_writing(repo: Path) -> None:
    assert_sync(repo)
    source = repo / "data/agent_prompt.sql"
    source.write_bytes(source.read_bytes().replace(b"original prompt", b"new prompt"))
    before = snapshot(repo)
    assert run_tool(repo, "--check").returncode != 0
    assert snapshot(repo) == before


def test_sync_is_idempotent_and_current_check_is_read_only(repo: Path) -> None:
    assert_sync(repo)
    before = snapshot(repo)
    assert_sync(repo)
    assert snapshot(repo) == before
    result = run_tool(repo, "--check")
    assert result.returncode == 0, result.stdout + result.stderr
    assert snapshot(repo) == before


@pytest.mark.parametrize(
    ("old", "new"),
    [
        (b"-- GENERATED view_installer END", b"-- missing end"),
        (b"-- GENERATED view_installer BEGIN", b"-- missing begin"),
        (
            b"-- GENERATED view_installer BEGIN",
            b"-- GENERATED view_installer BEGIN\n-- GENERATED view_installer BEGIN",
        ),
        (
            b"-- GENERATED view_installer END",
            b"-- GENERATED view_installer END\n-- GENERATED view_installer END",
        ),
        (
            b"-- GENERATED view_installer BEGIN",
            b"-- GENERATED view_installer BEGIN extra",
        ),
        (
            b"-- GENERATED view_installer END",
            b"  -- GENERATED view_installer END",
        ),
        (
            b"-- GENERATED view_installer END",
            b"-- GENERATED view_installer FINISH",
        ),
        (
            b"-- GENERATED view_installer END",
            b"SELECT 'do not erase';\n-- GENERATED view_installer END",
        ),
        (b"$view_install$;", b"$wrong$;"),
        (VIEW, VIEW + b"\n" + VIEW),
        (VIEW, b"SELECT 'missing helper';"),
    ],
)
@pytest.mark.parametrize("check", [False, True])
def test_invalid_last_target_never_partially_updates_files(
    repo: Path, old: bytes, new: bytes, check: bool
) -> None:
    assert_sync(repo)
    source = repo / "data/agent_prompt.sql"
    source.write_bytes(source.read_bytes().replace(b"original prompt", b"new prompt"))
    target = repo / TARGETS[-1]
    target.write_bytes(target.read_bytes().replace(old, new))
    before = snapshot(repo)
    result = run_tool(repo, *(["--check"] if check else []))
    assert result.returncode != 0
    assert target.name in result.stdout + result.stderr
    assert "view_installer" in result.stdout + result.stderr
    assert snapshot(repo) == before


@pytest.mark.parametrize(
    "invalid",
    [
        b"",
        VIEW,
        PROMPT + b"\nSELECT 'outside helper';\n",
        PROMPT + b"\n" + PROMPT,
        PROMPT.replace(b"$prompt$;", b"$wrong$;"),
        PROMPT.replace(b"AS $prompt$", b"AS $other$"),
        PROMPT.replace(b"AS $prompt$", b"AS $PROMPT$"),
        b"SELECT 'prefix';\n" + PROMPT,
        b"-- GENERATED agent_prompt BEGIN\n" + PROMPT,
    ],
)
def test_invalid_canonical_source_is_rejected_before_any_writes(
    repo: Path, invalid: bytes
) -> None:
    (repo / "data/agent_prompt.sql").write_bytes(invalid)
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert "data/agent_prompt.sql" in result.stdout + result.stderr
    assert snapshot(repo) == before


@pytest.mark.parametrize("kind", ["agent_prompt", "view_installer"])
@pytest.mark.parametrize("change", ["missing", "duplicate", "wrong_tag"])
def test_bootstrap_requires_a_unique_bounded_function(
    repo: Path, kind: str, change: str
) -> None:
    target = repo / TARGETS[-1]
    function = PROMPT if kind == "agent_prompt" else VIEW
    replacement = {
        "missing": b"SELECT 'missing helper';",
        "duplicate": function + b"\n" + function,
        "wrong_tag": function.rsplit(b"$", 1)[0] + b"_wrong$;",
    }[change]
    target.write_bytes(target.read_bytes().replace(function, replacement))
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert target.name in result.stdout + result.stderr
    assert kind in result.stdout + result.stderr
    assert snapshot(repo) == before


def test_missing_canonical_file_is_actionable_and_read_only(repo: Path) -> None:
    (repo / "data/view_installer.sql").rename(repo / "data/saved.sql")
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert "data/view_installer.sql" in result.stdout + result.stderr
    assert snapshot(repo) == before


def test_missing_last_target_is_actionable_and_read_only(repo: Path) -> None:
    (repo / TARGETS[-1]).rename(repo / "saved.sql")
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert TARGETS[-1] in result.stdout + result.stderr
    assert snapshot(repo) == before


@pytest.mark.parametrize("kind", ["agent_prompt", "view_installer"])
def test_indented_duplicate_helper_is_rejected(repo: Path, kind: str) -> None:
    target = repo / TARGETS[-1]
    function = PROMPT if kind == "agent_prompt" else VIEW
    target.write_bytes(
        target.read_bytes().replace(function, function + b"\n  " + function)
    )
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert target.name in result.stdout + result.stderr
    assert snapshot(repo) == before


def test_alias_rendering_changes_only_declaration(repo: Path) -> None:
    source = repo / "data/agent_prompt.sql"
    source.write_bytes(
        PROMPT.replace(
            b"original prompt",
            b"pgfirstaid_agent_prompt pg_temp._pgfirstaid_stage_prompt",
        )
    )
    assert_sync(repo)
    for name in TARGETS:
        rendered = (repo / name).read_bytes()
        assert (
            b"RETURN 'pgfirstaid_agent_prompt pg_temp._pgfirstaid_stage_prompt'"
        ) in rendered
        declaration = (
            b"FUNCTION pg_temp._pgfirstaid_stage_prompt("
            if name == "pgFirstAid.sql"
            else b"FUNCTION pgfirstaid_agent_prompt("
        )
        assert declaration in rendered
    assert b"FUNCTION pgfirstaid_agent_prompt(" in source.read_bytes()
    assert run_tool(repo, "--check").returncode == 0


@pytest.mark.parametrize(
    "alias",
    [
        b"pgfirstaid_agent_prompt",
        b"pg_temp.wrong_alias",
        b"public.pgfirstaid_agent_prompt",
    ],
)
def test_check_rejects_stale_or_wrong_root_alias(repo: Path, alias: bytes) -> None:
    assert_sync(repo)
    target = repo / TARGETS[0]
    target.write_bytes(
        target.read_bytes().replace(
            b"FUNCTION pg_temp._pgfirstaid_stage_prompt(", b"FUNCTION " + alias + b"("
        )
    )
    before = snapshot(repo)
    assert run_tool(repo, "--check").returncode != 0
    assert snapshot(repo) == before


def test_canonical_declaration_case_does_not_break_alias_rendering(repo: Path) -> None:
    canonical = PROMPT.replace(
        b"FUNCTION pgfirstaid_agent_prompt", b"FUNCTION\nPGFIRSTAID_AGENT_PROMPT"
    )
    (repo / "data/agent_prompt.sql").write_bytes(canonical)
    assert_sync(repo)
    assert (
        b"FUNCTION\npg_temp._pgfirstaid_stage_prompt("
        in (repo / TARGETS[0]).read_bytes()
    )
    assert run_tool(repo, "--check").returncode == 0


def test_canonical_source_cannot_use_target_alias(repo: Path) -> None:
    (repo / "data/agent_prompt.sql").write_bytes(STAGED_PROMPT)
    before = snapshot(repo)
    assert run_tool(repo).returncode != 0
    assert snapshot(repo) == before


def test_root_alias_and_original_duplicate_is_rejected(repo: Path) -> None:
    assert_sync(repo)
    target = repo / TARGETS[0]
    target.write_bytes(target.read_bytes() + b"\n" + PROMPT)
    before = snapshot(repo)
    assert run_tool(repo).returncode != 0
    assert snapshot(repo) == before


def test_malformed_marker_spacing_is_not_treated_as_bootstrap(repo: Path) -> None:
    assert_sync(repo)
    for name in TARGETS:
        target = repo / name
        target.write_bytes(target.read_bytes().replace(b"-- GENERATED", b"--GENERATED"))
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert snapshot(repo) == before


def test_reversed_markers_are_rejected_without_writes(repo: Path) -> None:
    assert_sync(repo)
    target = repo / TARGETS[-1]
    data = target.read_bytes()
    data = data.replace(b"agent_prompt BEGIN", b"agent_prompt TEMP")
    data = data.replace(b"agent_prompt END", b"agent_prompt BEGIN")
    data = data.replace(b"agent_prompt TEMP", b"agent_prompt END")
    target.write_bytes(data)
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert snapshot(repo) == before


def test_overlapping_blocks_fail_without_writes(repo: Path) -> None:
    assert_sync(repo)
    target = repo / TARGETS[-1]
    data = target.read_bytes()
    data = data.replace(b"-- GENERATED agent_prompt END", b"-- TEMP END")
    data = data.replace(
        b"-- GENERATED view_installer END",
        b"-- GENERATED agent_prompt END\n-- GENERATED view_installer END",
    )
    target.write_bytes(data)
    before = snapshot(repo)
    result = run_tool(repo)
    assert result.returncode != 0
    assert target.name in result.stdout + result.stderr
    assert snapshot(repo) == before
