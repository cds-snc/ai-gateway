data "aws_secretsmanager_secret_version" "litellm_db_password" {
  secret_id  = aws_secretsmanager_secret.litellm_db_password.id
  depends_on = [aws_secretsmanager_secret_version.litellm_db_password]
}

data "aws_secretsmanager_secret_version" "litellm_master_key" {
  secret_id  = aws_secretsmanager_secret.litellm_master_key.id
  depends_on = [aws_secretsmanager_secret_version.litellm_master_key]
}

locals {
  litellm_database_url = "postgresql://${var.litellm_database_username}:${urlencode(data.aws_secretsmanager_secret_version.litellm_db_password.secret_string)}@${module.litellm_rds.rds_cluster_endpoint}:5432/${var.litellm_database_name}?sslmode=${var.litellm_postgres_ssl_mode}"
  litellm_managed_secret_rollout_token = join(":", compact([
    var.litellm_force_redeploy_token,
    data.aws_secretsmanager_secret_version.litellm_db_password.version_id,
    data.aws_secretsmanager_secret_version.litellm_master_key.version_id,
    data.aws_secretsmanager_secret_version.litellm_redis_auth_token.version_id,
  ]))
}

module "litellm" {
  source = "github.com/cds-snc/terraform-modules//ecs?ref=main"

  depends_on = [
    module.litellm_rds,
    aws_elasticache_replication_group.litellm,
  ]

  cluster_name = "${var.name_prefix}-litellm"
  service_name = "litellm"

  container_image = var.litellm_image

  task_cpu    = var.litellm_task_cpu
  task_memory = var.litellm_task_memory

  container_port      = var.litellm_container_port
  container_host_port = var.litellm_container_port

  subnet_ids         = module.gateway_vpc.private_subnet_ids
  security_group_ids = [aws_security_group.litellm_ecs.id]

  lb_target_group_arn = aws_lb_target_group.litellm.arn

  task_role_arn = aws_iam_role.litellm_task.arn

  task_exec_role_policy_documents = [data.aws_iam_policy_document.litellm_exec_extra.json]

  container_environment = [
    { name = "AWS_REGION", value = var.primary_region },
    { name = "LITELLM_FORCE_REDEPLOY_TOKEN", value = local.litellm_managed_secret_rollout_token },
    { name = "DATABASE_URL", value = local.litellm_database_url },
    { name = "REDIS_HOST", value = aws_elasticache_replication_group.litellm.primary_endpoint_address },
    { name = "REDIS_PORT", value = "6379" },
    { name = "REDIS_SSL", value = "true" },
    { name = "LITELLM_CONFIG_BUCKET_TYPE", value = "s3" },
    { name = "LITELLM_CONFIG_BUCKET_NAME", value = module.invocation_logs_bucket.s3_bucket_id },
    { name = "LITELLM_CONFIG_BUCKET_OBJECT_KEY", value = var.litellm_config_s3_key },
    { name = "LITELLM_LOCAL_MODEL_COST_MAP", value = var.litellm_local_model_cost_map }
  ]

  container_secrets = [
    { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.litellm_master_key.arn },
    { name = "REDIS_PASSWORD", valueFrom = aws_secretsmanager_secret.litellm_redis_auth_token.arn }
  ]

  container_read_only_root_filesystem = false

  enable_execute_command = true

  desired_count = var.litellm_desired_count

  enable_autoscaling       = true
  autoscaling_min_capacity = var.litellm_desired_count
  autoscaling_max_capacity = var.litellm_desired_count + 1

  billing_tag_value = var.billing_tag_value
}