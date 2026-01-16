provider "aws" {
  region  = "us-west-2"
}

module "nonaurora" {
  source              = "../../opentofu/modules/nonaurora"
  database_name       = local.database_name
  service             = local.service
  engine              = local.engine
  engine_version      = local.engine_version
  family              = local.engine_family
  db_parameter_group  = local.db_parameter_group
  allowed_cidr_block  = var.allowed_cidr_block
}

output "endpoint" {
  value = module.nonaurora.rds_instance_address
}
s
