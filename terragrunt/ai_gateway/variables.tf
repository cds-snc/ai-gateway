variable "name_prefix" {
  description = "Prefix used for named resources."
  type        = string
  default     = "ai-gateway"
}


variable "billing_tag_value" {
  description = "Billing tag value required by the cds-snc S3 module."
  type        = string
  default     = "innovation"
}

variable "data_classification" {
  description = "Data classification tag value."
  type        = string
  default     = "unclassified"
}

variable "primary_region" {
  description = "Primary Canadian region for Bedrock runtime."
  type        = string
  default     = "ca-central-1"

  validation {
    condition     = contains(["ca-central-1", "ca-west-2"], var.primary_region)
    error_message = "primary_region must be ca-central-1 or ca-west-2."
  }
}


variable "vpc_cidr" {
  description = "CIDR block for the dedicated AI gateway VPC."
  type        = string
  default     = "10.80.0.0/16"
}

variable "subnet_cidrs" {
  description = "CIDRs for private endpoint subnets (first two are used)."
  type        = list(string)
  default     = ["10.80.0.0/24", "10.80.1.0/24"]

  validation {
    condition     = length(var.subnet_cidrs) > 0
    error_message = "subnet_cidrs must contain at least one private subnet CIDR."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDRs for public subnets required by the shared VPC module."
  type        = list(string)
  default     = ["10.80.100.0/24", "10.80.101.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) == length(var.subnet_cidrs)
    error_message = "public_subnet_cidrs must have the same number of entries as subnet_cidrs."
  }
}

variable "allowed_endpoint_ingress_cidrs" {
  description = "CIDRs allowed to connect to VPC interface endpoints on 443."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}



variable "enable_prompt_and_completion_logging" {
  description = "Enable delivery of prompt/completion text in Bedrock invocation logging."
  type        = bool
  default     = true
}

variable "litellm_image" {
  description = "Pinned LiteLLM container image tag."
  type        = string
  default     = "ghcr.io/berriai/litellm-database:v1.90.2"
}

variable "litellm_desired_count" {
  description = "Desired number of LiteLLM ECS tasks."
  type        = number
  default     = 1
}

variable "litellm_force_redeploy_token" {
  description = "Change this value to force a new ECS task definition revision and rolling redeploy."
  type        = string
  default     = ""
}

variable "litellm_database_name" {
  description = "PostgreSQL database name for LiteLLM storage."
  type        = string
  default     = "litellm"
}

variable "litellm_database_username" {
  description = "PostgreSQL admin username used by LiteLLM to connect to RDS."
  type        = string
  default     = "litellm_admin"
}

variable "litellm_postgres_ssl_mode" {
  description = "SSL mode used by LiteLLM when connecting to PostgreSQL."
  type        = string
  default     = "require"

  validation {
    condition = contains([
      "disable",
      "allow",
      "prefer",
      "require",
      "verify-ca",
      "verify-full"
    ], var.litellm_postgres_ssl_mode)
    error_message = "litellm_postgres_ssl_mode must be a valid PostgreSQL sslmode value."
  }
}

variable "litellm_rds_engine_version" {
  description = "Aurora PostgreSQL engine version for LiteLLM storage."
  type        = string
  default     = "16.4"
}

variable "litellm_rds_instance_class" {
  description = "Instance class for the Aurora cluster instances."
  type        = string
  default     = "db.serverless"
}

variable "litellm_rds_instances" {
  description = "Number of Aurora cluster instances."
  type        = number
  default     = 1
}

variable "litellm_rds_serverless_min_capacity" {
  description = "Aurora serverless v2 minimum ACU."
  type        = number
  default     = 0.5
}

variable "litellm_rds_serverless_max_capacity" {
  description = "Aurora serverless v2 maximum ACU."
  type        = number
  default     = 4
}

variable "litellm_rds_backup_retention_period" {
  description = "RDS backup retention period in days."
  type        = number
  default     = 7
}

variable "litellm_rds_preferred_backup_window" {
  description = "Preferred RDS backup window in UTC."
  type        = string
  default     = "03:00-04:00"
}

variable "litellm_redis_engine_version" {
  description = "Redis engine version for LiteLLM sync cache."
  type        = string
  default     = "7.1"
}

variable "litellm_redis_node_type" {
  description = "Elasticache Redis node type."
  type        = string
  default     = "cache.t4g.micro"
}

variable "litellm_redis_num_cache_clusters" {
  description = "Number of nodes in the Redis replication group."
  type        = number
  default     = 1
}

variable "litellm_config_s3_key" {
  description = "S3 object key for LiteLLM proxy config.yaml."
  type        = string
  default     = "litellm/config.yaml"
}

variable "litellm_config_yaml" {
  description = "LiteLLM proxy config YAML uploaded to S3."
  type        = string
  default     = <<-EOT
model_list:
  - model_name: claude-sonnet-4
    litellm_params:
      model: bedrock/anthropic.claude-sonnet-4-20250514-v1:0
  - model_name: claude-haiku
    litellm_params:
      model: bedrock/anthropic.claude-3-5-haiku-20241022-v1:0

router_settings:
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD

general_settings:
  use_redis_transaction_buffer: true
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL

litellm_settings:
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD
  EOT
}

variable "litellm_master_key_placeholder" {
  description = "Placeholder value for LiteLLM master key secret. Must start with sk-."
  type        = string
  default     = "sk-CHANGE-ME-BEFORE-APPLY"
}

variable "litellm_db_password_placeholder" {
  description = "Placeholder value for LiteLLM database password secret."
  type        = string
  sensitive   = true
  default     = "CHANGE_ME_BEFORE_APPLY"
}

variable "litellm_redis_auth_token_placeholder" {
  description = "Placeholder value for LiteLLM Redis auth token secret."
  type        = string
  sensitive   = true
  default     = "CHANGE_ME_BEFORE_APPLY"
}

variable "litellm_local_model_cost_map" {
  description = "Set LiteLLM to use local model pricing map and avoid startup network fetch."
  type        = string
  default     = "True"
}

variable "gateway_certificate_arn" {
  description = "ACM certificate ARN for public HTTPS listener in this account."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^$|^arn:[^:]+:acm:[^:]+:[0-9]{12}:certificate/.+", var.gateway_certificate_arn))
    error_message = "gateway_certificate_arn must be empty or a valid ACM certificate ARN."
  }
}

variable "gateway_domain_name" {
  description = "Public FQDN for the AI gateway (for example ai.cdssandbox.xyz). This is required."
  type        = string

  validation {
    condition = (
      can(regex("^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$", var.gateway_domain_name))
    )
    error_message = "gateway_domain_name must be a valid lowercase DNS name."
  }
}

variable "gateway_subject_alternative_names" {
  description = "Optional SAN entries for the gateway ACM certificate."
  type        = list(string)
  default     = []
}

variable "gateway_tls_policy" {
  description = "TLS policy for the ALB HTTPS listener."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

variable "approved_public_listener_ports" {
  description = "Approved internet-facing listener ports."
  type        = list(number)
  default     = [80, 443]

  validation {
    condition     = contains(var.approved_public_listener_ports, 80) && contains(var.approved_public_listener_ports, 443)
    error_message = "approved_public_listener_ports must include both 80 and 443."
  }
}

variable "public_ingress_cidrs" {
  description = "Allowed CIDR ranges for approved public listener behavior."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_alb_access_logs" {
  description = "Enable ALB access log delivery to the shared S3 bucket."
  type        = bool
  default     = true
}

variable "alb_access_logs_prefix" {
  description = "S3 key prefix for ALB access logs."
  type        = string
  default     = "alb-access"
}

variable "listener_nacl_rule_start" {
  description = "Base NACL rule number for internet listener coverage rules."
  type        = number
  default     = 60
}

variable "health_check_interval_seconds" {
  description = "Target group health check interval in seconds."
  type        = number
  default     = 15
}

variable "health_check_timeout_seconds" {
  description = "Target group health check timeout in seconds."
  type        = number
  default     = 5
}

variable "health_check_healthy_threshold" {
  description = "Consecutive successful checks required for healthy status."
  type        = number
  default     = 3
}

variable "health_check_unhealthy_threshold" {
  description = "Consecutive failed checks required for unhealthy status."
  type        = number
  default     = 2
}

variable "litellm_container_port" {
  description = "LiteLLM container port."
  type        = number
  default     = 4000
}

variable "litellm_task_cpu" {
  description = "CPU units for LiteLLM ECS task."
  type        = number
  default     = 1024
}

variable "litellm_task_memory" {
  description = "Memory (MiB) for LiteLLM ECS task."
  type        = number
  default     = 2048
}

variable "litellm_use_redis" {
  description = "Enable Redis settings for LiteLLM."
  type        = bool
  default     = false
}

