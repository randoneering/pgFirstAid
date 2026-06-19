#!/usr/bin/env bash
# test_neon_before_after.sh
#
# Uses Neon's instant database branching to run before/after health checks
# on an isolated copy of your data. Detects regressions from any change
# that affects query behavior on the target database:
#
#   - SQL migrations (schema changes, index additions)
#   - Application code deploys (new ORM queries, join patterns)
#   - Infrastructure changes (connection pools, work_mem, PGBouncer)
#   - Configuration changes (timeouts, statement timeouts)
#
# This is the local equivalent of .github/workflows/neon-before-after-validate.yml.
#
# Prerequisites:
#   neonctl CLI -- npm install -g neonctl  OR  brew install neonctl
#   NEON_API_KEY -- export NEON_API_KEY=...

# Usage:
#   export NEON_API_KEY=... NEON_PROJECT_ID=...
#   ./test_neon_before_after.sh [--role-name ROLE] [--database-name DB]
#
# Optional env vars:
#   NEON_BRANCH_NAME          - branch name (default: auto-generated)
#   NEON_PARENT_BRANCH        - parent branch to clone (default: project default)
#   NEON_ROLE_NAME            - role for connection string (default: auto-detect)
#   NEON_DATABASE_NAME        - database for connection string (default: pgFirstAid)
#   CHANGE_DIR                - directory with .sql change files (default: auto)
#   PGFIRSTAID_FAIL_SEVERITY  - CRITICAL | HIGH | MEDIUM | LOW | NONE (default: HIGH)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PREFIX="[neon-beforeafter]"

NEON_API_KEY="${NEON_API_KEY:-}"
NEON_PROJECT_ID="${NEON_PROJECT_ID:-}"
NEON_BRANCH_NAME="${NEON_BRANCH_NAME:-pgfa-beforeafter-$(date +%s)}"
NEON_PARENT_BRANCH="${NEON_PARENT_BRANCH:-}"
NEON_ROLE_NAME="${NEON_ROLE_NAME:-}"
NEON_DATABASE_NAME="${NEON_DATABASE_NAME:-pgFirstAid}"
CHANGE_DIR="${CHANGE_DIR:-}"
PGFIRSTAID_FAIL_SEVERITY="${PGFIRSTAID_FAIL_SEVERITY:-HIGH}"

# ---- CLI arg parsing ----
while [[ $# -gt 0 ]]; do
    case "$1" in
        --role-name)
            NEON_ROLE_NAME="$2"
            shift 2
            ;;
        --database-name)
            NEON_DATABASE_NAME="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [--role-name ROLE] [--database-name DB]"
            echo ""
            echo "Env vars: NEON_API_KEY (req), NEON_PROJECT_ID (req), NEON_ROLE_NAME, NEON_DATABASE_NAME, NEON_BRANCH_NAME, NEON_PARENT_BRANCH, CHANGE_DIR, PGFIRSTAID_FAIL_SEVERITY"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# ---- 0. Pre-flight ----
for tool in psql neonctl; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$PREFIX ERROR: $tool not found."
        echo "  Install psql: apt install postgresql-client"
        echo "  Install neonctl: npm install -g neonctl"
        exit 1
    fi
done

if [ -z "$NEON_API_KEY" ]; then
    echo "$PREFIX ERROR: NEON_API_KEY is required."
    echo "  export NEON_API_KEY=..."
    echo "  Get one at https://console.neon.tech/app/settings/api-keys"
    exit 1
fi

if [ -z "$NEON_PROJECT_ID" ]; then
    echo "$PREFIX ERROR: NEON_PROJECT_ID is required."
    echo "  export NEON_PROJECT_ID=..."
    echo "  Find it in your Neon project Settings page."
    exit 1
fi

# ---- 1. Create Neon branch ----
echo "$PREFIX Creating branch '$NEON_BRANCH_NAME'..."
BRANCH_ARGS=(
    --project-id "$NEON_PROJECT_ID"
    --name "$NEON_BRANCH_NAME"
    --output json
)
if [ -n "$NEON_PARENT_BRANCH" ]; then
    BRANCH_ARGS+=(--parent "$NEON_PARENT_BRANCH")
fi

BRANCH_OUTPUT=$(neonctl branches create "${BRANCH_ARGS[@]}")
BRANCH_ID=$(echo "$BRANCH_OUTPUT" | python3 -c "import sys,json; print(json.load(sys.stdin)['branch']['id'])")
echo "$PREFIX Branch ID: $BRANCH_ID"

_cleanup() {
    echo ""
    echo "$PREFIX Cleaning up -- deleting branch '$NEON_BRANCH_NAME'..."
    neonctl branches delete "$BRANCH_ID" --project-id "$NEON_PROJECT_ID" 2>/dev/null || true
    echo "$PREFIX Branch deleted."
}
trap _cleanup EXIT

# ---- 2. Get connection string ----
echo "$PREFIX Getting connection string..."
ROLE_ARG=""
if [ -n "$NEON_ROLE_NAME" ]; then
    ROLE_ARG="--role-name $NEON_ROLE_NAME"
fi
DB_URL=$(neonctl connection-string "$NEON_BRANCH_NAME" \
    --project-id "$NEON_PROJECT_ID" \
    --database-name "$NEON_DATABASE_NAME" \
    $ROLE_ARG)
echo "$PREFIX Connecting to branch..."

# Wait for compute to be ready (Neon cold-start can take a moment)
echo "$PREFIX Waiting for compute to be ready..."
for i in $(seq 1 15); do
    if psql "$DB_URL" -c "SELECT 1" >/dev/null 2>&1; then
        echo "$PREFIX Compute ready."
        break
    fi
    if [ "$i" -eq 15 ]; then
        echo "$PREFIX ERROR: Compute did not become ready within 15s."
        exit 1
    fi
    sleep 2
done

# ---- 3. Install pgFirstAid ----
echo "$PREFIX Installing pgFirstAid on branch..."
psql "$DB_URL" -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
psql "$DB_URL" -v ON_ERROR_STOP=1 -f "${REPO_ROOT}/pgFirstAid.sql"
psql "$DB_URL" -v ON_ERROR_STOP=1 -f "${REPO_ROOT}/view_pgFirstAid.sql"
psql "$DB_URL" -v ON_ERROR_STOP=1 -f "${REPO_ROOT}/view_pgFirstAid_managed.sql"
echo "$PREFIX pgFirstAid installed."

# ---- 4. Pre-change baseline ----
echo ""
echo "=============================================="
echo "    PRE-CHANGE HEALTH BASELINE"
echo "=============================================="
echo ""

psql "$DB_URL" -v ON_ERROR_STOP=1 <<'EOF'
CREATE UNLOGGED TABLE _pre_change_snapshot AS SELECT * FROM pg_firstAid();

\echo 'Severity Summary:'
SELECT severity, COUNT(*) as issue_count
FROM _pre_change_snapshot
GROUP BY severity
ORDER BY
  CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    WHEN 'LOW' THEN 4
    ELSE 5
  END;
\echo ''
\echo 'Critical & High Issues:'
SELECT severity, check_name, object_name, issue_description
FROM _pre_change_snapshot
WHERE severity IN ('CRITICAL', 'HIGH')
ORDER BY severity, check_name;
EOF

BASELINE_CRITICAL=$(psql "$DB_URL" -t -c "SELECT count(*) FROM _pre_change_snapshot WHERE severity = 'CRITICAL';" | tr -d '[:space:]')
echo "$PREFIX Baseline critical issues: $BASELINE_CRITICAL"

# ---- 5. BEFORE / AFTER BOUNDARY -- Apply changes here ----
echo ""
echo "=============================================="
echo "    BEFORE / AFTER BOUNDARY"
echo "=============================================="
echo ""
echo "  Pre-change baseline captured above."
echo "  Apply your change (migration SQL, app config, etc.)"
echo "  on this branch before the post-change comparison."
echo ""

CHANGE_FILES=""
if [ -n "$CHANGE_DIR" ]; then
    CHANGE_FILES=$(find "$CHANGE_DIR" -name '*.sql' -type f | sort || true)
fi

if [ -z "$CHANGE_FILES" ]; then
    if [ -d "${REPO_ROOT}/migrations" ]; then
        CHANGE_FILES=$(find "${REPO_ROOT}/migrations" -name '*.sql' -type f | sort || true)
    fi
fi

if [ -n "$CHANGE_FILES" ]; then
    echo "$PREFIX Applying SQL change files:"
    while IFS= read -r f; do
        echo "  $f"
        psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"
    done <<< "$CHANGE_FILES"
    echo "$PREFIX Changes applied."
else
    echo "  No .sql change files found in CHANGE_DIR or REPO_ROOT/migrations/."
    echo ""
    echo "  Apply your change manually in another terminal. Examples:"
    echo ""
    echo "    # SQL migration:"
    echo "    psql \"$DB_URL\" -f /path/to/your/migration.sql"
    echo ""
    echo "    # Run app test suite against this branch URL:"
    echo "    export DATABASE_URL=\"$DB_URL\""
    echo "    ./run_tests.sh"
    echo ""
    echo "  When ready, press Enter to run the post-change"
    echo "  health comparison."
    echo ""
    read -r -p "  Press Enter after applying your changes to continue... "
fi

# ---- 6. Post-change comparison ----
echo ""
echo "=============================================="
echo "    POST-CHANGE HEALTH"
echo "=============================================="
echo ""

psql "$DB_URL" -v ON_ERROR_STOP=1 <<'EOF'
CREATE TEMP TABLE _post_change_snapshot AS SELECT * FROM pg_firstAid();

\echo 'Severity Summary:'
SELECT severity, COUNT(*) as issue_count
FROM _post_change_snapshot
GROUP BY severity
ORDER BY
  CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    WHEN 'LOW' THEN 4
    ELSE 5
  END;
\echo ''
\echo 'New Issues Since Baseline:'
SELECT severity, check_name, object_name, issue_description, recommended_action
FROM _post_change_snapshot
WHERE (check_name, object_name) NOT IN (
  SELECT check_name, object_name FROM _pre_change_snapshot
)
ORDER BY severity, check_name;
EOF

# ---- 7. Gate check ----
echo ""
echo "=============================================="
echo "    GATE CHECK"
echo "=============================================="
echo ""

CURRENT_CRITICAL=$(psql "$DB_URL" -t -c "SELECT count(*) FROM pg_firstAid() WHERE severity = 'CRITICAL';" | tr -d '[:space:]')

echo "  Baseline critical: $BASELINE_CRITICAL"
echo "  Current critical:  $CURRENT_CRITICAL"

if [ "$CURRENT_CRITICAL" -gt "$BASELINE_CRITICAL" ]; then
    NEW_CRITICAL=$((CURRENT_CRITICAL - BASELINE_CRITICAL))
    echo ""
    echo "  BLOCKED: Change introduces $NEW_CRITICAL new critical issue(s)!"
    echo ""
    echo "  New critical findings:"
    psql "$DB_URL" -v ON_ERROR_STOP=1 <<'EOF'
    SELECT check_name, object_name, issue_description
    FROM pg_firstAid()
    WHERE severity = 'CRITICAL'
    AND (check_name, object_name) NOT IN (
        SELECT check_name, object_name FROM _pre_change_snapshot
    );
EOF
    exit 1
else
    echo ""
    echo "  PASSED: No new critical issues. Safe to deploy."
    exit 0
fi
