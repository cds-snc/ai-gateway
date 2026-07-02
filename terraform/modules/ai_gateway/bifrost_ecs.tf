module "bifrost" {
  source = "github.com/cds-snc/terraform-modules//ecs?ref=main"

  cluster_name = "${var.name_prefix}-bifrost"
  service_name = "bifrost"

  # Docker Hub public image — latest tag as requested
  container_image = "maximhq/bifrost:latest"

  # Fargate task sizing: 512 CPU / 2048 MB to avoid OOM kills during startup
  task_cpu    = 512
  task_memory = 2048

  # Port mapping
  container_port      = 8080
  container_host_port = 8080

  # Private subnets — tasks are not publicly accessible; traffic flows through ALB
  subnet_ids         = module.gateway_vpc.private_subnet_ids
  security_group_ids = [aws_security_group.bifrost_ecs.id]

  # Wire up to the ALB target group
  lb_target_group_arn = aws_lb_target_group.bifrost.arn

  # Use the pre-created task role so it is named BedrockConsumer-bifrost,
  # matching the StringLike condition on the Bedrock VPC endpoint policy
  task_role_arn = aws_iam_role.bifrost_task.arn

  # Extend the auto-created execution role with Secrets Manager + KMS access
  task_exec_role_policy_documents = [data.aws_iam_policy_document.bifrost_exec_extra.json]

  # Runtime environment — no secrets in env vars; key comes from Secrets Manager
  container_environment = [
    { name = "AWS_REGION", value = var.primary_region }
  ]

  # Share /app/data using task storage so an init container can write config.json
  # before Bifrost starts with its default entrypoint.
  # A second shared volume stages aws CLI for IAM DB auth token generation.
  task_volume = [
    { name = "bifrost-data" },
    { name = "bifrost-tools" }
  ]

  container_mount_points = [
    {
      containerPath = "/app/data"
      sourceVolume  = "bifrost-data"
      readOnly      = false
    },
    {
      containerPath = "/opt/bifrost"
      sourceVolume  = "bifrost-tools"
      readOnly      = true
    }
  ]

  container_depends_on = [
    {
      containerName = "bifrost-config-init"
      condition     = "SUCCESS"
    }
  ]

  # Init container writes BIFROST_CONFIG to shared volume and stages aws CLI
  # so password_command can generate RDS IAM auth tokens.
  container_definitions = [
    jsonencode({
      name      = "bifrost-config-init"
      image     = "public.ecr.aws/aws-cli/aws-cli:2.17.49"
      essential = false
      command = [
        "sh",
        "-c",
        "if [ -n \"$BIFROST_CONFIG\" ]; then mkdir -p /work && printf '%s' \"$BIFROST_CONFIG\" > /work/config.json; else echo \"ERROR: BIFROST_CONFIG not set\" >&2; exit 1; fi && mkdir -p /tools && cp -a /usr/local/aws-cli /tools/ && ln -sf /tools/aws-cli/v2/current/bin/aws /tools/aws"
      ]
      mountPoints = [
        {
          containerPath = "/work"
          sourceVolume  = "bifrost-data"
          readOnly      = false
        },
        {
          containerPath = "/tools"
          sourceVolume  = "bifrost-tools"
          readOnly      = false
        }
      ]
      secrets = [
        {
          name      = "BIFROST_CONFIG"
          valueFrom = aws_secretsmanager_secret.bifrost_config_json.arn
        }
      ]
    })
  ]

  container_secrets = [
    { name = "BIFROST_ENCRYPTION_KEY", valueFrom = aws_secretsmanager_secret.bifrost_encryption_key.arn },
    { name = "BIFROST_CONFIG", valueFrom = aws_secretsmanager_secret.bifrost_config_json.arn }
  ]

  # Bifrost writes SQLite data to /app/data — root filesystem must be writable
  container_read_only_root_filesystem = false

  # Rely on ALB target group health check (/health on port 8080);
  # the Bifrost image does not include curl/wget for a Docker HEALTHCHECK.

  # Allow ECS Exec for debugging (requires SSM messages perms on the task role)
  enable_execute_command = true

  # 1 task for staging — scale up when needed
  desired_count = 1

  # Retain logs for 30 days (module default)
  cloudwatch_log_group_retention_in_days = 30

  billing_tag_value = var.billing_tag_value
}
