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
    md5(local.litellm_config_content),
  ]))

  # Shared ephemeral volume the azure-token-refresher sidecar writes the
  # federated token file to and the LiteLLM container reads it from.
  azure_token_volume_name = "azure-federated-token"
  azure_token_mount_dir   = "/azure-token"
  azure_token_file_path   = "${local.azure_token_mount_dir}/token.jwt"

  # Loops requesting a new AWS STS web identity token at half its lifetime
  # and atomically replaces the file so LiteLLM never reads a partial write.
  azure_token_refresher_script = join("; ", [
    "set -eu",
    "DURATION=${var.azure_federated_token_refresh_duration_seconds}",
    "while true; do aws sts get-web-identity-token --audience \"$AZURE_FEDERATION_AUDIENCE\" --signing-algorithm RS256 --duration-seconds \"$DURATION\" --query WebIdentityToken --output text > ${local.azure_token_file_path}.tmp && mv ${local.azure_token_file_path}.tmp ${local.azure_token_file_path} && sleep $((DURATION / 2)); done",
  ])

  # Sidecar container definition (in addition to the module's own litellm
  # container). essential = true so a stalled refresher fails the task
  # instead of letting the token silently expire.
  azure_token_refresher_container = jsonencode({
    name       = "azure-token-refresher"
    image      = var.azure_token_sidecar_image
    essential  = true
    entryPoint = ["/bin/sh", "-c"]
    command    = [local.azure_token_refresher_script]
    environment = [
      { name = "AWS_REGION", value = var.primary_region },
      { name = "AZURE_FEDERATION_AUDIENCE", value = var.azure_federation_audience },
    ]
    mountPoints = [
      { sourceVolume = local.azure_token_volume_name, containerPath = local.azure_token_mount_dir, readOnly = false }
    ]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.azure_token_sidecar.name
        "awslogs-region"        = var.primary_region
        "awslogs-stream-prefix" = "azure-token-refresher"
      }
    }
  })
}

# Dedicated log group for the sidecar so its container_definitions JSON does
# not need to reference module.litellm's own log group output (which would
# be a circular dependency on an input to the same module instance it feeds).
resource "aws_cloudwatch_log_group" "azure_token_sidecar" {
  name              = "/ecs/${var.name_prefix}-litellm/azure-token-refresher"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.invocation_logs.arn
  tags              = merge(local.common_tags, { ssc_cbrid = "22DH" })
}

module "litellm" {
  source = "github.com/cds-snc/terraform-modules//ecs?ref=v11.4.4"

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
    { name = "LITELLM_LOCAL_MODEL_COST_MAP", value = var.litellm_local_model_cost_map },
    # Control-plane identity: provisions/rotates Azure OpenAI keys. Kept
    # separate from the data-plane identity below. See azure_openai_role.tf.
    { name = "AZURE_PROVISIONER_CLIENT_ID", value = azurerm_user_assigned_identity.litellm_openai_provisioner.client_id },
    { name = "AZURE_SUBSCRIPTION_ID", value = var.azure_subscription_id },
    { name = "AZURE_RESOURCE_GROUP", value = var.azure_resource_group_name },
    # Data-plane identity: the azure-identity SDK's workload-identity
    # credential (used internally by LiteLLM when
    # enable_azure_ad_token_refresh is set, see configuration_files/
    # litellm_config.yaml) reads AZURE_CLIENT_ID / AZURE_TENANT_ID /
    # AZURE_FEDERATED_TOKEN_FILE automatically -- this is the AKS
    # workload-identity convention. No AZURE_API_KEY is set anywhere.
    { name = "AZURE_TENANT_ID", value = var.azure_tenant_id },
    { name = "AZURE_CLIENT_ID", value = azurerm_user_assigned_identity.litellm_openai_inference.client_id },
    { name = "AZURE_FEDERATED_TOKEN_FILE", value = local.azure_token_file_path },
    { name = "AZURE_API_BASE", value = azurerm_cognitive_account.openai.endpoint },
    { name = "AZURE_FEDERATION_AUDIENCE", value = var.azure_federation_audience },
    { name = "AZURE_CREDENTIAL", value = "WorkloadIdentityCredential" }
  ]

  container_secrets = [
    { name = "LITELLM_MASTER_KEY", valueFrom = aws_secretsmanager_secret.litellm_master_key.arn },
    { name = "REDIS_PASSWORD", valueFrom = aws_secretsmanager_secret.litellm_redis_auth_token.arn }
  ]

  container_read_only_root_filesystem = false

  # Shared volume + sidecar delivering the Azure federated token file (see
  # locals above). The litellm container mounts it read-only and waits for
  # the sidecar to write the initial token before starting.
  task_volume = [
    { name = local.azure_token_volume_name }
  ]

  container_mount_points = [
    { containerPath = local.azure_token_mount_dir, sourceVolume = local.azure_token_volume_name, readOnly = true }
  ]

  container_depends_on = [
    { containerName = "azure-token-refresher", condition = "START" }
  ]

  container_definitions = [local.azure_token_refresher_container]

  enable_execute_command = true

  desired_count = var.litellm_desired_count

  enable_autoscaling       = true
  autoscaling_min_capacity = var.litellm_desired_count
  autoscaling_max_capacity = var.litellm_desired_count + 1

  billing_tag_value = var.billing_tag_value
}