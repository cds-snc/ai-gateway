# -----------------------------------------------------------------------------
# Variables for the Azure side of the AWS -> Azure workload identity
# federation used so the LiteLLM ECS task can provision/rotate Azure OpenAI
# (Cognitive Services) keys without any long-lived Azure secrets.
# -----------------------------------------------------------------------------

variable "azure_tenant_id" {
  description = "Microsoft Entra ID (Azure AD) tenant ID that owns the Azure OpenAI resources."
  type        = string
}

variable "azure_subscription_id" {
  description = "Azure subscription ID that contains (or will contain) the Azure OpenAI resource group."
  type        = string
}

variable "azure_location" {
  description = "Azure region for the resource group used to hold Azure OpenAI resources."
  type        = string
  default     = "canadacentral"
}

variable "azure_resource_group_name" {
  description = "Name of the Azure resource group scoped for Azure OpenAI (Cognitive Services) resources."
  type        = string
  default     = "ai-gateway-openai"
}

variable "azure_create_resource_group" {
  description = "Whether Terraform should create azure_resource_group_name. Set to false if it already exists and is managed elsewhere."
  type        = bool
  default     = true
}

variable "azure_managed_identity_name" {
  description = "Name of the Azure user-assigned managed identity that the LiteLLM ECS task role federates into."
  type        = string
  default     = "ai-gateway-litellm-openai-provisioner"
}

variable "aws_outbound_federation_issuer_url" {
  description = <<-EOT
    Account-specific issuer URL returned by `aws iam enable-outbound-web-identity-federation`
    (a one-time, account-level, out-of-band step; see README for details), for example
    "https://abc123-def456-ghi789-jkl012.tokens.sts.global.api.aws". Used as the `issuer`
    on the Azure federated identity credential so Microsoft Entra ID trusts JWTs issued by
    this AWS account's STS on behalf of the litellm_task IAM role.
  EOT
  type        = string
}

variable "azure_federation_audience" {
  description = "Audience Microsoft Entra ID expects on incoming federated tokens. Do not change unless Microsoft's guidance changes."
  type        = string
  default     = "api://AzureADTokenExchange"
}
