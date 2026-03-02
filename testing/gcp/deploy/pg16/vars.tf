variable "authorized_networks" {
  description = "Authorized networks for Cloud SQL"
  type = list(object({
    name  = string
    value = string
  }))
}

variable "db_password" {
  description = "Database user password"
  type        = string
  sensitive   = true
}
