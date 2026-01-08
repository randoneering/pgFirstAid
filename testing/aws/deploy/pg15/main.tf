

provider "aws" {
  region  = "us-west-2"
  profile = ""

}

module "aurora" {
  source                  = "../../opentofu/modules/aurora"
  account                 = data.aws_caller_identity.current.account_id
  service                 = local.service
  database_name           = local.database_name
  engine                  = local.engine
  engine_version          = local.engine_version
  family                  = local.engine_family
  cluster_parameter_group = local.cluster_parameter_group

}

output "writer_endpoint" {
  value = module.aurora.rds_cluster_endpoint
}

output "reader_endpoint" {
  value = module.aurora.rds_cluster_reader_endpoint
}
