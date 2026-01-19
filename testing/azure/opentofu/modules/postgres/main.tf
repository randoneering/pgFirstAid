resource "random_password" "password" {
  length  = 20
  special = false
}

resource "azurerm_resource_group" "postgres_rg" {
  name     = "${var.server_name}-rg"
  location = var.location
}

resource "azurerm_postgresql_flexible_server" "postgres" {
  name                = var.server_name
  resource_group_name = azurerm_resource_group.postgres_rg.name
  location            = azurerm_resource_group.postgres_rg.location
  version             = var.postgres_version

  administrator_login    = var.db_user
  administrator_password = random_password.password.result

  sku_name   = "B_Standard_B1ms"
  storage_mb = 32768

  backup_retention_days = 7
  geo_redundant_backup_enabled = false

  zone = "1"

  lifecycle {
    ignore_changes = [
      zone,
    ]
  }
}

resource "azurerm_postgresql_flexible_server_database" "database" {
  name      = var.database_name
  server_id = azurerm_postgresql_flexible_server.postgres.id
  charset   = "UTF8"
  collation = "en_US.utf8"
}

resource "azurerm_postgresql_flexible_server_firewall_rule" "allow_personal" {
  name             = "allow-personal"
  server_id        = azurerm_postgresql_flexible_server.postgres.id
  start_ip_address = var.personal_ip
  end_ip_address   = var.personal_ip
}
