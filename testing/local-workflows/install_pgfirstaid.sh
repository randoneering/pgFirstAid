#!/usr/bin/env bash
set -euo pipefail

pgfirstaid_test_psql() {
    local -a arguments=("$@")
    local has_action=0
    while (( $# > 0 )); do
        case "$1" in
            -c|-f|--command|--file|-c?*|-f?*|--command=*|--file=*)
                has_action=1
                break
                ;;
            -h|-p|-U|-d|-v|-P|-o|-L|--host|--port|--username|--dbname|--set|--variable|--pset|--output|--log-file)
                if (( $# < 2 )); then break; fi
                shift 2
                ;;
            --) break ;;
            *) shift ;;
        esac
    done
    # Transaction pooling must keep temporary snapshots with their later SELECTs.
    if (( has_action )); then
        command psql --single-transaction "${arguments[@]}"
    else
        command psql --single-transaction --file=- "${arguments[@]}"
    fi
}

install_pgfirstaid_for_test() {
    if [[ "${PGFA_TEST_ALLOW_LEGACY_UPGRADE:-0}" == "1" ]]; then
        PGHOST="$PGHOST" PGPORT="$PGPORT" PGUSER="$PGUSER" PGDATABASE="$PGDATABASE" \
            uv run --project "$REPO_ROOT" python \
            "$REPO_ROOT/testing/ci_install.py" --allow-legacy-upgrade
    else
        "${PSQL[@]}" -f "$REPO_ROOT/pgFirstAid.sql"
    fi
}
