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
    assert "curl -LsSf https://astral.sh/uv/install.sh | sh" in workflow
    assert 'echo "$HOME/.local/bin" >> "$GITHUB_PATH"' in workflow
    assert "uv sync --frozen" in workflow
    assert "testing/test_workflow_security.py" in workflow
    assert "test_every_health_check_has_pgtap_coverage" in workflow
    assert "test_both_view_sql_files_cover_all_health_checks" in workflow
    assert "test_expected_check_groups_cover_all_defined_checks" not in workflow


def test_release_drafter_uses_hosted_runner():
    workflow = (WORKFLOW_DIR / "release-drafter.yml").read_text()
    assert re.search(r"(?m)^    runs-on: ubuntu-latest\s*$", workflow)
    assert "self-hosted" not in workflow
