resource "aws_secretsmanager_secret" "litellm_master_key" {
  name        = "${var.name_prefix}/litellm/master-key"
  description = "LiteLLM master key for admin API access"
  kms_key_id  = aws_kms_key.invocation_logs.arn

  tags = merge(local.common_tags, {
    Name       = "${var.name_prefix}-litellm-master-key"
    ssc_cbrid  = "22DH"
  })
}

resource "aws_secretsmanager_secret_version" "litellm_master_key" {
  secret_id     = aws_secretsmanager_secret.litellm_master_key.id
  secret_string = var.litellm_master_key_placeholder
}

resource "aws_secretsmanager_secret" "litellm_db_password" {
  name        = "${var.name_prefix}/litellm/db-password"
  description = "LiteLLM Aurora PostgreSQL password"
  kms_key_id  = aws_kms_key.invocation_logs.arn

  tags = merge(local.common_tags, {
    Name       = "${var.name_prefix}-litellm-db-password"
    ssc_cbrid  = "22DH"
  })
}

resource "aws_secretsmanager_secret_version" "litellm_db_password" {
  secret_id     = aws_secretsmanager_secret.litellm_db_password.id
  secret_string = var.litellm_db_password_placeholder
}

resource "aws_secretsmanager_secret" "litellm_redis_auth_token" {
  name        = "${var.name_prefix}/litellm/redis-auth-token"
  description = "LiteLLM Elasticache Redis AUTH token"
  kms_key_id  = aws_kms_key.invocation_logs.arn

  tags = merge(local.common_tags, {
    Name       = "${var.name_prefix}-litellm-redis-auth-token"
    ssc_cbrid  = "22DH"
  })
}

resource "aws_secretsmanager_secret_version" "litellm_redis_auth_token" {
  secret_id     = aws_secretsmanager_secret.litellm_redis_auth_token.id
  secret_string = var.litellm_redis_auth_token_placeholder
}