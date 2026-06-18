#!/usr/bin/env bash
# test_pr_audit.sh
#
# Replicates the pgfirstaid-pr-audit.yml workflow locally.
# Runs the pgfirstaid_audit.py Python script via uv against the
# target database, mirroring the CI PR audit step.
#
# The script fetches pgFirstAid.sql from GitHub, connects to the
# database, runs the full audit, and prints a markdown summary.
# Exits non-zero when findings meet or exceed the configured
# severity threshold (PGFIRSTAID_FAIL_SEVERITY).
#
# Usage:
#   export DATABASE_URL=postgresql://user:pass@host:5432/dbname
#   ./test_pr_audit.sh
#
# Optional env vars:
#   PGFIRSTAID_VERSION       - git ref (default: main)
#   PGFIRSTAID_FAIL_SEVERITY - CRITICAL | HIGH | MEDIUM | LOW | NONE (default: HIGH)
#
# Without a PR_NUMBER, the script prints results to stdout instead of
# posting a GitHub PR comment — exactly like workflow_dispatch runs.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="[pr-audit]"

# ---- Config ----
DATABASE_URL="${DATABASE_URL:-}"
PGFIRSTAID_VERSION="${PGFIRSTAID_VERSION:-main}"
PGFIRSTAID_FAIL_SEVERITY="${PGFIRSTAID_FAIL_SEVERITY:-HIGH}"

# ---- 0. Pre-flight checks ----
if [ -z "$DATABASE_URL" ]; then
    echo "$PREFIX ERROR: DATABASE_URL is required."
    echo ""
    echo "  export DATABASE_URL=postgresql://user:pass@host:5432/dbname"
    echo ""
    echo "  You can also build it from component env vars:"
    echo ""
    echo '  DATABASE_URL="postgresql://${PGUSER}:${PGPASSWORD}@${PGHOST}:${PGPORT}/${PGDATABASE}"'
    exit 1
fi

if ! command -v uv >/dev/null 2>&1; then
    echo "$PREFIX ERROR: uv not found. Install from https://docs.astral.sh/uv/"
    exit 1
fi

# ---- 1. Install Python dependencies ----
echo "$PREFIX Installing psycopg2-binary via uv..."
uv sync 2>/dev/null || true
uv pip install --quiet psycopg2-binary 2>/dev/null || uv pip install psycopg2-binary

# ---- 2. Run the audit script ----
echo "$PREFIX Running pgFirstAid audit..."
echo "$PREFIX   version=$PGFIRSTAID_VERSION  fail=$PGFIRSTAID_FAIL_SEVERITY"
echo ""

# The audit script requires GITHUB_TOKEN and GITHUB_REPOSITORY even for
# local runs (validate_config checks them). Set dummy values — they are
# only used for the GitHub API call, which is skipped when PR_NUMBER is
# empty (the "workflow_dispatch" path in the script).
EXIT_CODE=0
DATABASE_URL="$DATABASE_URL" \
GITHUB_TOKEN="local-dev-dummy" \
GITHUB_REPOSITORY="pgfirstaid/pgfirstaid" \
PR_NUMBER="" \
PGFIRSTAID_VERSION="$PGFIRSTAID_VERSION" \
PGFIRSTAID_FAIL_SEVERITY="$PGFIRSTAID_FAIL_SEVERITY" \
    uv run python "${REPO_ROOT}/workflows/pgfirstaid_audit.py" || EXIT_CODE=$?

# ---- 3. Report ----
echo ""
if [ "$EXIT_CODE" -ne 0 ]; then
    echo "$PREFIX Audit failed with exit code $EXIT_CODE."
    echo "  Findings at or above PGFIRSTAID_FAIL_SEVERITY=$PGFIRSTAID_FAIL_SEVERITY were found."
    exit "$EXIT_CODE"
fi

echo "$PREFIX Audit passed. No findings at or above the $PGFIRSTAID_FAIL_SEVERITY threshold."
