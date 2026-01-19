output "account" {
  description = "Account"
  value       = var.account
}

output "rds_instance_endpoint" {
  description = "A list of all instance endpoints"
  value       = aws_db_instance.rds_instance.endpoint
}


output "rds_instance_address" {
  description = "The hostname of the RDS instance, without the port"
  value       = aws_db_instance.rds_instance.address

}

output "rds_instance_arn" {
  description = "The ID of the instance"
  value       = aws_db_instance.rds_instance.arn
}

output "rds_instance_id" {
  description = "The ID of the instance"
  value       = aws_db_instance.rds_instance.id
}
