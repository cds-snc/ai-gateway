# Encryption key for Bifrost — stored in Secrets Manager, injected into the container
resource "aws_secretsmanager_secret" "bifrost_encryption_key" {
  name        = "${var.name_prefix}/bifrost/encryption-key"
  description = "32-byte encryption key for the Bifrost AI gateway"
  kms_key_id  = aws_kms_key.invocation_logs.arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost-encryption-key" })
}

# Placeholder value — replace with a real 32-byte random key before apply
# e.g. openssl rand -hex 16
resource "aws_secretsmanager_secret_version" "bifrost_encryption_key" {
  secret_id     = aws_secretsmanager_secret.bifrost_encryption_key.id
  secret_string = "REPLACE_WITH_32_BYTE_KEY_BEFORE_APPLY"

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Bifrost config.json — updated by local helper script and injected into ECS
resource "aws_secretsmanager_secret" "bifrost_config_json" {
  name        = "${var.name_prefix}/bifrost/config-json"
  description = "Bifrost config.json content for ECS startup"
  kms_key_id  = aws_kms_key.invocation_logs.arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-bifrost-config-json" })
}

# Placeholder value. The local redeploy script updates this secret from config.json.
resource "aws_secretsmanager_secret_version" "bifrost_config_json" {
  secret_id     = aws_secretsmanager_secret.bifrost_config_json.id
  secret_string = jsonencode({
    governance = {
      auth_config = {
        is_enabled                 = true
        admin_username             = var.bifrost_auth_admin_username
        admin_password             = var.bifrost_auth_admin_password
        disable_auth_on_inference  = var.bifrost_auth_disable_on_inference
      }
    }
    config_store = {
      enabled = false
    }
    logs_store = {
      enabled = false
    }
  })
}
