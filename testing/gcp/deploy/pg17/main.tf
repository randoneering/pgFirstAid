provider "google" {
  project = local.project_id
  region  = local.region
}

module "postgres" {
  source = "../../models/postgres"

  instance_name    = local.instance_name
  postgres_version = local.postgres_version
  region           = local.region
  database_name    = local.database_name
  db_user          = local.db_user
  personal_ip      = local.personal_ip
}

output "instance_name" {
  description = "Name of the Cloud SQL instance"
  value       = module.postgres.instance_name
}

output "instance_connection_name" {
  description = "Connection name for Cloud SQL Proxy"
  value       = module.postgres.instance_connection_name
}

output "public_ip_address" {
  description = "Public IP address of the instance"
  value       = module.postgres.public_ip_address
}

output "database_name" {
  description = "Name of the database"
  value       = module.postgres.database_name
}

output "db_user" {
  description = "Database user name"
  value       = module.postgres.db_user
}
