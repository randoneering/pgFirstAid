variable "account" {
  description = "Account number to deploy to"
  type        = string
  default     = ""

}

variable "service" {
  description = "Name for the service"
  type        = string
  default     = ""
}

variable "identifier" {
  description = "To be used if there needs to be a specific, custom name for the instance that differs from the default"
  type        = string
  default     = ""
}

variable "vpc_security_group_ids" {
  description = "A list of Security Group ID's to allow access to."
  type        = list(string)
  default     = []
}

variable "instance_class" {
  description = "Instance type to use"
  type        = string
  default     = "db.t3.micro"
}

variable "database_name" {
  description = "Name for an automatically created database on instance creation"
  type        = string
  default     = ""
}

variable "username" {
  description = "Master DB username"
  type        = string
  default     = "randoneering"
}

variable "skip_final_snapshot" {
  description = "Should a final snapshot be created on instance destroy"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "If the DB instance should have deletion protection enabled"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "How long to keep backups for (in days)"
  type        = number
  default     = 1
}

variable "preferred_backup_window" {
  description = "When to perform DB backups"
  type        = string
  default     = "12:00-14:00"
}

variable "preferred_maintenance_window" {
  description = "When to perform DB maintenance"
  type        = string
  default     = "sun:03:00-sun:04:00" #Tues DEMO/PLE, #Thurs is Prod
}

variable "port" {
  description = "The port on which to accept connections"
  type        = string
  default     = "5432"
}

variable "apply_immediately" {
  description = "Determines whether or not any DB modifications are applied immediately, or during the maintenance window"
  type        = bool
  default     = true
}

variable "monitoring_interval" {
  description = "The interval (seconds) between points when Enhanced Monitoring metrics are collected"
  type        = number
  default     = 60
}

variable "auto_minor_version_upgrade" {
  description = "Determines whether minor engine upgrades will be performed automatically in the maintenance window"
  type        = bool
  default     = true
}

variable "db_parameter_group" {
  description = "The name of a DB parameter group"
  type = list(object({
    apply_method = string
    name         = string
    value        = string
  }))
  default = []
}

variable "snapshot_identifier" {
  description = "DB snapshot to create this database from"
  type        = string
  default     = null
}

variable "storage_encrypted" {
  description = "Specifies whether the underlying storage layer should be encrypted"
  type        = bool
  default     = true
}

variable "allocated_storage" {
  description = "Specifies the amount of storage the instance starts with"
  type        = number
  default     = 60

}
variable "kms_key_id" {
  description = "The ARN for the KMS encryption key if one is set to the instance."
  type        = string
  default     = ""
}

variable "engine" {
  description = "Aurora database engine type, currently aurora, aurora-mysql or aurora-postgresql"
  type        = string
  default     = "postgres"
}

variable "engine_version" {
  description = "RDS database engine version. Default is 15.12 for postgres"
  type        = string
  default     = "15.12"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "required_tags" {
  description = "A map of tags to add to all resources."
  type        = map(string)
  default     = {}
}

variable "performance_insights_enabled" {
  description = "Specifies whether Performance Insights is enabled or not."
  type        = bool
  default     = false
}

variable "performance_insights_kms_key_id" {
  description = "The ARN for the KMS key to encrypt Performance Insights data."
  type        = string
  default     = ""
}

variable "performance_insights_retention_period" {
  description = "Amount of time in days to keep performance insight data, in increments of 7 to 731 (two years) or multiples of 31."
  type        = number
  default     = 7
}
variable "iam_database_authentication_enabled" {
  description = "Specifies whether IAM Database authentication should be enabled or not. Not all versions and instances are supported. Refer to the AWS documentation to see which versions are supported."
  type        = bool
  default     = false
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to export to cloudwatch"
  type        = list(string)
  default     = ["postgres"]
}

variable "family" {
  description = "The family name of the RDS instance. See the RDS parameter group docs for complete list"
  type        = string
  default     = "postgres15"
}

variable "db_subnet_group_name" {
  description = "The existing subnet group name to use"
  type        = string
  default     = ""
}


variable "copy_tags_to_snapshot" {
  description = "Copy all instance tags to snapshots."
  type        = bool
  default     = true
}

variable "iam_roles" {
  description = "A List of ARNs for the IAM roles to associate to the RDS instance."
  type        = list(string)
  default     = []
}

variable "ca_cert_identifier" {
  description = "The identifier of the CA certificate for the DB instance"
  type        = string
  default     = "rds-ca-ecc384-g1"
}

variable "availability_zone" {
  description = "List of AZ's instance will be deployed in"
  type        = string
  default     = null
}

variable "instances_parameters" {
  description = "Customized instance settings. Supported keys: `instance_name`, `instance_type`, `instance_promotion_tier`, `publicly_accessible`"
  type        = list(map(string))
  default     = []
}

variable "s3_import" {
  description = "Configuration map used to restore from S3"
  type        = map(string)
  default     = null
}

variable "allow_major_version_upgrade" {
  description = "Allow major version upgrade on rds instance"
  type        = bool
  default     = true
}

variable "delete_automated_backups" {
  description = "Specifies whether to remove automated backups immediately after the DB instance is deleted"
  type        = bool
  default     = true
}


variable "blue_green_enabled" {
  description = "Whether or not to enable a blue/green deployment"
  type        = bool
  default     = false
}

variable "storage_type" {
  description = "Accepted values are GP2, GP3 (requires iops), io1, io2"
  type        = string
  default     = "gp3"
}

variable "iops" {
  description = "The amount of iops to be provisioned. Only applies if storage_type is set to io1, io2, or gp3"
  type        = number
  default     = null
}

variable "max_allocated_storage" {
  description = "If storage auto-scaling is enabled, this is the max mount that the instance can expand to. Must be greater than or equal to allocated_storage, or 0 to disable auto-scaling"
  type        = number
  default     = 0
}

variable "option_group_name" {
  description = "Name of DB option group"
  type        = string
  default     = ""
}

variable "restore_to_point_in_time" {
  description = "Restore to a point in time (MySQL is NOT supported)"
  type        = map(string)
  default     = null
}

variable "source_db_instance_identifier" {
  description = "The identifier of the source db instance from which to restore. Must match the identifier of an existing DB."
  type        = string
  default     = ""
}

variable "source_db_instance_automated_backups_arn" {
  description = "ARN of automated backup to restore from"
  type        = string
  default     = ""

}

variable "use_latest_restorable_time" {
  description = "Whether or not to restore to the most recent restorable time. Default is false"
  type        = bool
  default     = false
}

variable "storage_throughput" {
  description = "The storage throughput value for the db instance. Only possible if storage type is gp3"
  type        = number
  default     = null
}

variable "kms_key_arn" {
  description = "The arn for the kms that is encrypting this instance/instance."
  type        = string
  default     = ""
}
