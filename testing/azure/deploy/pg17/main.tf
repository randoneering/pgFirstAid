provider "azurerm" {
  features {}
}

module "postgres" {
  source = "../../opentofu/modules/postgres"

  server_name      = local.server_name
  postgres_version = local.postgres_version
  location         = local.location
  database_name    = local.database_name
  db_user          = local.db_user
  personal_ip      = var.personal_ip
}

output "server_name" {
  description = "Name of the PostgreSQL server"
  value       = module.postgres.server_name
}

output "server_fqdn" {
  description = "Fully qualified domain name of the server"
  value       = module.postgres.server_fqdn
}

output "database_name" {
  description = "Name of the database"
  value       = module.postgres.database_name
}

output "db_user" {
  description = "Database admin user name"
  value       = module.postgres.db_user
}
