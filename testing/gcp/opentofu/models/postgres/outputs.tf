output "instance_name" {
  description = "Name of the Cloud SQL instance"
  value       = google_sql_database_instance.postgres.name
}

output "instance_connection_name" {
  description = "Connection name for Cloud SQL Proxy"
  value       = google_sql_database_instance.postgres.connection_name
}

output "public_ip_address" {
  description = "Public IP address of the instance"
  value       = google_sql_database_instance.postgres.public_ip_address
}

output "database_name" {
  description = "Name of the database"
  value       = google_sql_database.database.name
}

output "db_user" {
  description = "Database user name"
  value       = google_sql_user.user.name
}
