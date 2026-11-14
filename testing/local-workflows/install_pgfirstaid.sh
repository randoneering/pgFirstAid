#!/usr/bin/env bash
set -euo pipefail

install_pgfirstaid_for_test() {
    if [[ "${PGFA_TEST_ALLOW_LEGACY_UPGRADE:-0}" == "1" ]]; then
        PGHOST="$PGHOST" PGPORT="$PGPORT" PGUSER="$PGUSER" PGDATABASE="$PGDATABASE" \
            uv run --project "$REPO_ROOT" python \
            "$REPO_ROOT/testing/ci_install.py" --allow-legacy-upgrade
    else
        "${PSQL[@]}" -f "$REPO_ROOT/pgFirstAid.sql"
    fi
}
