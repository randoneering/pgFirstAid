output "server_name" {
  description = "Name of the PostgreSQL server"
  value       = azurerm_postgresql_flexible_server.postgres.name
}

output "server_fqdn" {
  description = "Fully qualified domain name of the server"
  value       = azurerm_postgresql_flexible_server.postgres.fqdn
}

output "database_name" {
  description = "Name of the database"
  value       = azurerm_postgresql_flexible_server_database.database.name
}

output "db_user" {
  description = "Database admin user name"
  value       = azurerm_postgresql_flexible_server.postgres.administrator_login
}

output "resource_group_name" {
  description = "Name of the resource group"
  value       = azurerm_resource_group.postgres_rg.name
}
