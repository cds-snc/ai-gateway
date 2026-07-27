provider "azurerm" {
  features {}

  tenant_id       = var.azure_tenant_id
  subscription_id = var.azure_subscription_id

  # Authenticates using the ambient Azure credentials configured on the
  # GitHub Actions admin-access role/OIDC federation (ARM_CLIENT_ID,
  # ARM_CLIENT_SECRET/ARM_OIDC_TOKEN, ARM_TENANT_ID, ARM_SUBSCRIPTION_ID env
  # vars, or `az login`). No credentials are hardcoded here.
}
