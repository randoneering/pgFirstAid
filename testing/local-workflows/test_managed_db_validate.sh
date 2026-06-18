#!/usr/bin/env bash
# test_managed_db_validate.sh
#
# Replicates the SQL validation portion of managed-db-validate.yml locally.
# Cloud auth steps (AWS CLI, gcloud, az) are not replicated — this script
# runs the same pgFirstAid SQL against whatever database you point it at.
#
# Usage:
#   export PGHOST=... PGPORT=... PGUSER=... PGPASSWORD=... PGDATABASE=...
#   CLOUD_PROVIDER=aws ./test_managed_db_validate.sh
#
# CLOUD_PROVIDER is optional — it only labels the output (aws/gcp/azure/direct).
# Defaults to "direct".

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORTS_DIR="$(dirname "${BASH_SOURCE[0]}")/reports"
PREFIX="[managed-validate]"

CLOUD_PROVIDER="${CLOUD_PROVIDER:-direct}"

# ---- Config with defaults ----
PGHOST="${PGHOST:-localhost}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-pgfirstaid}"
PGPASSWORD="${PGPASSWORD:-pgfirstaid}"
PGDATABASE="${PGDATABASE:-pgfirstaid}"
PGSSLMODE="${PGSSLMODE:-require}"
PGPASSFILE="$(mktemp)"
export PGPASSFILE PGSSLMODE

echo "${PGHOST}:${PGPORT}:${PGDATABASE}:${PGUSER}:${PGPASSWORD}" > "$PGPASSFILE"
chmod 600 "$PGPASSFILE"
_cleanup() { rm -f "$PGPASSFILE"; }
trap _cleanup EXIT

PSQL=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1)

# ---- 0. Verify tools ----
for tool in psql; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$PREFIX ERROR: $tool not found."
        exit 1
    fi
done

mkdir -p "$REPORTS_DIR"

# ---- 1. Install pgFirstAid ----
echo "$PREFIX [$CLOUD_PROVIDER] Installing pgFirstAid function + managed view..."
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
"${PSQL[@]}" -f "${REPO_ROOT}/pgFirstAid.sql"
"${PSQL[@]}" -f "${REPO_ROOT}/view_pgFirstAid_managed.sql"
echo "$PREFIX [$CLOUD_PROVIDER] pgFirstAid installed."

# ---- 2. Verify installation ----
"${PSQL[@]}" -c "SELECT pg_firstAid();" > /dev/null
echo "$PREFIX [$CLOUD_PROVIDER] Function responds OK."

# ---- 3. Run health check ----
echo ""
echo "=============================================="
echo "    $CLOUD_PROVIDER Health Check"
echo "    Host: $PGHOST:$PGPORT"
echo "=============================================="
echo ""

"${PSQL[@]}" <<'EOF'
CREATE TEMP TABLE _snap AS SELECT * FROM pg_firstAid();

\echo '=== Severity Summary ==='
SELECT
  severity,
  COUNT(*) as issue_count,
  COUNT(DISTINCT object_name) as affected_objects
FROM _snap
GROUP BY severity
ORDER BY
  CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    ELSE 4
  END;
\echo ''

\echo '=== Critical Issues ==='
SELECT severity, check_name, object_name, issue_description, recommended_action
FROM _snap
WHERE severity = 'CRITICAL'
ORDER BY check_name;
\echo ''

\echo '=== High Priority Issues ==='
SELECT severity, check_name, object_name, issue_description
FROM _snap
WHERE severity = 'HIGH'
ORDER BY check_name;
\echo ''
EOF

# ---- 4. CSV export via \copy ----
CSV_PATH="${REPORTS_DIR}/${CLOUD_PROVIDER}_health_check.csv"
echo "$PREFIX [$CLOUD_PROVIDER] Exporting CSV report..."
"${PSQL[@]}" \
    -c "\copy (SELECT * FROM pg_firstAid() ORDER BY severity, check_name) TO '${CSV_PATH}' CSV HEADER"
echo "$PREFIX [$CLOUD_PROVIDER] Report -> ${CSV_PATH}"

# ---- 5. Summary ----
echo ""
echo "=============================================="
echo "    $CLOUD_PROVIDER Validation Complete"
echo "    Host: $PGHOST:$PGPORT"
echo "    Report: ${CSV_PATH}"
echo "=============================================="
