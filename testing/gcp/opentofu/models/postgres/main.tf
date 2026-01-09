resource "random_password" "password" {
  length  = 20
  special = false
}

resource "google_sql_database_instance" "postgres" {
  name             = var.instance_name
  database_version = var.postgres_version
  region           = var.region

  settings {
    tier              = "db-f1-micro"
    availability_type = "ZONAL"
    disk_size         = 10
    disk_type         = "PD_SSD"

    ip_configuration {
      ipv4_enabled = true

      authorized_networks {
        name  = "allow-personal"
        value = var.personal_ip
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
