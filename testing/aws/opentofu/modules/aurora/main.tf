locals {
  username                        = var.username == "" ? "randoneering" : var.username
  master_password                 = var.master_password == "" ? random_password.password.result : var.master_password
  cluster_parameter_group_name    = var.cluster_parameter_group_name == "" ? "${var.service}-cluster-parameter-group" : var.cluster_parameter_group_name
  cluster_identifier              = var.cluster_identifier == "" ? "${var.service}-cluster" : var.cluster_identifier
  instance_class                  = var.instance_class == "" ? "db.t4g.medium" : var.instance_class
  identifier                      = var.identifier == "" ? "${var.service}-instance" : var.identifier
  snapshot_identifier             = var.snapshot_identifier == "" ? "" : var.snapshot_identifier
  delete_automated_backups        = var.delete_automated_backups == "" ? false : var.delete_automated_backups
}


resource "random_password" "password" {
  length  = 20
  special = false
}

resource "aws_rds_cluster" "rds_cluster" {
  cluster_identifier                  = local.cluster_identifier
  source_region                       = var.source_region
  engine                              = var.engine
  engine_mode                         = var.engine_mode
  engine_version                      = var.engine_version
  database_name                       = var.database_name
  master_username                     = local.username
  master_password                     = local.master_password
  skip_final_snapshot                 = var.skip_final_snapshot
  delete_automated_backups            = local.delete_automated_backups
  deletion_protection                 = var.deletion_protection
  backup_retention_period             = var.backup_retention_period
  performance_insights_enabled        = var.performance_insights_enabled
  preferred_backup_window             = var.preferred_backup_window
  preferred_maintenance_window        = var.preferred_maintenance_window
  db_subnet_group_name                = var.db_subnet_group_name
  vpc_security_group_ids              = [var.security_group_ids]
  storage_encrypted                   = var.storage_encrypted
  apply_immediately                   = var.apply_immediately
  db_cluster_parameter_group_name     = aws_rds_cluster_parameter_group.cluster_param_group.id
  enabled_cloudwatch_logs_exports = ["postgresql"]

}

resource "aws_rds_cluster_instance" "rds_cluster_instance" {

  identifier                      = "${local.identifier}-${count.index + 1}"
  cluster_identifier              = aws_rds_cluster.rds_cluster.id
  engine                          = var.engine
  engine_version                  = var.engine_version
  instance_class                  = local.instance_class
  publicly_accessible             = true
  preferred_maintenance_window    = var.preferred_maintenance_window
  apply_immediately               = var.apply_immediately
  performance_insights_enabled    = var.performance_insights_enabled
  performance_insights_kms_key_id = var.performance_insights_kms_key_id
  ca_cert_identifier              = var.ca_cert_identifier
  availability_zone               = var.availability_zone
}


resource "aws_rds_cluster_parameter_group" "cluster_param_group" {
  name        = local.cluster_parameter_group_name
  family      = var.family
  description = "aurora-cluster-parameter-group for ${var.service}, created by Terraform"
  tags        = var.required_tags

  dynamic "parameter" {
    for_each = var.cluster_parameter_group

    content {
      apply_method = parameter.value.apply_method
      name         = parameter.value.name
      value        = parameter.value.value
    }
  }

  lifecycle {
    create_before_destroy = true
  }

}
