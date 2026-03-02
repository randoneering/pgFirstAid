variable "allowed_cidr_block" {
  description = "CIDR block allowed to access the RDS instance (e.g., 1.2.3.4/32)"
  type        = string
}

variable "db_password" {
  description = "Master DB password"
  type        = string
  sensitive   = true
}
