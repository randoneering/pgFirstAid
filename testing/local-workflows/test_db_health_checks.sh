#!/usr/bin/env bash
# test_db_health_checks.sh
#
# Replicates the db-health-checks.yml GitHub Actions workflow locally.
# Installs pgFirstAid, runs the full health check with severity
# breakdowns, and exports CSV + JSON reports.
#
# Usage:
#   export PGHOST=... PGPORT=... PGUSER=... PGPASSWORD=... PGDATABASE=...
#   ./test_db_health_checks.sh
#
# All connection parameters default to localhost / pgfirstaid.
# You can also source a .env file before running.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORTS_DIR="$(dirname "${BASH_SOURCE[0]}")/reports"
PREFIX="[health-check]"

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
        echo "$PREFIX ERROR: $tool not found. Install postgresql-client."
        exit 1
    fi
done

mkdir -p "$REPORTS_DIR"

# ---- 1. Install pgFirstAid ----
echo "$PREFIX Installing pgFirstAid..."
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
"${PSQL[@]}" -f "${REPO_ROOT}/pgFirstAid.sql"
"${PSQL[@]}" -f "${REPO_ROOT}/view_pgFirstAid.sql"
"${PSQL[@]}" -f "${REPO_ROOT}/view_pgFirstAid_managed.sql"
echo "$PREFIX pgFirstAid installed."

# ---- 2. Validate installation ----
echo "$PREFIX Validating pg_firstAid() function..."
"${PSQL[@]}" -c "SELECT pg_firstAid();" > /dev/null
echo "$PREFIX Function responds OK."

# ---- 3. Full health check with severity breakdown ----
echo ""
echo "=============================================="
echo "    DATABASE HEALTH CHECK REPORT"
echo "=============================================="
echo ""

"${PSQL[@]}" <<'EOF'
CREATE TEMP TABLE _health_snapshot AS SELECT * FROM pg_firstAid();

\echo '=== CRITICAL Issues (Must Fix) ==='
SELECT severity, check_name, object_name, issue_description, recommended_action, documentation_link
FROM _health_snapshot
WHERE severity = 'CRITICAL'
ORDER BY check_name;
\echo ''

\echo '=== HIGH Priority Issues (Should Fix) ==='
SELECT severity, check_name, object_name, issue_description, recommended_action
FROM _health_snapshot
WHERE severity = 'HIGH'
ORDER BY check_name;
\echo ''

\echo '=== MEDIUM Priority Issues (Monitor) ==='
SELECT severity, check_name, object_name, issue_description, recommended_action
FROM _health_snapshot
WHERE severity = 'MEDIUM'
ORDER BY check_name;
\echo ''

\echo '=== LOW Priority Issues (Nice to Have) ==='
SELECT severity, check_name, object_name, issue_description
FROM _health_snapshot
WHERE severity = 'LOW'
ORDER BY check_name;
\echo ''

\echo '=== INFO (General Information) ==='
SELECT severity, check_name, object_name
FROM _health_snapshot
WHERE severity = 'INFO'
ORDER BY check_name;
\echo ''

\echo '============================================'
\echo '    SUMMARY STATISTICS'
\echo '============================================'
\echo ''
SELECT
  severity,
  COUNT(*) as issue_count,
  COUNT(DISTINCT object_name) as affected_objects
FROM _health_snapshot
GROUP BY severity
ORDER BY
  CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    WHEN 'LOW' THEN 4
    ELSE 5
  END;
EOF

# ---- 4. CSV export ----
echo "$PREFIX Exporting CSV report..."
"${PSQL[@]}" \
    -c "CREATE TEMP TABLE _health_snapshot AS SELECT * FROM pg_firstAid();" \
    -c "\copy (SELECT * FROM _health_snapshot ORDER BY severity, check_name) TO '${REPORTS_DIR}/full_health_check.csv' CSV HEADER"
echo "$PREFIX CSV report -> ${REPORTS_DIR}/full_health_check.csv"

# ---- 5. JSON export ----
echo "$PREFIX Exporting JSON report..."
"${PSQL[@]}" \
    -c "CREATE TEMP TABLE _health_snapshot AS SELECT * FROM pg_firstAid();" \
    -c "\copy (SELECT json_agg(to_json(d)) FROM _health_snapshot d) TO '${REPORTS_DIR}/full_health_check.json'"
echo "$PREFIX JSON report -> ${REPORTS_DIR}/full_health_check.json"

# ---- 6. Summary ----
echo ""
echo "$PREFIX Done. Reports saved to ${REPORTS_DIR}/"
echo "  CSV:  ${REPORTS_DIR}/full_health_check.csv"
echo "  JSON: ${REPORTS_DIR}/full_health_check.json"
echo ""
echo "To compare with a previous baseline run, see test_pre_post_migration.sh"
