variable "instance_name" {
  description = "Name of the Cloud SQL instance"
  type        = string
}

variable "postgres_version" {
  description = "PostgreSQL version (POSTGRES_15, POSTGRES_16, POSTGRES_17, POSTGRES_18)"
  type        = string

  validation {
    condition     = contains(["POSTGRES_15", "POSTGRES_16", "POSTGRES_17", "POSTGRES_18"], var.postgres_version)
    error_message = "postgres_version must be POSTGRES_15, POSTGRES_16, POSTGRES_17, or POSTGRES_18"
  }
}

variable "region" {
  description = "GCP region for the instance"
  type        = string
  default     = "us-central1"
}

variable "database_name" {
  description = "Name of the default database"
  type        = string
  default     = "pgFirstAid"
}

variable "db_user" {
  description = "Database user name"
  type        = string
  default     = "randoneering"
}

variable "personal_ip" {
  description = "Personal IP to allow connections from"
  type = string
  default = "0.0.0.0"
}
