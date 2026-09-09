# Secure Fork PR Validation Design

## Goal

Keep pull-request validation available to fork contributors without allowing fork-controlled code to access repository database credentials, `NEON_API_KEY`, or persistent self-hosted runners.

## Current problem

The live secret-backed database workflows run on persistent self-hosted runners and previously used `pull_request` with empty-secret validation inside the job. A fork job could therefore be assigned a persistent runner before that validation failed. The distributed Neon template also needs the same explicit trust boundary.

## Design

1. The three live secret-backed workflows and the distributed Neon template use `pull_request_target` plus `workflow_dispatch`.
2. Each privileged job has this base-controlled guard before `runs-on`:

   ```yaml
   if: >-
     github.event_name != 'pull_request_target' ||
     github.event.pull_request.head.repo.full_name == github.repository
   ```

   Fork pull requests therefore skip the job before runner assignment. Manual dispatch remains available for owner-operated validation, and same-repository pull requests remain eligible.
3. Privileged checkouts use the reviewed pull-request head SHA, with `github.ref` as the dispatch fallback, and set `persist-credentials: false`. The guarded jobs are the only workflows that consume database or Neon secrets.
4. `PR Safe Checks` remains a secret-free plain `pull_request` workflow on `ubuntu-latest`. It checks out the PR head without persisted credentials and runs workflow-security plus the two pure SQL coverage contracts.
5. `release-drafter.yml` runs on `ubuntu-latest`; its pull-request event does not require Nix or a persistent runner.

## Trust boundaries

A fork pull request can run only the secret-free hosted checks. Its privileged jobs evaluate false in the base workflow before runner selection, so fork SQL is not checked out or executed and `NEON_API_KEY` is not exposed to fork execution. Trusted database validation runs only for same-repository pull requests or an explicit owner-triggered dispatch.

The distributed Neon template retains its Neon secret references for trusted execution, but its base-workflow guard is false for fork heads. No workflow uses `workflow_run` to check out a fork commit with secrets.

## Status checks

The safe workflow reports a stable advisory check without changing repository rulesets. Its test command includes the workflow-security test and the two file-only SQL coverage tests. The pre-existing failing static seed expectation test is intentionally not part of this security PR's safe-check command; it remains outside this branch's scope.

## Out of scope

PR #44's `Unread Large Constraint-Backing Index` check, pgTAP assertions, seed expectations, and health-check documentation are not part of this separate security PR. Those items belong to PR #44 or a later follow-up. This branch does not edit SQL, pgTAP, seed expectations, or `docs/health-checks/README.md`.

## Validation

- `testing/test_workflow_security.py` verifies guarded `pull_request_target` jobs, reviewed-head checkouts, the secret-free plain `pull_request` workflow, and the hosted release-drafter runner.
- The two pure SQL coverage tests run without a database.
- `git diff --check` and workflow inspection verify whitespace and scope.

## Rejected alternatives

- Do not use an unguarded `pull_request_target` job for privileged workflows.
- Do not retain empty-secret validation as the fork safety boundary.
- Do not run fork-controlled code on persistent self-hosted runners.
- Do not add a `workflow_run` follower that checks out a fork commit and runs it with secrets.
- Do not alter repository settings or mix PR #44's health-check contract changes into this security PR.
