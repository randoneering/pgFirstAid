resource "random_password" "password" {
  length  = 20
  special = false
}

locals {
  resolved_authorized_networks = length(var.authorized_networks) > 0 ? var.authorized_networks : [
    {
      name  = "allow-personal"
      value = var.personal_ip
    }
  ]
}

resource "google_sql_database_instance" "postgres" {
  name             = var.instance_name
  database_version = var.postgres_version
  region           = var.region

  settings {
    tier              = "db-g1-small"
    availability_type = "ZONAL"
    edition = "ENTERPRISE"
    disk_size         = 10
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled = true

      dynamic "authorized_networks" {
        for_each = local.resolved_authorized_networks

        content {
          name  = authorized_networks.value.name
          value = authorized_networks.value.value
        }
      }
    }

    backup_configuration {
      enabled = false
    }
  }

  deletion_protection = false
}

resource "google_sql_database" "database" {
  name     = var.database_name
  instance = google_sql_database_instance.postgres.name
}

resource "google_sql_user" "user" {
  name     = var.db_user
  instance = google_sql_database_instance.postgres.name
  password = random_password.password.result
}
