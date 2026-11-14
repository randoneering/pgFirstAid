from __future__ import annotations

import os
import subprocess
from pathlib import Path
from typing import Any

import pytest
import yaml

ROOT = Path(__file__).resolve().parents[1]


def workflow(name: str) -> dict[str, Any]:
    return yaml.safe_load((ROOT / ".github" / "workflows" / name).read_text())


@pytest.fixture
def command_environment(tmp_path: Path) -> dict[str, str]:
    for command in ("uv", "psql"):
        path = tmp_path / command
        path.write_text(
            "#!/usr/bin/env bash\nset -euo pipefail\n"
            f"printf '%s\\n' '{command.upper()}' \"$@\"\n"
        )
        path.chmod(0o755)
    env = os.environ.copy()
    env["PATH"] = str(tmp_path) + os.pathsep + env["PATH"]
    return env


@pytest.mark.parametrize("allow", [False, True])
def test_local_installer_routes_legacy_upgrades_only_when_enabled(
    command_environment: dict[str, str],
    allow: bool,
) -> None:
    env = command_environment.copy()
    env.update(
        PGFA_TEST_ALLOW_LEGACY_UPGRADE="1" if allow else "0",
        REPO_ROOT=str(ROOT),
        PGHOST="ci-host",
        PGPORT="5432",
        PGUSER="ci-user",
        PGDATABASE="ci-database",
    )
    result = subprocess.run(
        [
            "bash",
            "-c",
            (
                'PSQL=(psql); source "$REPO_ROOT/testing/local-workflows/'
                'install_pgfirstaid.sh"; install_pgfirstaid_for_test'
            ),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    arguments = result.stdout.splitlines()
    if allow:
        assert arguments[0] == "UV"
        assert "--allow-legacy-upgrade" in arguments
        assert str(ROOT / "testing" / "ci_install.py") in arguments
        assert "PSQL" not in arguments
    else:
        assert arguments == ["PSQL", "-f", str(ROOT / "pgFirstAid.sql")]


def test_long_lived_database_jobs_explicitly_enable_ci_upgrades() -> None:
    for name, job in [
        ("nixos-local-test.yml", "local-test"),
        ("neon-integration-pg-matrix.yml", "integration"),
    ]:
        definition = workflow(name)["jobs"][job]
        assert definition["env"]["PGFA_TEST_ALLOW_LEGACY_UPGRADE"] == "1"
        assert "head.repo.full_name == github.repository" in definition["if"]


def test_neon_installer_passes_explicit_opt_in() -> None:
    steps = workflow("neon-integration-pg-matrix.yml")["jobs"]["integration"]["steps"]
    install = next(
        step for step in steps if step.get("name") == "Install pgFirstAid function"
    )
    assert "ci_install.py --allow-legacy-upgrade" in install["run"]


def test_cloned_branch_installer_upgrades_before_installing_views(
    command_environment: dict[str, str],
) -> None:
    steps = workflow("neon-before-after-validate.yml")["jobs"][
        "before-after-validation"
    ]["steps"]
    install = next(
        step for step in steps if step.get("name") == "Install pgFirstAid on branch"
    )
    env = command_environment.copy()
    env["DB_URL"] = "synthetic-ci-dsn"
    result = subprocess.run(
        ["bash", "-euo", "pipefail", "-c", install["run"]],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    arguments = result.stdout.splitlines()
    assert arguments[0] == "UV"
    boundary = arguments.index("PSQL")
    assert "--allow-legacy-upgrade" in arguments[:boundary]
    dsn_option = arguments.index("--dsn-env")
    assert arguments[dsn_option + 1] == "DB_URL"
    assert "synthetic-ci-dsn" not in arguments[:boundary]
    assert "\\i pgFirstAid.sql" not in install["run"]
