locals {
  project_id       = ""  # Set your GCP project ID
  region           = "us-central1"
  instance_name    = "pgfirstaid-pg15"
  postgres_version = "POSTGRES_15"
  database_name    = "pgFirstAid"
  db_user          = "randoneering"
  personal_ip      = "0.0.0.0/0"  # Replace with your IP or CIDR range
}
