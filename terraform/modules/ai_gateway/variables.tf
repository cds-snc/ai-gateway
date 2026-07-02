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


variable "bifrost_database_name" {
  description = "PostgreSQL database name for Bifrost config and logs storage."
  type        = string
  default     = "bifrost"
}

variable "bifrost_database_username" {
  description = "PostgreSQL admin username used by Bifrost to connect to RDS."
  type        = string
  default     = "bifrost"
}

variable "bifrost_postgres_ssl_mode" {
  description = "SSL mode used by Bifrost when connecting to PostgreSQL."
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
    ], var.bifrost_postgres_ssl_mode)
    error_message = "bifrost_postgres_ssl_mode must be a valid PostgreSQL sslmode value."
  }
}

variable "bifrost_auth_admin_username" {
  description = "Bifrost admin username in config.json governance.auth_config."
  type        = string
  default     = "calvin"
}

variable "bifrost_auth_admin_password" {
  description = "Bifrost admin password in config.json governance.auth_config."
  type        = string
  sensitive   = true
  default     = "CHANGE_ME_BEFORE_APPLY"
}

variable "bifrost_auth_disable_on_inference" {
  description = "Disable Bifrost authentication checks on inference endpoints."
  type        = bool
  default     = false
}

