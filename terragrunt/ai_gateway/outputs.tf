output "azure_managed_identity_client_id" {
  description = "Client ID of the Azure user-assigned managed identity the LiteLLM ECS task federates into."
  value       = azurerm_user_assigned_identity.litellm_openai_provisioner.client_id
}

output "azure_managed_identity_principal_id" {
  description = "Principal (object) ID of the Azure user-assigned managed identity, used in role assignments."
  value       = azurerm_user_assigned_identity.litellm_openai_provisioner.principal_id
}

output "azure_openai_resource_group_id" {
  description = "Resource ID of the Azure resource group scoped for Azure OpenAI resources."
  value       = local.azure_openai_resource_group_id
}

output "azure_openai_role_definition_id" {
  description = "Resource ID of the custom Azure role granted to the managed identity for provisioning Azure OpenAI keys."
  value       = azurerm_role_definition.openai_key_provisioner.role_definition_resource_id
}

output "azure_openai_account_id" {
  description = "Resource ID of the Azure OpenAI (Cognitive Services) account used by the LiteLLM data plane."
  value       = azurerm_cognitive_account.openai.id
}

output "azure_openai_account_endpoint" {
  description = "Data-plane endpoint (https://<custom-subdomain>.openai.azure.com/) of the Azure OpenAI account."
  value       = azurerm_cognitive_account.openai.endpoint
}

output "azure_inference_identity_client_id" {
  description = "Client ID of the Azure user-assigned managed identity the LiteLLM data plane uses to call Azure OpenAI directly (set as AZURE_CLIENT_ID on the LiteLLM container)."
  value       = azurerm_user_assigned_identity.litellm_openai_inference.client_id
}

output "azure_inference_identity_principal_id" {
  description = "Principal (object) ID of the inference-only managed identity, used in the Cognitive Services OpenAI User role assignment."
  value       = azurerm_user_assigned_identity.litellm_openai_inference.principal_id
}

output "litellm_task_role_arn" {
  description = "ARN of the AWS IAM role (litellm_task) federated into Azure. This is the `sub` claim Azure validates against."
  value       = aws_iam_role.litellm_task.arn
}

output "aws_outbound_web_identity_federation_issuer_url" {
  description = "Account-specific AWS STS issuer URL used as the `issuer` on the Azure federated identity credential."
  value       = aws_iam_outbound_web_identity_federation.this.issuer_identifier
}
