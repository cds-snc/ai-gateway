# -----------------------------------------------------------------------------
# Azure OpenAI (Cognitive Services) model deployments.
#
# LiteLLM's `azure/<name>` model string routes directly to a deployment name
# on azurerm_cognitive_account.openai -- it is not enough for the account to
# exist, a matching azurerm_cognitive_deployment must exist too. These were
# previously left as placeholders (see the TODO history in
# configuration_files/litellm_config.yaml.tftpl), which is why every azure/*
# model in that file 404'd ("The API deployment for this resource does not
# exist").
#
# The deployments themselves are described in
# configuration_files/azure_openai_deployments.yaml (var.azure_openai_deployments_config)
# rather than inline here -- each entry's model_version MUST be set to a
# real, available Azure OpenAI model version before applying. That same
# list also drives the Azure OpenAI section of
# configuration_files/litellm_config.yaml.tftpl (rendered via templatefile()
# in litellm_config.tf), so this is the single source of truth for azure/*
# models -- do not hand-edit that section of the template.
# -----------------------------------------------------------------------------

locals {
  azure_openai_deployments_list = yamldecode(
    file("${path.module}/${var.azure_openai_deployments_config}")
  )["deployments"]

  # Fill in defaults for the optional per-deployment fields (model_format,
  # sku_name, capacity), and compute is_new_category (used by the
  # litellm_config.yaml.tftpl template to emit a comment header whenever the
  # category changes) so the rendered YAML stays grouped/readable the same
  # way the previous hand-maintained file was.
  azure_openai_deployments_ordered = [
    for idx, d in local.azure_openai_deployments_list : merge(d, {
      model_format    = try(d.model_format, "OpenAI")
      sku_name        = try(d.sku_name, "Standard")
      capacity        = try(d.capacity, 10)
      is_new_category = idx == 0 ? true : d.category != local.azure_openai_deployments_list[idx - 1].category
    })
  ]

  # Keyed by name for azurerm_cognitive_deployment's for_each (map, not
  # list -- order doesn't matter here, each resource is addressed by key).
  azure_openai_deployments = {
    for d in local.azure_openai_deployments_ordered : d.name => d
  }
}

resource "azurerm_cognitive_deployment" "this" {
  for_each = local.azure_openai_deployments

  name                   = each.key
  cognitive_account_id   = azurerm_cognitive_account.openai.id
  version_upgrade_option = "NoAutoUpgrade"

  model {
    format  = each.value.model_format
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.capacity
  }

  lifecycle {
    precondition {
      condition     = each.value.model_version != ""
      error_message = "azure_openai_deployments.yaml entry \"${each.key}\".model_version is unset. Set it to a real Azure OpenAI model version (see `az cognitiveservices account list-models` or the Azure AI Foundry model catalog) before applying."
    }
  }
}
