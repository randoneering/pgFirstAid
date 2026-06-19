#!/usr/bin/env bash
# test_pre_post_migration.sh
#
# Replicates the pre-post-migration-validate.yml workflow locally.
#
# Flow:
#   1. Pre-migration baseline — install pgFirstAid, snapshot health
#   2. Apply test migrations — create a PK-less table + duplicate index
#   3. Post-migration validation — compare health against baseline
#   4. Critical issue count comparison — exit 1 if new CRITICALs appear
#   5. Cleanup — drop test objects
#
# The test migrations are realistic schema changes that should trigger
# "Missing Primary Key" and "Duplicate Index" health checks.
#
# Usage:
#   export PGHOST=... PGPORT=... PGUSER=... PGPASSWORD=... PGDATABASE=...
#   ./test_pre_post_migration.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORTS_DIR="$(dirname "${BASH_SOURCE[0]}")/reports"
PREFIX="[migration]"

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
_cleanup_passfile() { rm -f "$PGPASSFILE"; }
trap _cleanup_passfile EXIT

PSQL=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1)

# Schema we'll create and then drop
TEST_SCHEMA="pgfirstaid_migration_test"

mkdir -p "$REPORTS_DIR"

# ---- 1. Pre-migration baseline ----
echo "$PREFIX === Step 1/5: Pre-migration baseline ==="

# Install pgFirstAid
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
"${PSQL[@]}" -c "DROP FUNCTION IF EXISTS pg_firstAid()"
"${PSQL[@]}" -f "${REPO_ROOT}/pgFirstAid.sql"

# Capture baseline (single session — temp tables die with the connection)
"${PSQL[@]}" <<EOF
-- Use unlogged table so baseline data survives across psql sessions
DROP TABLE IF EXISTS _pre_health_snapshot;
CREATE UNLOGGED TABLE _pre_health_snapshot AS SELECT * FROM pg_firstAid();

\echo '=== Pre-Migration Health Baseline ==='
\echo ''
\echo 'Severity Summary:'
SELECT severity, COUNT(*) as issue_count
FROM _pre_health_snapshot
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
\echo 'Critical Issues (blocking):'
SELECT severity, check_name, object_name, issue_description
FROM _pre_health_snapshot
WHERE severity = 'CRITICAL'
ORDER BY check_name;
\echo ''
\echo 'High Priority Issues:'
SELECT severity, check_name, object_name, issue_description
FROM _pre_health_snapshot
WHERE severity = 'HIGH'
ORDER BY check_name;

-- Export baseline counts to files
\copy (SELECT severity, COUNT(*)::int AS count FROM _pre_health_snapshot GROUP BY severity ORDER BY 1) TO '${REPORTS_DIR}/baseline_severity.csv' CSV HEADER
\copy (SELECT count(*) FROM _pre_health_snapshot WHERE severity = 'CRITICAL') TO '${REPORTS_DIR}/baseline_critical_count.txt'
EOF

BASELINE_CRITICAL=$(cat "$REPORTS_DIR/baseline_critical_count.txt" | tr -d '[:space:]')
echo "$PREFIX Baseline: $BASELINE_CRITICAL critical issues."

# ---- 2. Apply test migrations ----
echo ""
echo "$PREFIX === Step 2/5: Applying test migrations ==="

# These are realistic schema changes that pgFirstAid should flag:
#   - A table without a primary key (triggers "Missing Primary Key")
#   - A duplicate index (triggers "Duplicate Index")
"${PSQL[@]}" <<EOF
CREATE SCHEMA IF NOT EXISTS ${TEST_SCHEMA};

-- Table without a primary key (triggers "Missing Primary Key")
CREATE TABLE ${TEST_SCHEMA}.orders_no_pk (
    id          integer,
    customer_id integer,
    amount      numeric(10,2),
    created_at  timestamptz default now()
);

-- Duplicate index on the same columns (triggers "Duplicate Index")
CREATE TABLE ${TEST_SCHEMA}.inventory (
    id         integer PRIMARY KEY,
    sku        text NOT NULL,
    quantity   integer DEFAULT 0
);
CREATE INDEX idx_inventory_sku ON ${TEST_SCHEMA}.inventory (sku);
CREATE INDEX idx_inventory_sku_dup ON ${TEST_SCHEMA}.inventory (sku);

-- Insert some rows so the table is not empty and stats get generated
INSERT INTO ${TEST_SCHEMA}.orders_no_pk (id, customer_id, amount)
SELECT g, g % 100, random() * 1000
FROM generate_series(1, 1000) g;

INSERT INTO ${TEST_SCHEMA}.inventory (id, sku, quantity)
SELECT g, 'SKU-' || g, g % 50
FROM generate_series(1, 100) g;

-- Update stats so pgFirstAid picks up the schema
ANALYZE ${TEST_SCHEMA}.orders_no_pk;
ANALYZE ${TEST_SCHEMA}.inventory;
EOF

echo "$PREFIX Test migrations applied:"
echo "  - Created ${TEST_SCHEMA}.orders_no_pk (no primary key)"
echo "  - Created ${TEST_SCHEMA}.inventory with duplicate index"

# ---- 3. Post-migration validation ----
echo ""
echo "$PREFIX === Step 3/5: Post-migration validation ==="

# Re-install in case pgFirstAid.sql was updated during migration step
"${PSQL[@]}" -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements"
"${PSQL[@]}" -c "DROP FUNCTION IF EXISTS pg_firstAid()"
"${PSQL[@]}" -f "${REPO_ROOT}/pgFirstAid.sql"

"${PSQL[@]}" <<EOF
CREATE TEMP TABLE _health_snapshot AS SELECT * FROM pg_firstAid();

\echo '=== Post-Migration Health Report ==='
\echo ''
\echo 'Severity Summary:'
SELECT severity, COUNT(*) as issue_count
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
\echo ''
\echo 'All Issues (ordered by priority):'
SELECT severity, check_name, object_name, issue_description, recommended_action
FROM _health_snapshot
ORDER BY
  CASE severity
    WHEN 'CRITICAL' THEN 1
    WHEN 'HIGH' THEN 2
    WHEN 'MEDIUM' THEN 3
    WHEN 'LOW' THEN 4
    ELSE 5
  END,
  check_name;
\echo ''
\echo 'New Issues (compared to baseline):'
SELECT severity, check_name, object_name, issue_description, recommended_action
FROM _health_snapshot
WHERE (check_name, object_name) NOT IN (
    SELECT check_name, object_name FROM _pre_health_snapshot
)
ORDER BY severity, check_name;
EOF

# ---- 4. Compare critical issue count ----
echo ""
echo "$PREFIX === Step 4/5: Critical issue comparison ==="

CURRENT_CRITICAL=$("${PSQL[@]}" -t \
    -c "SELECT count(*) FROM pg_firstAid() WHERE severity = 'CRITICAL';" \
    | tr -d '[:space:]')

echo "$PREFIX Baseline critical: $BASELINE_CRITICAL"
echo "$PREFIX Current critical:  $CURRENT_CRITICAL"

if [ "$CURRENT_CRITICAL" -gt "$BASELINE_CRITICAL" ]; then
    NEW_CRITICAL=$((CURRENT_CRITICAL - BASELINE_CRITICAL))
    echo ""
    echo "$PREFIX ERROR: Migration introduced $NEW_CRITICAL new critical issues!"
    echo "  Baseline: $BASELINE_CRITICAL | Current: $CURRENT_CRITICAL"
    echo ""
    echo "New critical findings:"
    "${PSQL[@]}" <<'EOF'
    SELECT check_name, object_name, issue_description
    FROM pg_firstAid()
    WHERE severity = 'CRITICAL'
    AND (check_name, object_name) NOT IN (
        SELECT check_name, object_name FROM _pre_health_snapshot
    );
EOF
    HAS_NEW_CRITICAL=1
else
    echo "$PREFIX No new critical issues introduced. ✓"
    HAS_NEW_CRITICAL=0
fi

# Check for HIGH issues (warn-only in CI; replicated here for completeness)
CURRENT_HIGH=$("${PSQL[@]}" -t \
    -c "SELECT count(*) FROM pg_firstAid() WHERE severity = 'HIGH';" \
    | tr -d '[:space:]')
if [ "$CURRENT_HIGH" -gt 0 ]; then
    echo "$PREFIX Found $CURRENT_HIGH high priority issues (non-blocking)."
fi

# Save post-migration reports
"${PSQL[@]}" --csv \
    -c "SELECT severity, COUNT(*)::int AS count FROM pg_firstAid() GROUP BY severity ORDER BY 1;" \
    > "$REPORTS_DIR/post_migration_severity.csv"
"${PSQL[@]}" --csv \
    -c "SELECT severity, check_name, object_name, issue_description, recommended_action FROM pg_firstAid() ORDER BY severity, check_name;" \
    > "$REPORTS_DIR/post_migration_health.csv"
echo "$PREFIX Post-migration reports saved to ${REPORTS_DIR}/"

# ---- 5. Cleanup ----
echo ""
echo "$PREFIX === Step 5/5: Cleanup ==="

"${PSQL[@]}" <<EOF
DROP SCHEMA IF EXISTS ${TEST_SCHEMA} CASCADE;
DROP TABLE IF EXISTS _pre_health_snapshot;
EOF
echo "$PREFIX Test schema ${TEST_SCHEMA} dropped."

# ---- Final verdict ----
echo ""
echo "=============================================="
echo "    MIGRATION VALIDATION SUMMARY"
echo "=============================================="
echo ""
echo "Baseline vs Post-Migration:"
echo "  Critical: $BASELINE_CRITICAL → $CURRENT_CRITICAL"
echo "  High:     (baseline not saved separately) → $CURRENT_HIGH"
echo ""

if [ "$HAS_NEW_CRITICAL" -eq 1 ]; then
    echo "STATUS: BLOCKED — New critical issues detected."
    echo ""
    echo "This matches the behavior of pre-post-migration-validate.yml:"
    echo "new CRITICAL findings block the deployment gate."
    exit 1
else
    echo "STATUS: PASSED — No new critical issues. Safe to deploy."
    exit 0
fi
