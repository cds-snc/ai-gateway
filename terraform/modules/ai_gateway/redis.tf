data "aws_secretsmanager_secret_version" "litellm_redis_auth_token" {
  secret_id  = aws_secretsmanager_secret.litellm_redis_auth_token.id
  depends_on = [aws_secretsmanager_secret_version.litellm_redis_auth_token]
}

# No CDS module available for Elasticache Redis — using native AWS provider
resource "aws_elasticache_subnet_group" "litellm" {
  name       = "${var.name_prefix}-litellm-redis"
  subnet_ids = module.gateway_vpc.private_subnet_ids

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-litellm-redis" })
}

# No CDS module available for Elasticache Redis — using native AWS provider
resource "aws_elasticache_replication_group" "litellm" {
  replication_group_id       = "${var.name_prefix}-litellm-redis"
  description                = "LiteLLM Redis cache for multi-node sync"
  engine                     = "redis"
  engine_version             = var.litellm_redis_engine_version
  node_type                  = var.litellm_redis_node_type
  num_cache_clusters         = var.litellm_redis_num_cache_clusters
  port                       = 6379
  parameter_group_name       = "default.redis7"
  subnet_group_name          = aws_elasticache_subnet_group.litellm.name
  security_group_ids         = [aws_security_group.litellm_redis.id]
  auth_token                 = data.aws_secretsmanager_secret_version.litellm_redis_auth_token.secret_string
  auth_token_update_strategy = "ROTATE"
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  kms_key_id                 = aws_kms_key.invocation_logs.arn
  apply_immediately          = true

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-litellm-redis" })
}