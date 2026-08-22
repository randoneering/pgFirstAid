# Workflow Notes

## PR-driven: `neon-integration-pg-matrix.yml`

Runs the full pgFirstAid validation suite against long-lived Neon projects
on every PR open and push. Matrix covers PG15-18 in parallel on the
self-hosted NixOS runner. Installs `pg_stat_statements`, then
`pgFirstAid.sql` + `view_pgFirstAid_managed.sql`, runs the pytest
integration suite, and finishes with `seed_and_validate.py --managed`.

Required secrets (one set per PG version):
`PG{15,16,17,18}_{HOST,PORT,USER,PASSWORD,DATABASE}`.

## Reusable: `managed-db-validate.yml`

`managed-db-validate.yml` installs `pgFirstAid.sql`, recreates `view_pgFirstAid_managed.sql`, runs integration tests including the pgTAP-backed checks, and then runs `testing/seed_and_validate.py --managed` against the same target.

## Supported connection modes

- `direct`: caller passes `pg_host`
- `aws`: resolves host from `aws_db_identifier`
- `gcp`: resolves host from `gcp_project_id` and `gcp_instance_name`

## Required inputs and secrets

Connection details depend on the selected connection mode. The reusable workflow always requires:

- `pg_user`
- `pg_database`
- `pg_password`

Provider-specific auth is optional and only needed when the workflow resolves the host automatically.

## Secret handling

- Passwords are passed through workflow inputs and masked by GitHub Actions
- Avoid printing secret values in custom debug statements
