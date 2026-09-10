import re
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).parent.parent
WORKFLOW_DIR = REPO_ROOT / ".github" / "workflows"


PRIVILEGED_WORKFLOWS = (
    "neon-before-after-validate.yml",
    "neon-integration-pg-matrix.yml",
    "nixos-local-test.yml",
)
GUARDED_JOB = re.compile(
    r"(?ms)^  [A-Za-z0-9_-]+:\n"
    r"(?:(?!^  [A-Za-z0-9_-]+:).)*?"
    r"^    if: >-\n"
    r"      github\.event_name != 'pull_request_target' \|\|\n"
    r"      github\.event\.pull_request\.head\.repo\.full_name == github\.repository\n"
    r"(?:(?!^  [A-Za-z0-9_-]+:).)*?"
    r"^    runs-on:",
)


SETUP_UV_USES = (
    "astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9"
)
UV_VERSION_VALUE = "0.12.9"
UV_CHECKSUM_VALUE = (
    "ec7a99cd05e0cd7f80243f135ce1361c76835cb0ee60055d14d20eba8eba1460"
)
GUARD_FETCH_FILES = (
    "pr-safe-checks.yml",
    "pr-workflow-guard.yml",
    "neon-before-after-validate.yml",
    "neon-integration-pg-matrix.yml",
    "nixos-local-test.yml",
    "pgdg-cve-scraper.yml",
    "release-notes-scout.yml",
)


def _parse_install_uv_steps(workflow: str) -> list[dict]:
    document = yaml.safe_load(workflow)
    jobs = document.get("jobs") or {}
    steps = []
    for job in jobs.values():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if isinstance(step, dict) and step.get("name") == "Install uv":
                steps.append(step)
    return steps


def _assert_pinned_uv_install(workflow: str) -> None:
    # Whole-file negatives: a differently named step cannot reintroduce curl|sh.
    assert "curl -LsSf https://astral.sh/uv/install.sh | sh" not in workflow
    assert 'echo "$HOME/.local/bin" >> "$GITHUB_PATH"' not in workflow

    # Parser-based: bind every positive assertion to exactly one Install uv step.
    install_steps = _parse_install_uv_steps(workflow)
    assert len(install_steps) == 1, (
        f"expected exactly one 'Install uv' step, found {len(install_steps)}"
    )
    step = install_steps[0]
    assert step.get("uses") == SETUP_UV_USES, step.get("uses")
    assert "run" not in step, "Install uv step must not also have a run: block"
    with_keys = step.get("with") or {}
    assert with_keys.get("version") == UV_VERSION_VALUE
    assert with_keys.get("checksum") == UV_CHECKSUM_VALUE
    assert with_keys.get("enable-cache") is True

    # No second action entry that uses astral-sh/setup-uv under a different name.
    document = yaml.safe_load(workflow)
    extra_setup_uv = []
    for job in (document.get("jobs") or {}).values():
        if not isinstance(job, dict):
            continue
        for step in job.get("steps") or []:
            if not isinstance(step, dict):
                continue
            uses = step.get("uses")
            if not (isinstance(uses, str) and uses.startswith("astral-sh/setup-uv@")):
                continue
            if step.get("name") == "Install uv":
                continue
            extra_setup_uv.append(step)
    assert extra_setup_uv == [], extra_setup_uv


def test_secret_backed_pr_jobs_skip_forks_before_runner_selection():
    for workflow_name in PRIVILEGED_WORKFLOWS:
        workflow = (WORKFLOW_DIR / workflow_name).read_text()
        assert re.search(r"(?m)^  pull_request_target:\s*$", workflow)
        assert re.search(r"(?m)^  workflow_dispatch:\s*$", workflow)
        assert GUARDED_JOB.search(workflow), (
            f"{workflow_name} must guard its job before runs-on"
        )
        assert "persist-credentials: false" in workflow
        assert "github.event.pull_request.head.sha || github.ref" in workflow


def test_distributed_neon_template_uses_guarded_pull_request_target():
    template = (REPO_ROOT / "workflows" / "neon-before-after-validate.yml").read_text()
    assert re.search(r"(?m)^  pull_request_target:\s*$", template)
    assert re.search(r"(?m)^  workflow_dispatch:\s*$", template)
    assert GUARDED_JOB.search(template)
    assert "github.event.pull_request.head.sha || github.ref" in template
    assert "persist-credentials: false" in template
    assert "api_key: ${{ secrets.NEON_API_KEY }}" in template


def test_pr_safe_checks_is_hosted_and_secret_free():
    workflow = (WORKFLOW_DIR / "pr-safe-checks.yml").read_text()
    document = yaml.safe_load(workflow)

    assert "name: PR Safe Checks" in workflow
    assert re.search(r"(?m)^  pull_request:\s*$", workflow)
    assert re.search(r"(?m)^    types: \[opened, synchronize, reopened\]\s*$", workflow)
    assert "paths:" not in workflow
    assert re.search(r"(?m)^    runs-on: ubuntu-latest\s*$", workflow)
    assert "permissions:\n  contents: read" in workflow
    assert "write" not in workflow
    assert "self-hosted" not in workflow
    assert "secrets." not in workflow
    assert "NEON_API_KEY" not in workflow
    assert "pull_request_target" not in workflow
    assert "workflow_run" not in workflow
    assert "persist-credentials: false" in workflow
    assert "ref: ${{ github.event.pull_request.head.sha }}" in workflow
    assert (
        "actions/setup-python@f677139bbe7f9c59b41e40162b753c062f5d49a3"
        in workflow
    )
    assert "python-version: \"3.11\"" in workflow
    assert "uv sync --frozen" in workflow
    assert "testing/test_workflow_security.py" in workflow
    assert "test_every_health_check_has_pgtap_coverage" in workflow
    assert "test_both_view_sql_files_cover_all_health_checks" in workflow
    assert "test_expected_check_groups_cover_all_defined_checks" not in workflow

    # Parser-based: assert pr-safe-checks uses the pinned setup-uv on its actual step.
    install_steps = _parse_install_uv_steps(workflow)
    assert len(install_steps) == 1
    assert install_steps[0].get("uses") == SETUP_UV_USES

    # Sanity: pull_request_target trigger is absent; this job must not receive secrets.
    on_section = document.get(True) or document.get("on") or {}
    assert "pull_request_target" not in on_section


def test_release_drafter_uses_hosted_runner():
    workflow = (WORKFLOW_DIR / "release-drafter.yml").read_text()
    assert re.search(r"(?m)^    runs-on: ubuntu-latest\s*$", workflow)
    assert "self-hosted" not in workflow


def test_pr_workflow_guard_is_trusted_base_only():
    workflow = (WORKFLOW_DIR / "pr-workflow-guard.yml").read_text()
    document = yaml.safe_load(workflow)

    assert "name: Workflow Security Guard" in workflow
    assert re.search(r"(?m)^  pull_request_target:\s*$", workflow)
    assert re.search(r"(?m)^    types: \[opened, synchronize, reopened\]\s*$", workflow)
    assert "permissions:\n  contents: read" in workflow
    assert re.search(r"(?m)^    runs-on: ubuntu-latest\s*$", workflow)
    assert re.search(
        r"(?m)^    name: Workflow Security Guard\s*$", workflow
    )
    assert "self-hosted" not in workflow
    assert "secrets." not in workflow
    assert "workflow_run" not in workflow
    assert "persist-credentials: false" in workflow

    # Guard must checkout base, not the PR head.
    assert "ref: ${{ github.event.pull_request.head.sha }}" not in workflow
    # Guard must fetch PR files via the API as data, not by checking out PR head.
    assert "gh api" in workflow
    assert "repos/${HEAD_REPO}/contents/" in workflow
    # Guard must run the trusted verifier, not PR-supplied code.
    assert "uv run pytest -q testing/test_workflow_security.py" in workflow
    # Guard must never copy PR Python or other test sources from the fetch result.
    assert "cp /tmp/pr-workflows/*.py" not in workflow
    assert "cp -r /tmp/pr-workflows/." not in workflow
    assert "rsync -a /tmp/pr-workflows" not in workflow

    # Parser-based: guard's Install uv step is pinned.
    install_steps = _parse_install_uv_steps(workflow)
    assert len(install_steps) == 1
    assert install_steps[0].get("uses") == SETUP_UV_USES

    # Guard trigger must be pull_request_target (Trusted context).
    on_section = document.get(True) or document.get("on") or {}
    assert "pull_request_target" in on_section


def test_pr_workflow_guard_fetches_scraper_workflows():
    # The two scraper workflows grant contents: write + pull-requests: write.
    # The trusted guard must fetch them so the verifier evaluates the PR version,
    # not the base-branch copy.
    workflow = (WORKFLOW_DIR / "pr-workflow-guard.yml").read_text()
    fetch_step = workflow.split("Fetch PR workflow files as data", 1)[1].split(
        "\n      - name:", 1
    )[0]

    for name in GUARD_FETCH_FILES:
        assert name in fetch_step, (
            f"Workflow Security Guard must fetch {name} from the PR head"
        )


def test_pr_workflow_guard_overlay_replaces_yaml_only():
    workflow = (WORKFLOW_DIR / "pr-workflow-guard.yml").read_text()
    # The overlay step must copy YAML only. No .py, no testing/*, no pgTAP, no seed.
    overlay_run = workflow.split("Overlay PR YAML for verifier", 1)[1].split(
        "run: |\n", 1
    )[1].split("\n      - name:", 1)[0]
    assert ".py" not in overlay_run
    assert ".sql" not in overlay_run
    assert "testing/" not in overlay_run
    assert "pgTAP" not in overlay_run
    assert "seed" not in overlay_run
    assert "cp /tmp/pr-workflows/*.yml .github/workflows/" in workflow
    assert (
        "cp /tmp/pr-distributed/neon-before-after-validate.yml workflows/neon-before-after-validate.yml"
        in workflow
    )


def test_pr_safe_checks_no_longer_pipes_curl_to_sh():
    workflow = (WORKFLOW_DIR / "pr-safe-checks.yml").read_text()
    assert "curl -LsSf https://astral.sh/uv/install.sh | sh" not in workflow
    assert 'echo "$HOME/.local/bin" >> "$GITHUB_PATH"' not in workflow


def test_pgdg_cve_scraper_uses_pinned_uv():
    _assert_pinned_uv_install(
        (WORKFLOW_DIR / "pgdg-cve-scraper.yml").read_text()
    )


def test_release_notes_scout_uses_pinned_uv():
    _assert_pinned_uv_install(
        (WORKFLOW_DIR / "release-notes-scout.yml").read_text()
    )
