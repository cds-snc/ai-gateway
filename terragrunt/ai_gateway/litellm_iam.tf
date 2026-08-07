data "aws_iam_policy_document" "litellm_task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "litellm_task" {
  name               = "BedrockConsumer-litellm"
  assume_role_policy = data.aws_iam_policy_document.litellm_task_assume.json

  tags = merge(local.common_tags, { ssc_cbrid = "22DH" })
}

resource "aws_iam_role_policy" "litellm_task" {
  name = "BedrockConsumer-litellm-policy"
  role = aws_iam_role.litellm_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockInvoke"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream",
          "bedrock:Rerank"
        ]
        Resource = [
          "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
          "arn:${data.aws_partition.current.partition}:bedrock:*::inference-profile/*",
          "arn:${data.aws_partition.current.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*",
          "arn:${data.aws_partition.current.partition}:bedrock:*:${data.aws_caller_identity.current.account_id}:application-inference-profile/*"
        ]
      },
      {
        Sid    = "AllowBedrockListModels"
        Effect = "Allow"
        Action = [
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel",
          "bedrock:ListInferenceProfiles",
          "bedrock:GetInferenceProfile"
        ]
        Resource = "*"
      },
      {
        Sid    = "AllowReadLiteLLMConfig"
        Effect = "Allow"
        Action = [
          "s3:GetObject"
        ]
        Resource = "${module.invocation_logs_bucket.s3_bucket_arn}/${var.litellm_config_s3_key}"
      },
      {
        Sid    = "AllowDecryptLiteLLMConfig"
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = [aws_kms_key.invocation_logs.arn]
      },
      {
        Sid    = "AllowSSMMessagesForExec"
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}

# Allows the LiteLLM ECS task role to request a short-lived JWT (via AWS
# Outbound Identity Federation) scoped only to the Azure AD token-exchange
# audience, which is exchanged for a Microsoft Entra ID access token as
# azurerm_user_assigned_identity.litellm_openai_provisioner (see
# azure_openai_role.tf). Requires the account-level, one-time
# `aws iam enable-outbound-web-identity-federation` step described in the
# README; this policy alone does not enable the feature.
resource "aws_iam_role_policy" "litellm_task_azure_federation" {
  name = "BedrockConsumer-litellm-azure-federation-policy"
  role = aws_iam_role.litellm_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowAzureADTokenExchangeWebIdentityToken"
        Effect = "Allow"
        Action = [
          "sts:GetWebIdentityToken"
        ]
        Resource = "*"
        Condition = {
          "ForAllValues:StringEquals" = {
            "sts:IdentityTokenAudience" = var.azure_federation_audience
          }
          NumericLessThanEquals = {
            "sts:DurationSeconds" = 300
          }
        }
      }
    ]
  })
}

data "aws_iam_policy_document" "litellm_exec_extra" {
  statement {
    sid    = "AllowReadLiteLLMMasterKey"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.litellm_master_key.arn]
  }

  statement {
    sid    = "AllowReadLiteLLMDBPassword"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.litellm_db_password.arn]
  }

  statement {
    sid    = "AllowReadLiteLLMRedisAuthToken"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.litellm_redis_auth_token.arn]
  }

  statement {
    sid    = "AllowDecryptLiteLLMSecrets"
    effect = "Allow"
    actions = [
      "kms:Decrypt"
    ]
    resources = [aws_kms_key.invocation_logs.arn]
  }

  # The azure-token-refresher sidecar (litellm_ecs.tf) logs to its own
  # CloudWatch log group, not the one the ECS module creates for the litellm
  # container, so the task exec role needs an explicit grant for it.
  statement {
    sid    = "AllowAzureTokenSidecarLogging"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["${aws_cloudwatch_log_group.azure_token_sidecar.arn}:*"]
  }
}