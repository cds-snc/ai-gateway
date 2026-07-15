locals {
  aws_region          = get_env("AWS_REGION", "ca-central-1")
  aws_account_id      = get_env("AWS_ACCOUNT_ID", "123456789012")
  tf_state_key_prefix = "ai-gateway"
  env_config          = try(read_terragrunt_config("${get_terragrunt_dir()}/staging.hcl"), { inputs = {} })
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    encrypt             = true
    bucket              = "ai-gateway-staging-tf"
    use_lockfile        = true
    region              = "ca-central-1"
    key                 = "./terraform.tfstate"
    s3_bucket_tags      = { ssc_cbrid = "22DH" }
    dynamodb_table_tags = { ssc_cbrid = "22DI" }
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "aws" {
      region = "${local.aws_region}"

      default_tags {
        tags = {
          purpose             = "ai-gateway"
          data-classification = "unclassified"
          managed-by          = "terraform"
          ssc_cbrid = "22DI"
        }
      }
    }
  EOF
}

terraform {
  source = "."
}

inputs = local.env_config.inputs
