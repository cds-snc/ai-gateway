locals {
  aws_region          = get_env("AWS_REGION", "ca-central-1")
  aws_account_id      = get_env("AWS_ACCOUNT_ID", "123456789012")
  tf_state_key_prefix = "ai-gateway"
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
