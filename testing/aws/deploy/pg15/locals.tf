locals {
      service             = "pg15"
      database_name       = "pgFirstAid"
      engine              = "postgres"
      engine_version      = "15.12"
      engine_family       = "postgres15"
      db_parameter_group = [
        {
          name         = "autovacuum"
          value        = "1"
          apply_method = "immediate"
        },
        {
          name         = "autovacuum_analyze_threshold"
          value        = "0"
          apply_method = "immediate"
        },
        {
          name         = "autovacuum_naptime"
          value        = "15"
          apply_method = "immediate"
        },
        {
          name         = "autovacuum_vacuum_cost_delay"
          value        = "20"
          apply_method = "immediate"
        },
        {
          name         = "autovacuum_vacuum_scale_factor"
          value        = "0.5"
          apply_method = "immediate"
        },
        {
          name         = "autovacuum_vacuum_threshold"
          value        = "50"
          apply_method = "immediate"
        },
        {
          name         = "rds.force_ssl"
          value        = "0"
          apply_method = "immediate"
        },
        {
          name         = "rds.logical_replication"
          value        = "1"
          apply_method = "pending-reboot"
        },
        {
          name         = "shared_preload_libraries"
          value        = "pg_stat_statements"
          apply_method = "pending-reboot"
        }
      ]
    }
