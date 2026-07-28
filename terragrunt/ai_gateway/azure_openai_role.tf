# -----------------------------------------------------------------------------
# Azure side of AWS -> Azure workload identity federation.
#
# Goal: let the LiteLLM ECS task (using its existing AWS IAM role,
# aws_iam_role.litellm_task / "BedrockConsumer-litellm") assume an identity in
# Azure so it can provision and rotate Azure OpenAI (Cognitive Services) API
# keys, without ever storing a long-lived Azure client secret.
#
# Flow:
#   1. The ECS task calls AWS STS GetWebIdentityToken (see
#      aws_iam_role_policy.litellm_task_azure_federation in litellm_iam.tf)
#      to get a short-lived JWT signed by this AWS account, with
#      aud = var.azure_federation_audience and sub = the litellm_task role ARN.
#   2. The task exchanges that JWT for a Microsoft Entra ID access token via
#      the federated identity credential below (client_credentials grant,
#      client_assertion_type = urn:ietf:params:oauth:client-assertion-type:jwt-bearer).
#   3. That access token authenticates as the user-assigned managed identity,
#      which is authorized (via the custom role below) to read/regenerate
#      Azure OpenAI keys within azurerm_resource_group.ai_gateway_openai.
#
# Note: this Terraform manages account-level enablement of AWS IAM Outbound
# Web Identity Federation directly via aws_iam_outbound_web_identity_federation
# below, so no manual `aws iam enable-outbound-web-identity-federation` step
# is required. See README.md for the full token-exchange walkthrough.
# -----------------------------------------------------------------------------

# Enables AWS IAM Outbound Web Identity Federation for this account (a
# no-op if already enabled) and exposes the account-specific issuer URL used
# below as the `issuer` on the Azure federated identity credential.
resource "aws_iam_outbound_web_identity_federation" "this" {}

resource "azurerm_resource_group" "ai_gateway_openai" {
  count = var.azure_create_resource_group ? 1 : 0

  name     = var.azure_resource_group_name
  location = var.azure_location

  tags = {
    purpose             = "ai-gateway"
    data-classification = var.data_classification
    managed-by          = "terraform"
  }
}

data "azurerm_resource_group" "ai_gateway_openai" {
  count = var.azure_create_resource_group ? 0 : 1

  name = var.azure_resource_group_name
}

locals {
  azure_openai_resource_group_id = var.azure_create_resource_group ? azurerm_resource_group.ai_gateway_openai[0].id : data.azurerm_resource_group.ai_gateway_openai[0].id
}

# User-assigned managed identity that acts as the "role" the ECS task assumes
# in Azure. This is granted only the permissions needed to manage Azure
# OpenAI (Cognitive Services) accounts and their keys within the target
# resource group.
resource "azurerm_user_assigned_identity" "litellm_openai_provisioner" {
  name                = var.azure_managed_identity_name
  resource_group_name = var.azure_create_resource_group ? azurerm_resource_group.ai_gateway_openai[0].name : data.azurerm_resource_group.ai_gateway_openai[0].name
  location            = var.azure_location

  tags = {
    purpose    = "ai-gateway"
    managed-by = "terraform"
  }
}

# Trust relationship: allows the AWS litellm_task IAM role to exchange its
# AWS-issued JWT (sub = role ARN) for a Microsoft Entra ID access token as
# this managed identity.
resource "azurerm_federated_identity_credential" "litellm_task_aws" {
  name                = "${var.name_prefix}-litellm-task-aws-federation"
  resource_group_name = var.azure_create_resource_group ? azurerm_resource_group.ai_gateway_openai[0].name : data.azurerm_resource_group.ai_gateway_openai[0].name
  parent_id           = azurerm_user_assigned_identity.litellm_openai_provisioner.id

  issuer  = aws_iam_outbound_web_identity_federation.this.issuer_identifier
  subject = aws_iam_role.litellm_task.arn
  audience = [
    var.azure_federation_audience
  ]
}

# Minimal custom role: only what's needed to create/read/delete Azure OpenAI
# (Cognitive Services) accounts and deployments and to read/rotate their
# subscription keys. Deliberately narrower than the built-in "Cognitive
# Services Contributor" role's broader Cognitive Services surface area.
resource "azurerm_role_definition" "openai_key_provisioner" {
  name        = "${var.name_prefix}-openai-key-provisioner"
  scope       = local.azure_openai_resource_group_id
  description = "Provision, configure, and rotate Azure OpenAI (Cognitive Services) accounts and keys for the AI gateway."

  permissions {
    actions = [
      "Microsoft.CognitiveServices/accounts/read",
      "Microsoft.CognitiveServices/accounts/write",
      "Microsoft.CognitiveServices/accounts/delete",
      "Microsoft.CognitiveServices/accounts/listKeys/action",
      "Microsoft.CognitiveServices/accounts/regenerateKey/action",
      "Microsoft.CognitiveServices/accounts/deployments/read",
      "Microsoft.CognitiveServices/accounts/deployments/write",
      "Microsoft.CognitiveServices/accounts/deployments/delete",
      "Microsoft.CognitiveServices/locations/usages/read",
      "Microsoft.CognitiveServices/locations/modelCapacities/read",
      "Microsoft.Resources/subscriptions/resourceGroups/read"
    ]
    not_actions = []
  }

  assignable_scopes = [
    local.azure_openai_resource_group_id
  ]
}

resource "azurerm_role_assignment" "litellm_openai_provisioner" {
  scope              = local.azure_openai_resource_group_id
  role_definition_id = azurerm_role_definition.openai_key_provisioner.role_definition_resource_id
  principal_id       = azurerm_user_assigned_identity.litellm_openai_provisioner.principal_id
}
