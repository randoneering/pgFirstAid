# PostgreSQL Cloud SQL Module - Deploy Guide

This directory contains OpenTofu/Terraform configurations for deploying PostgreSQL instances on Google Cloud SQL using the `postgres` module. Each subdirectory (pg15, pg16, pg17, pg18) represents a deployment configuration for a specific PostgreSQL version.

## Directory Structure

```
deploy/
├── README.md           (this file)
├── pg15/              (PostgreSQL 15 deployment)
├── pg16/              (PostgreSQL 16 deployment)
├── pg17/              (PostgreSQL 17 deployment)
├── pg18/              (PostgreSQL 18 deployment)
└── state/             (Local state files)
```

## Prerequisites

- [OpenTofu](https://opentofu.org/) or Terraform installed
- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) installed and authenticated
- GCP project with Cloud SQL API enabled
- Appropriate IAM permissions to create Cloud SQL instances

### Enable Required APIs

```bash
gcloud services enable sqladmin.googleapis.com
gcloud services enable compute.googleapis.com
```

### Authenticate with GCP

```bash
gcloud auth application-default login
```

## Module Reference

The postgres module is located at `../../models/postgres` and creates:
- Google Cloud SQL PostgreSQL instance
- Initial database with specified name
- Database user with random password generation
- IP-based access control

## Quick Start

### 1. Navigate to the desired PostgreSQL version directory

```bash
cd pg15  # or pg16, pg17, pg18
```

### 2. Configure your GCP project

Edit `locals.tf` to set your GCP project and configuration:

```hcl
locals {
  project_id       = "your-gcp-project-id"      # REQUIRED: Set your GCP project ID
  region           = "us-central1"               # GCP region for the instance
  instance_name    = "pgfirstaid-pg15"          # Unique instance name
  postgres_version = "POSTGRES_15"               # PostgreSQL version
  database_name    = "pgFirstAid"                # Initial database name
  db_user          = "randoneering"              # Database user name
  personal_ip      = "YOUR.IP.ADDRESS/32"        # Replace with your IP or CIDR
}
```

**Important:** Replace `project_id` with your actual GCP project ID and `personal_ip` with your IP address for security.

### 3. Initialize OpenTofu/Terraform

```bash
tofu init
```

This downloads the required providers (Google Cloud, random) and initializes the backend.

### 4. Review the execution plan

```bash
tofu plan
```

This shows what resources will be created without making any changes.

### 5. Apply the configuration

```bash
tofu apply
```

Review the plan and type `yes` to proceed. The deployment will:
- Generate a random 20-character password (alphanumeric, no special chars)
- Create a Cloud SQL PostgreSQL instance
- Create the initial database
- Create the database user with the generated password
- Configure IP-based access control

**Note:** Cloud SQL instance creation typically takes 5-10 minutes.

## Module Configuration

### Required Variables (via locals)

The following locals are passed to the module in `main.tf`:

- `instance_name` - Unique name for the Cloud SQL instance
- `postgres_version` - PostgreSQL version (POSTGRES_15, POSTGRES_16, POSTGRES_17, POSTGRES_18)
- `region` - GCP region for deployment
- `database_name` - Name of the initial database
- `db_user` - Database user name
- `personal_ip` - IP address or CIDR range allowed to connect

### Module Defaults

The module (`../../models/postgres/main.tf`) has these default settings:

**Instance Configuration:**
- `tier` - "db-f1-micro" (smallest instance type)
- `availability_type` - "ZONAL" (single zone)
- `disk_size` - 10 GB
- `disk_type` - "PD_SSD"

**Network Configuration:**
- `ipv4_enabled` - true (public IP enabled)
- `authorized_networks` - Configured from `personal_ip` variable

**Backup Configuration:**
- `enabled` - false (backups disabled by default)
- `deletion_protection` - false (can be deleted without protection)

### Customizing the Module

To customize instance settings, you can modify the module source at `../../models/postgres/main.tf` or pass additional variables. Common customizations:


## State Management

State files are stored locally in `../state/`:
- `pg15.tfstate` for PostgreSQL 15
- `pg16.tfstate` for PostgreSQL 16
- `pg17.tfstate` for PostgreSQL 17
- `pg18.tfstate` for PostgreSQL 18

## Outputs

The module provides these outputs (accessible via `tofu output`):

- `instance_name` - Name of the Cloud SQL instance
- `instance_connection_name` - Connection name for Cloud SQL Proxy (format: project:region:instance)
- `public_ip_address` - Public IP address of the instance
- `database_name` - Name of the created database
- `db_user` - Database user name

## Destroying Resources

To delete the Cloud SQL instance:

```bash
tofu destroy
```

## Module Source

Module location: `../../models/postgres/`

Key files:
- `main.tf` - Resource definitions (Cloud SQL instance, database, user)
- `variables.tf` - Input variable definitions with validation
- `outputs.tf` - Output value definitions
