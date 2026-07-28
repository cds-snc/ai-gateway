terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      # >= 6.26 required for aws_iam_outbound_web_identity_federation.
      version = ">= 6.26"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.100"
    }
  }
}
