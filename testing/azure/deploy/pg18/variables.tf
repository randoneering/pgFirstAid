variable "personal_ip" {
  description = "Personal IP to allow access to the server (format: x.x.x.x)"
  type        = string
}

variable "db_password" {
  description = "Database admin password"
  type        = string
  sensitive   = true
}
