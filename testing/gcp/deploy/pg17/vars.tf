variable "personal_ip" {
  description = "Personal IP to allow connections from"
  type = string
}

variable "db_password" {
  description = "Database user password"
  type        = string
  sensitive   = true
}
