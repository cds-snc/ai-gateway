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

  tags = local.common_tags
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
          "bedrock:InvokeModelWithResponseStream"
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
}