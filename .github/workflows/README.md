# Manual Cloud Deploy Workflows

This repo uses three manual deployment workflows and one reusable validation workflow:

- `deploy-aws-rds.yml`
- `deploy-gcp-postgres.yml`
- `azure-postgres-opentofu.yml`
- `managed-db-validate.yml` (reusable via `workflow_call`)

Deploy workflows are run manually from the Actions tab.

AWS and GCP also support trusted PR comment triggers:

- AWS: `/deploy-aws-rds [target|command] [command]`
- GCP: `/deploy-gcp-pg [target|command] [command]`

## Deploy Inputs

AWS and GCP workflows support `target` (`pg15`-`pg18` or `all`) and `command` (`plan`, `apply`, `destroy`).

Azure workflow supports:

- `action`: `plan`, `apply`, `destroy`
- `postgres_version`: `pg15`, `pg16`, `pg17`, `pg18`
- `personal_ip`: optional (falls back to secret)

## Secrets

### AWS

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_ALLOWED_CIDR_BLOCK`
- `AWS_DB_PASSWORD`

### GCP

- `GCP_SA_KEY`
- `DEPLOY_PERSONAL_IP_CIDR` (unless provided as workflow input)
- `GCP_DB_PASSWORD`

### Azure

- OIDC: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
  - or service principal JSON: `AZURE_CREDENTIALS`
- `AZURE_PERSONAL_IP` (unless provided as workflow input)
- `AZURE_DB_PASSWORD`

### Shared deploy controls

- `DEPLOY_TRIGGER_USER` (used by AWS/GCP manual and comment-triggered deploy checks)

## Validation Workflow

`managed-db-validate.yml` installs `pgFirstAid.sql`, recreates `view_pgFirstAid_managed.sql`, and runs integration tests (including pgTAP coverage through the integration test harness).

It supports three connection modes:

- `direct`: caller passes `pg_host`
- `aws`: resolves host from `aws_db_identifier`
- `gcp`: resolves host from `gcp_project_id` + `gcp_instance_name`

Current wiring:

- Azure apply calls `managed-db-validate.yml` automatically after deploy.
- AWS apply calls `managed-db-validate.yml` for each selected version after deploy.
- GCP apply calls `managed-db-validate.yml` for each selected version after deploy.

## Secret Handling

- DB passwords are passed to OpenTofu as `TF_VAR_db_password`.
- Password variables in the OpenTofu stacks are marked `sensitive = true`.
- Workflows use step-level environment variables and masking for secret values used in shell steps.
- Avoid printing secret values in custom debug statements.

## Recommended Run Order

1. Run `plan`
2. Run `apply`
3. Confirm validation results
4. Run `destroy` when done with test resources
