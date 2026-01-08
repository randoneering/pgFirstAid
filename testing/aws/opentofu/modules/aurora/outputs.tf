output "rds_cluster_arn" {
  description = "The ID of the cluster"
  value       = aws_rds_cluster.rds_cluster.arn
}

output "rds_cluster_id" {
  description = "The ID of the cluster"
  value       = aws_rds_cluster.rds_cluster.id
}
output "rds_instance_master_username" {
  description = "The master username"
  value       = aws_rds_cluster.rds_cluster.master_username
}


output "rds_cluster_resource_id" {
  description = "The Resource ID of the cluster"
  value       = aws_rds_cluster.rds_cluster.cluster_resource_id
}

output "rds_cluster_endpoint" {
  value       = aws_rds_cluster.rds_cluster.endpoint
}

output "rds_cluster_reader_endpoint" {
  description = "The cluster reader endpoint"
  value       = aws_rds_cluster.rds_cluster.reader_endpoint
}

output "rds_cluster_database_name" {
  description = "Name for an automatically created database on cluster creation"
  value       = var.database_name
}

// aws_rds_cluster_instance
output "rds_cluster_instance_endpoints" {
  description = "A list of all cluster instance endpoints"
  value       = aws_rds_cluster_instance.rds_cluster_instance.*.endpoint
}

output "rds_cluster_instance_ids" {
  description = "A list of all cluster instance ids"
  value       = aws_rds_cluster_instance.rds_cluster_instance.*.id
}
