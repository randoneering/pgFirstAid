# Workflow Notes

This repo keeps `managed-db-validate.yml` as a reusable validation workflow.

`managed-db-validate.yml` installs `pgFirstAid.sql`, recreates `view_pgFirstAid_managed.sql`, and runs integration tests, including the pgTAP-backed checks in the integration harness.

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
