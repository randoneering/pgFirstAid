#!/usr/bin/env bash
#
# run_tests.sh - Execute pgFirstAid pgTAP test suite
#
# Usage:
#   ./run_tests.sh [-h host] [-p port] [-U user] [-d database]
#
# Examples:
#   ./run_tests.sh                              # Use defaults (local socket)
#   ./run_tests.sh -d pgfirstaid_test           # Specify database
#   ./run_tests.sh -h localhost -p 5432 -U postgres -d testdb

set -euo pipefail

# Setup logging
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/run_$(date +%Y%m%d_%H%M%S).log"

# Redirect all output to both console and log file
exec > >(tee -a "$LOG_FILE")
exec 2>&1

echo "Logging to: $LOG_FILE"
echo ""

# Default connection parameters
DB_HOST="10.10.1.236"
DB_PORT="5432"
DB_USER="randoneering"
DB_NAME="pgFirstAid"

# Parse command line arguments
while getopts "h:p:U:d:" opt; do
    case $opt in
        h) DB_HOST="$OPTARG" ;;
        p) DB_PORT="$OPTARG" ;;
        U) DB_USER="$OPTARG" ;;
        d) DB_NAME="$OPTARG" ;;
        *) echo "Usage: $0 [-h host] [-p port] [-U user] [-d database]" >&2
           exit 1 ;;
    esac
done

# Build psql connection arguments
PSQL_ARGS=()
[[ -n "$DB_HOST" ]] && PSQL_ARGS+=("-h" "$DB_HOST")
[[ -n "$DB_PORT" ]] && PSQL_ARGS+=("-p" "$DB_PORT")
[[ -n "$DB_USER" ]] && PSQL_ARGS+=("-U" "$DB_USER")
[[ -n "$DB_NAME" ]] && PSQL_ARGS+=("-d" "$DB_NAME")

# Track results
TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

echo "============================================"
echo "  pgFirstAid pgTAP Test Suite"
echo "============================================"
echo ""

# Run setup first (not a test file, runs outside transaction)
echo "Running setup..."
if ! psql "${PSQL_ARGS[@]}" -f "$SCRIPT_DIR/00_setup.sql" 2>&1; then
    echo "FATAL: Setup failed. Ensure pgFirstAid function and view are loaded."
    echo "  psql ${PSQL_ARGS[*]} -f pgFirstAid.sql"
    echo "  psql ${PSQL_ARGS[*]} -f view_pgFirstAid.sql"
    exit 1
fi
echo ""

# Run each test file in order
for test_file in "$SCRIPT_DIR"/0[1-9]_*.sql; do
    filename=$(basename "$test_file")
    echo "--------------------------------------------"
    echo "Running: $filename"
    echo "--------------------------------------------"

    # Capture output and check for failures
    output=$(psql "${PSQL_ARGS[@]}" -f "$test_file" 2>&1) || true
    echo "$output"

    # Count pass/fail from TAP output
    # TAP output has leading space before "ok" and "not ok"
    pass_count=$(echo "$output" | grep -c '^ ok [0-9]' || true)
    fail_count=$(echo "$output" | grep -c '^ not ok [0-9]' || true)

    TOTAL_PASS=$((TOTAL_PASS + pass_count))
    TOTAL_FAIL=$((TOTAL_FAIL + fail_count))

    if [[ $fail_count -gt 0 ]]; then
        FAILED_FILES+=("$filename")
    fi

    echo ""
done

# Run teardown
echo "Running teardown..."
psql "${PSQL_ARGS[@]}" -f "$SCRIPT_DIR/99_teardown.sql" 2>&1
echo ""

# Summary
echo "============================================"
echo "  Test Results Summary"
echo "============================================"
echo "  Passed: $TOTAL_PASS"
echo "  Failed: $TOTAL_FAIL"
echo "  Total:  $((TOTAL_PASS + TOTAL_FAIL))"
echo ""

if [[ $TOTAL_FAIL -gt 0 ]]; then
    echo "  FAILED FILES:"
    for f in "${FAILED_FILES[@]}"; do
        echo "    - $f"
    done
    echo ""
    echo "  RESULT: FAIL"
    echo ""
    echo "Full log saved to: $LOG_FILE"
    exit 1
else
    echo "  RESULT: PASS"
    echo ""
    echo "Full log saved to: $LOG_FILE"
    exit 0
fi
