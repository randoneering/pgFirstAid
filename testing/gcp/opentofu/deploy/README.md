# PostgreSQL Test Instances

OpenTofu module for creating short-lived PostgreSQL instances on GCP Cloud SQL free tier.

## Features

- Creates 4 PostgreSQL instances (versions 15, 16, 17, 18)
- Free tier configuration (db-f1-micro, 10GB storage)
- Publicly accessible (0.0.0.0/0 authorized)
- No backups (short-lived testing)
- No deletion protection

## Prerequisites

- GCP project with Cloud SQL API enabled
- OpenTofu/Terraform installed
- GCP credentials configured (`gcloud auth application-default login`)

## Usage

1. Initialize and apply:
```bash
tofu init
tofu plan
tofu apply
```

2. Get connection details:
```bash
tofu output postgres_15_ip
tofu output -raw postgres_15_connection
```

3. Cleanup when done:
```bash
tofu destroy
```


## Cost Warning

Free tier caps:
- db-f1-micro shared-core instance
- 30GB storage max
- 250GB egress per month

Multiple instances count toward quota. Monitor usage in GCP console.

## Security Note

Public access (0.0.0.0/0) is intentional for testing but should **never** be used in production. Use strong passwords and destroy instances immediately after testing.
