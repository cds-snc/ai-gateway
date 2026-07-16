locals {
  common_tags = {
    purpose             = "ai-gateway"
    data-classification = var.data_classification
    managed-by          = "terraform"
  }
}