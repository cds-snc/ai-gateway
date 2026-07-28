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
  description = "Name of the Azure user-assigned managed identity that the LiteLLM ECS task role federates into for control-plane (key provisioning) operations."
  type        = string
  default     = "ai-gateway-litellm-openai-provisioner"
}

variable "azure_inference_identity_name" {
  description = "Name of the Azure user-assigned managed identity used by the LiteLLM data plane to call Azure OpenAI directly (distinct blast radius from the provisioner identity)."
  type        = string
  default     = "ai-gateway-litellm-openai-inference"
}

variable "azure_federation_audience" {
  description = "Audience Microsoft Entra ID expects on incoming federated tokens. Do not change unless Microsoft's guidance changes."
  type        = string
  default     = "api://AzureADTokenExchange"
}

variable "azure_openai_account_name" {
  description = "Name of the Azure OpenAI (Cognitive Services) account used by the LiteLLM data plane."
  type        = string
  default     = "ai-gateway-openai-account"
}

variable "azure_openai_custom_subdomain_name" {
  description = "Custom subdomain for the Azure OpenAI account (results in https://<name>.openai.azure.com). Required for Entra ID token auth; defaults to azure_openai_account_name if unset."
  type        = string
  default     = ""
}

variable "azure_openai_sku_name" {
  description = "SKU for the Azure OpenAI (Cognitive Services) account."
  type        = string
  default     = "S0"
}

variable "azure_token_sidecar_image" {
  description = "Pinned container image for the sidecar that refreshes the Azure federated token file (must include the AWS CLI v2 sts get-web-identity-token command)."
  type        = string
  default     = "public.ecr.aws/aws-cli/aws-cli:2.36.6"
}

variable "azure_federated_token_refresh_duration_seconds" {
  description = "Duration (seconds) requested on each sts:GetWebIdentityToken call. Must stay <= the DurationSeconds condition on aws_iam_role_policy.litellm_task_azure_federation (currently 300)."
  type        = number
  default     = 300
}

variable "azure_openai_deployments_config" {
  description = "Path to the YAML file describing Azure OpenAI (Cognitive Services) deployments to create, relative to this module. See azure_openai_deployments.tf and configuration_files/azure_openai_deployments.yaml."
  type        = string
  default     = "configuration_files/azure_openai_deployments.yaml"
}
