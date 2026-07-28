# -----------------------------------------------------------------------------
# Azure side of AWS -> Azure workload identity federation.
#
# Two separate identities are federated from the same AWS IAM role
# (aws_iam_role.litellm_task / "BedrockConsumer-litellm"), deliberately kept
# separate so a compromise of one has a smaller blast radius than the other:
#
#   - azurerm_user_assigned_identity.litellm_openai_provisioner: control
#     plane. Used only to provision/rotate Azure OpenAI (Cognitive Services)
#     accounts and keys, authorized via the built-in "Cognitive Services
#     Contributor" role assignment below.
#   - azurerm_user_assigned_identity.litellm_openai_inference: data plane.
#     Used by the LiteLLM proxy itself (via a token-refresh sidecar, see
#     litellm_ecs.tf) to call the Azure OpenAI data plane directly with a
#     short-lived Entra ID access token instead of a long-lived API key.
#     Authorized only with the built-in "Cognitive Services OpenAI User"
#     role, scoped to the account.
#
# Flow (same for both identities, different audience/principal):
#   1. The ECS task calls AWS STS GetWebIdentityToken (see
#      aws_iam_role_policy.litellm_task_azure_federation in litellm_iam.tf)
#      to get a short-lived JWT signed by this AWS account, with
#      aud = var.azure_federation_audience and sub = the litellm_task role ARN.
#   2. The task (or, for inference, the sidecar) exchanges that JWT for a
#      Microsoft Entra ID access token via the matching federated identity
#      credential below (client_credentials grant, client_assertion_type =
#      urn:ietf:params:oauth:client-assertion-type:jwt-bearer).
#   3. That access token authenticates as the corresponding user-assigned
#      managed identity.
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
  azure_openai_resource_group_id   = var.azure_create_resource_group ? azurerm_resource_group.ai_gateway_openai[0].id : data.azurerm_resource_group.ai_gateway_openai[0].id
  azure_openai_resource_group_name = var.azure_create_resource_group ? azurerm_resource_group.ai_gateway_openai[0].name : data.azurerm_resource_group.ai_gateway_openai[0].name
  azure_openai_custom_subdomain_name = (
    var.azure_openai_custom_subdomain_name != "" ? var.azure_openai_custom_subdomain_name : var.azure_openai_account_name
  )
}

# The Azure OpenAI (Cognitive Services) account itself. custom_subdomain_name
# is required: Entra ID token auth only works against
# https://<name>.openai.azure.com, never the shared regional endpoint.
#
# local_auth_enabled = false: key-based auth is disabled outright. This repo
# never actually stored/used an AZURE_API_KEY (no Secrets Manager secret, no
# ECS secret reference, no rotation automation ever existed here -- see
# README/PR history), so there is no rollback path being removed and nothing
# else in this account depends on subscription keys. All Azure OpenAI access
# goes through the workload-identity-federated managed identities below.
resource "azurerm_cognitive_account" "openai" {
  name                  = var.azure_openai_account_name
  resource_group_name   = local.azure_openai_resource_group_name
  location              = var.azure_location
  kind                  = "OpenAI"
  sku_name              = var.azure_openai_sku_name
  local_auth_enabled    = false
  custom_subdomain_name = local.azure_openai_custom_subdomain_name

  tags = {
    purpose             = "ai-gateway"
    data-classification = var.data_classification
    managed-by          = "terraform"
  }
}

# User-assigned managed identity that acts as the "role" the ECS task assumes
# in Azure. This is granted only the permissions needed to manage Azure
# OpenAI (Cognitive Services) accounts and their keys within the target
# resource group.
resource "azurerm_user_assigned_identity" "litellm_openai_provisioner" {
  name                = var.azure_managed_identity_name
  resource_group_name = local.azure_openai_resource_group_name
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
  name                      = "${var.name_prefix}-litellm-task-aws-federation"
  user_assigned_identity_id = azurerm_user_assigned_identity.litellm_openai_provisioner.id

  issuer  = aws_iam_outbound_web_identity_federation.this.issuer_identifier
  subject = aws_iam_role.litellm_task.arn
  audience = [
    var.azure_federation_audience
  ]
}

# Built-in "Cognitive Services Contributor" role, assigned at the resource
# group scope. A superset of the actions previously granted by a hand-scoped
# custom role (Microsoft.CognitiveServices/*), used instead because creating
# a custom azurerm_role_definition requires
# Microsoft.Authorization/roleDefinitions/write, which the CI service
# principal's Contributor + Role Based Access Control Administrator roles do
# not grant. Assigning a built-in role only needs roleAssignments/write.
resource "azurerm_role_assignment" "litellm_openai_provisioner" {
  scope              = local.azure_openai_resource_group_id
  role_definition_id = "/subscriptions/${var.azure_subscription_id}/providers/Microsoft.Authorization/roleDefinitions/25fbc0a9-bd7c-42a3-aa1a-3b75d497ee68"
  principal_id       = azurerm_user_assigned_identity.litellm_openai_provisioner.principal_id
}

# --- Inference-only identity (data plane) ------------------------------------
# Separate from the provisioner identity above: this is what the LiteLLM
# proxy container actually authenticates as when calling Azure OpenAI. It can
# only invoke models on the one account below -- it cannot read/rotate keys,
# create/delete accounts, or touch anything else in the resource group.
resource "azurerm_user_assigned_identity" "litellm_openai_inference" {
  name                = var.azure_inference_identity_name
  resource_group_name = local.azure_openai_resource_group_name
  location            = var.azure_location

  tags = {
    purpose    = "ai-gateway"
    managed-by = "terraform"
  }
}

resource "azurerm_federated_identity_credential" "litellm_inference_aws" {
  name                      = "${var.name_prefix}-litellm-inference-aws-federation"
  user_assigned_identity_id = azurerm_user_assigned_identity.litellm_openai_inference.id

  issuer  = aws_iam_outbound_web_identity_federation.this.issuer_identifier
  subject = aws_iam_role.litellm_task.arn
  audience = [
    var.azure_federation_audience
  ]
}

# Built-in data-plane role, scoped to the account (not the resource group):
# inference only needs to call the account's OpenAI API, not the broader
# Cognitive Services Contributor permissions granted to the provisioner
# identity above. Deliberately does not extend litellm_openai_provisioner.
resource "azurerm_role_assignment" "litellm_openai_inference" {
  scope                = azurerm_cognitive_account.openai.id
  role_definition_name = "Cognitive Services OpenAI User"
  principal_id         = azurerm_user_assigned_identity.litellm_openai_inference.principal_id
}

