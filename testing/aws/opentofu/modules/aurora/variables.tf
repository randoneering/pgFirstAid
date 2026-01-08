variable "service" {
  description = "Name of service/app database resource is being created for"
  type        = string
  default     = ""
}

variable "account" {
  description = "Account number to deploy to"
  type        = string
  default     = ""

}

variable "environment" {
  description = "Name of the environment deploying to"
  type        = string
  default     = ""
}

variable "cluster_identifier" {
  description = "Name of cluster resource"
  type        = string
  default     = ""
}

variable "identifier" {
  description = "Name of cluster instance"
  type        = string
  default     = ""
}


variable "replica_count" {
  description = "Number of reader nodes to create.  If `replica_scale_enable` is `true`, the value of `replica_scale_min` is used instead."
  default     = 1
}

variable "instance_class" {
  description = "Instance type to use"
  type        = string
  default     = "db.t4g.medium"
}

variable "database_name" {
  description = "Name for an automatically created database on cluster creation"
  type        = string
  default     = ""
}


variable "username" {
  description = "Master DB username"
  type        = string
  default     = ""
}

variable "master_password" {
  description = "Master DB password"
  type        = string
  default     = ""
}

variable "final_snapshot_identifier_prefix" {
  description = "The prefix name to use when creating a final snapshot on cluster destroy, appends a random 8 digits to name to ensure it's unique too."
  type        = string
  default     = "final"
}

variable "skip_final_snapshot" {
  description = "Should a final snapshot be created on cluster destroy"
  type        = bool
  default     = false
}

variable "deletion_protection" {
  description = "If the DB instance should have deletion protection enabled"
  type        = bool
  default     = true
}
variable "delete_automated_backups" {
  description = "When the cluster is being deleted, set this to true in order to delete all automated backups."
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
  default     = "sun:05:00-sun:06:00"
}

variable "port" {
  description = "The port on which to accept connections"
  type        = string
  default     = ""
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

variable "parameter_group_name" {
  description = "Name of the DB parameter group to associate or create"
  type        = string
  default     = null
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

variable "cluster_parameter_group_name" {
  description = "Name of the DB cluster parameter group to associate or create"
  type        = string
  default     = null
}

variable "cluster_parameter_group" {
  description = "The name of a DB Cluster parameter group to use"
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

variable "engine" {
  description = "Aurora database engine type, currently aurora, aurora-mysql or aurora-postgresql"
  type        = string
  default     = "aurora-postgresql"
}

variable "engine_version" {
  description = "Aurora database engine version."
  type        = string
  default     = ""
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

variable "iam_database_authentication_enabled" {
  description = "Specifies whether IAM Database authentication should be enabled or not. Not all versions and instances are supported. Refer to the AWS documentation to see which versions are supported."
  type        = bool
  default     = false
}

variable "enabled_cloudwatch_logs_exports" {
  description = "List of log types to export to cloudwatch"
  type        = list(string)
  default     = [""]
}

variable "family" {
  description = "The family name of the RDS instance. See the RDS parameter group docs for complete list"
  type        = string
  default     = null
}


variable "engine_mode" {
  description = "The database engine mode. Valid values: global, parallelquery, provisioned, serverless, multimaster."
  type        = string
  default     = "provisioned"
}


variable "source_region" {
  description = "The source region for an encrypted replica DB cluster."
  default     = ""
}


variable "db_subnet_group_name" {
  description = "The existing subnet group name to use"
  type        = string
  default     = ""
}

variable "backtrack_window" {
  description = "The target backtrack window, in seconds. Only available for aurora engine currently. To disable backtracking, set this value to 0. Defaults to 0. Must be between 0 and 259200 (72 hours)"
  type        = number
  default     = 0
}

variable "copy_tags_to_snapshot" {
  description = "Copy all Cluster tags to snapshots."
  type        = bool
  default     = true
}

variable "iam_roles" {
  description = "A List of ARNs for the IAM roles to associate to the RDS Cluster."
  type        = list(string)
  default     = []
}

variable "ca_cert_identifier" {
  description = "CA certificate for the DB instance"
  type        = string
  default     = "rds-ca-ecc384-g1"
}

variable "availability_zone" {
  description = "List of AZ's cluster will be deployed in"
  type        = string
  default     = null
}


variable "resource_tags" {
  description = "A map of tags to add to only the RDS cluster. Used for AWS Instance Scheduler tagging"
  type        = map(string)
  default     = {}
}

variable "instances_parameters" {
  description = "Customized instance settings. Supported keys: `instance_name`, `instance_type`, `instance_promotion_tier`, `publicly_accessible`"
  type        = list(map(string))
  default     = []
}

variable "allow_major_version_upgrade" {
  description = "Allow major version upgrade on rds cluster"
  type        = bool
  default     = true
}

variable "security_group_ids" {
  description = "ids for security groups"
  type = list
  default = []
}
