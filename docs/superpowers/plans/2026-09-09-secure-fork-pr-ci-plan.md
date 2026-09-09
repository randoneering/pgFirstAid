# Secure Fork PR Validation Implementation Plan

**Goal:** Guard privileged pull-request workflows before runner assignment while retaining owner-operated validation and an always-on safe check for fork pull requests.

**Spec:** `docs/superpowers/specs/2026-09-09-secure-fork-pr-ci-design.md`

## Scope and constraints

- Change only workflow YAML, workflow-security regression coverage, and this security design/plan documentation.
- Do not edit SQL files, pgTAP files, seed expectations, or `docs/health-checks/README.md`.
- Keep PR #44's `Unread Large Constraint-Backing Index`, pgTAP, seed, and health-check documentation work in PR #44 or a later follow-up.
- Do not change repository settings, rulesets, or dispatch behavior.
- Keep `workflow_dispatch` on all privileged database workflows.

## Implementation steps

### 1. Update regression coverage first

Update `testing/test_workflow_security.py` to verify:

- The three live secret-backed workflows use `pull_request_target` and `workflow_dispatch`.
- Each privileged job has the exact base-controlled repository guard before `runs-on`:

  ```yaml
  if: >-
    github.event_name != 'pull_request_target' ||
    github.event.pull_request.head.repo.full_name == github.repository
  ```

- Privileged checkouts use the reviewed head SHA with a `github.ref` fallback and `persist-credentials: false`.
- The distributed Neon template has the same trigger, guard, checkout behavior, and no fork execution path.
- `PR Safe Checks` remains plain `pull_request`, hosted, secret-free, and runs only the workflow-security test and the two pure SQL coverage tests.
- `release-drafter.yml` uses `ubuntu-latest` and not the persistent self-hosted runner.

Run the workflow-security test at this point and record its expected red result before implementation.

### 2. Guard the three live privileged workflows

In:

- `.github/workflows/neon-before-after-validate.yml`
- `.github/workflows/neon-integration-pg-matrix.yml`
- `.github/workflows/nixos-local-test.yml`

Change the automatic trigger to `pull_request_target`, preserve `workflow_dispatch`, and put the exact guard under the job before `runs-on`. Retain reviewed-head checkout behavior, add the `github.ref` fallback where needed, and keep `persist-credentials: false`. Replace stale comments about empty-secret failures with the statement that fork PRs skip the privileged job before runner assignment.

### 3. Guard the distributed Neon template

In `workflows/neon-before-after-validate.yml`, apply the same guarded `pull_request_target` and `workflow_dispatch` pattern. Use the reviewed head SHA with a dispatch fallback and `persist-credentials: false`. Keep the Neon secret only for trusted execution; the base-workflow guard must be false for fork heads before the job can run SQL or receive the secret.

### 4. Make safe and release workflows hosted appropriately

- Change `.github/workflows/release-drafter.yml` to `runs-on: ubuntu-latest`.
- Remove `testing/test_seed_and_validate.py::test_expected_check_groups_cover_all_defined_checks` from `.github/workflows/pr-safe-checks.yml` and from the workflow-security test's command assertions.
- Keep the workflow-security test and the two file-only SQL coverage tests in the safe workflow.

### 5. Update design documentation

Update the spec and this plan to describe guarded `pull_request_target`, the base-controlled fork boundary, the hosted release-drafter runner, and the reduced safe-check command. Explicitly state that PR #44's constraint-index, pgTAP, seed, and health-check documentation items are out of scope and belong to PR #44 or a later follow-up.

### 6. Validate and commit

Run:

```bash
uv run pytest -q testing/test_workflow_security.py
uv run pytest -q \
  testing/integration/tests/integration/test_pgtap_suite.py::test_every_health_check_has_pgtap_coverage \
  testing/integration/tests/integration/test_pgtap_suite.py::test_both_view_sql_files_cover_all_health_checks
git diff --check
git status --short --branch
```

Review the diff to confirm no SQL, pgTAP, seed, health-check README, repository settings, or PR #44 files changed. Commit the completed fix round locally on `fix/secure-fork-pr-ci`.
