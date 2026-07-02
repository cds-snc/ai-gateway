# -----------------------------------------------------------------------------
# BedrockConsumer-bifrost: ECS task role for the Bifrost AI gateway.
# The name matches the StringLike condition on the Bedrock VPC endpoint policies
# (arn:.../role/BedrockConsumer-*), so no endpoint policy changes are needed.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "bifrost_task_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "bifrost_task" {
  name               = "BedrockConsumer-bifrost"
  assume_role_policy = data.aws_iam_policy_document.bifrost_task_assume.json

  tags = local.common_tags
}

resource "aws_iam_role_policy" "bifrost_task" {
  name = "BedrockConsumer-bifrost-policy"
  role = aws_iam_role.bifrost_task.id

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
        # Required for ECS Exec (enable_execute_command = true)
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

# -----------------------------------------------------------------------------
# Extra policy document for the ECS task execution role that the CDS-SNC ECS
# module auto-creates. This adds Secrets Manager + KMS permissions on top of
# the ECR and CloudWatch permissions the module provides by default.
# -----------------------------------------------------------------------------

data "aws_iam_policy_document" "bifrost_exec_extra" {
  statement {
    sid    = "AllowGetEncryptionKey"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.bifrost_encryption_key.arn]
  }

  statement {
    sid    = "AllowGetBifrostConfigJson"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue"
    ]
    resources = [aws_secretsmanager_secret.bifrost_config_json.arn]
  }

  statement {
    sid    = "AllowDecryptEncryptionKey"
    effect = "Allow"
    actions = [
      "kms:Decrypt"
    ]
    resources = [aws_kms_key.invocation_logs.arn]
  }
}
