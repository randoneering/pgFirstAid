variable "server_name" {
  description = "Name of the PostgreSQL Flexible Server"
  type        = string
}

variable "postgres_version" {
  description = "PostgreSQL version (15, 16, 17, 18)"
  type        = string

  validation {
    condition     = contains(["15", "16", "17", "18"], var.postgres_version)
    error_message = "postgres_version must be 15, 16, 17, or 18"
  }
}

variable "location" {
  description = "Azure region for the server"
  type        = string
  default     = "eastus"
}

variable "database_name" {
  description = "Name of the default database"
  type        = string
  default     = "pgFirstAid"
}

variable "db_user" {
  description = "Database admin user name"
  type        = string
  default     = "randoneering"
}

variable "personal_ip" {
  description = "Personal IP to allow connections from (format: x.x.x.x)"
  type        = string
}
