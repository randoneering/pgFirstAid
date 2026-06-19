SHELL := bash

# pgFirstAid Local Test Workflows
#
# Usage:
#   make setup          - copy .env.example -> .env (never overwrites)
#   make test-health    - run health check suite
#   make test-managed   - run managed DB validation
#   make test-migration - run pre/post migration validation
#   make test-audit     - run PR audit script
#   make test-neon      - run Neon branching before/after validation
#   make test-all       - run all four standard suites sequentially
#   make test-all-pg15  - run all four standard suites against PG_VERSION=15
#   make clean          - remove reports/

# Load .env if present (silently skip if missing)
ifneq (,$(wildcard .env))
    include .env
    export
endif

# --- Default connection (override via .env or env vars) ---
PGHOST      ?= localhost
PGPORT      ?= 5432
PGUSER      ?= pgfirstaid
PGPASSWORD  ?= pgfirstaid
PGDATABASE  ?= pgfirstaid
PGSSLMODE   ?= require
DATABASE_URL ?= postgresql://$(PGUSER):$(PGPASSWORD)@$(PGHOST):$(PGPORT)/$(PGDATABASE)
CLOUD_PROVIDER ?= direct

# --- Check required tools ---
TOOLS := psql uv
$(foreach tool,$(TOOLS),\
    $(if $(shell command -v $(tool) 2>/dev/null),,\
        $(error $(tool) is required but not found in PATH)))

setup:
	@test -f .env || cp .env.example .env
	@echo "Created .env from .env.example — edit then run make test-*"

test-health:
	@echo "=== Health Check Suite ==="
	./test_db_health_checks.sh

test-managed:
	@echo "=== Managed DB Validation ==="
	CLOUD_PROVIDER=$(CLOUD_PROVIDER) ./test_managed_db_validate.sh

test-migration:
	@echo "=== Pre/Post Migration Validation ==="
	./test_pre_post_migration.sh

test-audit:
	@echo "=== PR Audit ==="
	DATABASE_URL=$(DATABASE_URL) ./test_pr_audit.sh

test-neon:
	@echo "=== Neon Before/After Validation ==="
	@test -n "$(NEON_API_KEY)" || { echo "NEON_API_KEY not set"; exit 1; }
	@test -n "$(NEON_PROJECT_ID)" || { echo "NEON_PROJECT_ID not set"; exit 1; }
	NEON_ROLE_NAME=$(NEON_ROLE_NAME) NEON_DATABASE_NAME=$(NEON_DATABASE_NAME) \
		./test_neon_before_after.sh

test-all: test-health test-managed test-migration test-audit
	@echo ""
	@echo "=== All test suites completed ==="

# Convenience: run against a specific PG version using secrets-style naming
#   PG_VERSION=15 make test-all-pg
test-all-pg:
	PGHOST=$(PGHOST) PGPORT=$(PGPORT) PGUSER=$(PGUSER) \
	PGPASSWORD=$(PGPASSWORD) PGDATABASE=$(PGDATABASE) \
	DATABASE_URL=postgresql://$(PGUSER):$(PGPASSWORD)@$(PGHOST):$(PGPORT)/$(PGDATABASE) \
	$(MAKE) test-all

clean:
	rm -rf reports/
	rm -f baseline_severity.csv baseline_critical_count.txt
	rm -f current_health_check.csv full_health_check.csv full_health_check.json
	rm -f post_migration_severity.csv post_migration_health.csv
	rm -f comparison-report.md

.PHONY: setup test-health test-managed test-migration test-audit test-all test-all-pg clean
