locals {
  identifier          = var.identifier =="" ? "${var.service}" : var.identifier
  username            = var.username == "" ? "randoneering" : var.username
  instance_class      = var.instance_class == "" ? "db.t4g.micro" : var.instance_class
  allocated_storage   = var.allocated_storage == "" ? 20 : var.allocated_storage
  iops                = var.allocated_storage >= 100 ? 3000 : null
  storage_type        = var.storage_type == "" ? "gp2" : var.storage_type

}

data "aws_vpc" "default" {
  default = true
}

resource "aws_security_group" "rds_sg" {
  name        = "${var.service}-rds-sg"
  description = "Security group for ${var.service} RDS instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "PostgreSQL access from public IP"
    from_port   = var.port
    to_port     = var.port
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr_block]
  }

  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.required_tags,
    {
      Name = "${var.service}-rds-sg"
    }
  )
}

resource "random_password" "password" {
  length  = 20
  special = false
}

resource "aws_db_instance" "rds_instance" {
  identifier                  = local.identifier
  engine                      = var.engine
  engine_version              = var.engine_version
  db_name                     = var.database_name
  username                    = local.username
  password                    = random_password.password.result
  instance_class              = local.instance_class
  parameter_group_name        = aws_db_parameter_group.param_group.name
  publicly_accessible         = true
  vpc_security_group_ids      = [aws_security_group.rds_sg.id]
  allocated_storage           = local.allocated_storage
  apply_immediately           = var.apply_immediately
  skip_final_snapshot         = true
  copy_tags_to_snapshot       = var.copy_tags_to_snapshot
  backup_retention_period     = var.backup_retention_period
  backup_window               = var.preferred_backup_window
  ca_cert_identifier                    = var.ca_cert_identifier
  delete_automated_backups              = var.delete_automated_backups
  monitoring_interval                   = var.monitoring_interval
  auto_minor_version_upgrade            = var.auto_minor_version_upgrade
  iops                                  = local.iops
  max_allocated_storage                 = var.max_allocated_storage
  multi_az                              = var.multi_az
  option_group_name                     = var.option_group_name
  enabled_cloudwatch_logs_exports       = ["postgresql"]
  performance_insights_enabled          = var.performance_insights_enabled
  storage_encrypted                     = true
  storage_type                          = local.storage_type
  storage_throughput                    = var.storage_throughput
  maintenance_window                    = var.preferred_maintenance_window
  deletion_protection                   = var.deletion_protection

}

resource "aws_db_parameter_group" "param_group" {
  name        = "${var.service}-parameter-group"
  family      = var.family
  description = "${var.service}db-parameter-group"
  tags        = var.required_tags

  dynamic "parameter" {
    for_each = var.db_parameter_group

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
