provider "google" {
  project = var.gcp_project_id
  region  = var.region
}

module "postgres_15" {
  source = "./modules/postgres"

  instance_name    = "postgres-15-test"
  postgres_version = "POSTGRES_15"
  region           = var.region
  database_name    = "pgFirstAid"
  db_user          = "postgres"
  db_password      = var.db_password
}

module "postgres_16" {
  source = "./modules/postgres"

  instance_name    = "postgres-16-test"
  postgres_version = "POSTGRES_16"
  region           = var.region
  database_name    = "pgFirstAid"
  db_user          = "postgres"
  db_password      = var.db_password
}

module "postgres_17" {
  source = "./modules/postgres"

  instance_name    = "postgres-17-test"
  postgres_version = "POSTGRES_17"
  region           = var.region
  database_name    = "pgFirstAid"
  db_user          = "postgres"
  db_password      = var.db_password
}

module "postgres_18" {
  source = "./modules/postgres"

  instance_name    = "postgres-18-test"
  postgres_version = "POSTGRES_18"
  region           = var.region
  database_name    = "pgFirstAid"
  db_user          = "postgres"
  db_password      = var.db_password
}


output "postgres_15_ip" {
  description = "PostgreSQL 15 public IP"
  value       = module.postgres_15.public_ip_address
}

output "postgres_15_connection" {
  description = "PostgreSQL 15 connection string"
  value       = module.postgres_15.connection_string
  sensitive   = true
}

output "postgres_16_ip" {
  description = "PostgreSQL 16 public IP"
  value       = module.postgres_16.public_ip_address
}

output "postgres_16_connection" {
  description = "PostgreSQL 16 connection string"
  value       = module.postgres_16.connection_string
  sensitive   = true
}

output "postgres_17_ip" {
  description = "PostgreSQL 17 public IP"
  value       = module.postgres_17.public_ip_address
}

output "postgres_17_connection" {
  description = "PostgreSQL 17 connection string"
  value       = module.postgres_17.connection_string
  sensitive   = true
}

output "postgres_18_ip" {
  description = "PostgreSQL 18 public IP"
  value       = module.postgres_18.public_ip_address
}

output "postgres_18_connection" {
  description = "PostgreSQL 18 connection string"
  value       = module.postgres_18.connection_string
  sensitive   = true
}
