# PostgreSQL RDS Non-Aurora Module - Deploy Guide

This directory contains OpenTofu/Terraform configurations for deploying PostgreSQL RDS instances using the `nonaurora` module. Each subdirectory (pg15, pg16, pg17, pg18) represents a deployment configuration for a specific PostgreSQL version.

## Directory Structure

```
deploy/
├── README.md           (this file)
├── pg15/              (PostgreSQL 15.x deployment)
├── pg16/              (PostgreSQL 16.x deployment)
├── pg17/              (PostgreSQL 17.x deployment)
├── pg18/              (PostgreSQL 18.x deployment)
└── state/             (Local state files)
```

## Prerequisites

- [OpenTofu](https://opentofu.org/) or Terraform installed
- AWS credentials configured (via `aws configure` or environment variables)
- Appropriate AWS IAM permissions to create RDS instances

## Module Reference

The nonaurora module is located at `../../opentofu/modules/nonaurora` and creates:
- AWS RDS PostgreSQL instance
- Custom parameter group with configurable parameters
- Random password generation for the master user
- CloudWatch log exports for PostgreSQL logs

## Quick Start

### 1. Navigate to the desired PostgreSQL version directory

```bash
cd pg15  # or pg16, pg17, pg18
```

### 2. Review and customize the configuration

Edit `locals.tf` to customize your deployment:

```hcl
locals {
  service             = "pg15"                    # Service/instance identifier
  database_name       = "pgFirstAid"              # Initial database name
  engine              = "postgres"                # Database engine
  engine_version      = "15.12"                   # PostgreSQL version
  engine_family       = "postgres15"              # Parameter group family
  db_parameter_group  = [                         # Custom parameters
    {
      name         = "autovacuum"
      value        = "1"
      apply_method = "immediate"
    },
    # Add more parameters as needed
  ]
}
```

### 3. Initialize OpenTofu/Terraform

```bash
tofu init
```

This downloads the required providers (AWS, random, null) and initializes the backend.

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
- Create a parameter group with your custom parameters
- Launch the RDS instance with the specified configuration

### 6. Retrieve the endpoint

After successful deployment, the RDS endpoint will be displayed:

```bash
tofu output endpoint
```

## Module Configuration

### Required Variables (via locals)

The following locals are passed to the module in `main.tf`:

- `database_name` - Name of the initial database to create
- `service` - Service identifier used for naming resources
- `engine` - Database engine (always "postgres")
- `engine_version` - PostgreSQL version (e.g., "15.12", "16.x")
- `family` - Parameter group family (e.g., "postgres15")
- `db_parameter_group` - List of parameter objects to customize the instance

### Optional Variables

The module supports many optional variables (see `../../opentofu/modules/nonaurora/variables.tf`):

**Instance Configuration:**
- `instance_class` - Default: "db.t4g.medium"
- `allocated_storage` - Default: 100 GB
- `max_allocated_storage` - Default: 0 (disabled autoscaling)
- `storage_type` - Default: "gp3"
- `iops` - Default: 3000 (for storage >= 100GB)
- `multi_az` - Default: false

**Security & Access:**
- `username` - Default: "randoneering"
- `publicly_accessible` - Default: true
- `deletion_protection` - Default: false
- `storage_encrypted` - Default: true (always enabled in main.tf)
- `ca_cert_identifier` - Default: "rds-ca-ecc384-g1"

**Backup & Maintenance:**
- `backup_retention_period` - Default: 1 day
- `preferred_backup_window` - Default: "12:00-14:00"
- `preferred_maintenance_window` - Default: "sun:03:00-sun:04:00"
- `apply_immediately` - Default: true
- `skip_final_snapshot` - Default: true

**Monitoring:**
- `monitoring_interval` - Default: 60 seconds
- `performance_insights_enabled` - Default: false
- `enabled_cloudwatch_logs_exports` - Default: ["postgresql"]

### Customizing the Module Call

To pass additional variables, edit `main.tf`:

```hcl
module "nonaurora" {
  source              = "../../opentofu/modules/nonaurora"
  
  # Required
  database_name       = local.database_name
  service             = local.service
  engine              = local.engine
  engine_version      = local.engine_version
  family              = local.engine_family
  db_parameter_group  = local.db_parameter_group
  
  # Optional customizations
  instance_class      = "db.t4g.large"
  allocated_storage   = 200
  multi_az            = true
  deletion_protection = true
  
  required_tags = {
    Environment = "testing"
    Project     = "pgFirstAid"
  }
}
```

## Database Parameters

The module allows custom PostgreSQL parameters via `db_parameter_group`. Each parameter requires:

- `name` - Parameter name (e.g., "autovacuum")
- `value` - Parameter value
- `apply_method` - Either "immediate" or "pending-reboot"

Example parameter configuration in `locals.tf`:

```hcl
db_parameter_group = [
  {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements,auto_explain"
    apply_method = "pending-reboot"
  },
  {
    name         = "log_min_duration_statement"
    value        = "1000"
    apply_method = "immediate"
  }
]
```

## State Management

State files are stored locally in `../state/`:
- `pg15.tfstate` for PostgreSQL 15
- `pg16.tfstate` for PostgreSQL 16
- etc.

For production use, consider migrating to a remote backend (S3, Consul, etc.).

## Outputs

The module provides these outputs (accessible via `tofu output`):

- `endpoint` - Full RDS endpoint with port (e.g., "mydb.abc123.us-west-2.rds.amazonaws.com:5432")
- `rds_instance_address` - Hostname only (from module output)
- `rds_instance_arn` - ARN of the RDS instance
- `rds_instance_id` - Instance identifier


## Destroying Resources

To tear down the RDS instance:

```bash
tofu destroy
```

Note: With `skip_final_snapshot = true`, no snapshot will be created. Set to `false` and provide `final_snapshot_identifier` if you need a snapshot.

## Common Use Cases

### Creating Multiple Instances

To deploy multiple PostgreSQL versions simultaneously, navigate to each directory and run the tofu commands:

```bash
cd pg15 && tofu apply -auto-approve
cd ../pg16 && tofu apply -auto-approve
```

### Updating Parameters

1. Edit `locals.tf` and modify the `db_parameter_group` list
2. Run `tofu plan` to review changes
3. Run `tofu apply` to apply changes
4. Parameters with `apply_method = "pending-reboot"` require instance restart

### Changing Instance Class

1. Edit `main.tf` and add `instance_class` to the module block
2. Run `tofu apply` - RDS will be modified according to `apply_immediately` setting


## Module Source

Module location: `../../opentofu/modules/nonaurora/`

Key files:
- `main.tf` - Resource definitions (RDS instance, parameter group)
- `variables.tf` - Input variable definitions with defaults
- `outputs.tf` - Output value definitions
