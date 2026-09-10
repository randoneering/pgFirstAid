import re
from pathlib import Path


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

    assert "name: PR Safe Checks" in workflow
    assert "pull_request:" in workflow
    assert "types: [opened, synchronize, reopened]" in workflow
    assert "paths:" not in workflow
    assert "runs-on: ubuntu-latest" in workflow
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


def test_release_drafter_uses_hosted_runner():
    workflow = (WORKFLOW_DIR / "release-drafter.yml").read_text()
    assert re.search(r"(?m)^    runs-on: ubuntu-latest\s*$", workflow)
    assert "self-hosted" not in workflow


def test_pr_workflow_guard_is_trusted_base_only():
    workflow = (WORKFLOW_DIR / "pr-workflow-guard.yml").read_text()

    assert "name: Workflow Security Guard" in workflow
    assert re.search(r"(?m)^  pull_request_target:\s*$", workflow)
    assert re.search(r"(?m)^    types: \[opened, synchronize, reopened\]\s*$", workflow)
    assert "permissions:\n  contents: read" in workflow
    assert "runs-on: ubuntu-latest" in workflow
    assert re.search(
        r"(?m)^    name: Workflow Security Guard\s*$", workflow
    )
    assert "self-hosted" not in workflow
    assert "secrets." not in workflow
    assert "workflow_run" not in workflow
    assert "astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9" in workflow
    assert "version: \"0.12.9\"" in workflow
    assert (
        "checksum: \"ec7a99cd05e0cd7f80243f135ce1361c76835cb0ee60055d14d20eba8eba1460\""
        in workflow
    )
    assert "enable-cache: true" in workflow
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
    assert "astral-sh/setup-uv@c771a70e6277c0a99b617c7a806ffedaca235ff9" in workflow
    assert "version: \"0.12.9\"" in workflow
    assert (
        "checksum: \"ec7a99cd05e0cd7f80243f135ce1361c76835cb0ee60055d14d20eba8eba1460\""
        in workflow
    )
    assert "enable-cache: true" in workflow
