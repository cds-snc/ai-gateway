resource "aws_iam_role" "bedrock_logging" {
  name = "${var.name_prefix}-bedrock-logging-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "bedrock.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { ssc_cbrid = "22DH" })
}

resource "aws_iam_role_policy" "bedrock_logging" {
  name = "${var.name_prefix}-bedrock-logging-policy"
  role = aws_iam_role.bedrock_logging.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "WriteInvocationLogsToS3"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${module.invocation_logs_bucket.s3_bucket_arn}/*"
      },
      {
        Sid    = "UseInvocationKmsKey"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.invocation_logs.arn
      },
      {
        Sid    = "WriteCloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "${aws_cloudwatch_log_group.invocation.arn}:*"
      }
    ]
  })
}
# -----------------------------------------------------------------------------
# BedrockConsumer-team-alpha: assumable by the SSO admin role,
# with permission to invoke all Bedrock models in ca-central-1.
# -----------------------------------------------------------------------------

resource "aws_iam_role" "bedrock_consumer_team_alpha" {
  name                 = "BedrockConsumer-team-alpha"
  max_session_duration = 3600

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        AWS = "arn:aws:iam::986843603702:root"
      }
      Action = "sts:AssumeRole"
      Condition = {
        ArnLike = {
          "aws:PrincipalArn" = "arn:aws:iam::986843603702:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_Staging-Claude-Code_bcc8955f52925949"
        }
      }
    }]
  })

  tags = merge(local.common_tags, { ssc_cbrid = "22DH" })
}

resource "aws_iam_role_policy" "bedrock_consumer_team_alpha" {
  name = "BedrockConsumer-team-alpha-policy"
  role = aws_iam_role.bedrock_consumer_team_alpha.id

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
          # Foundation models — all regions (global.* and us.* inference profiles
          # route through us-east-1 under the hood; region must be * to match)
          "arn:${data.aws_partition.current.partition}:bedrock:*::foundation-model/*",
          # System-defined inference profiles (global.*, us.*, ca.*, etc.)
          "arn:${data.aws_partition.current.partition}:bedrock:*::inference-profile/*",
          # Account-owned and application inference profiles
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
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Grant the Staging-Claude-Code SSO permission set the ability to assume
# BedrockConsumer-team-alpha so that SSO users can invoke Bedrock models.
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "assume_bedrock_consumer_team_alpha" {
  name        = "${var.name_prefix}-assume-bedrock-consumer-team-alpha"
  description = "Allows the Staging-Claude-Code SSO permission set to assume BedrockConsumer-team-alpha."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "AssumeBedrockConsumerTeamAlpha"
      Effect   = "Allow"
      Action   = "sts:AssumeRole"
      Resource = aws_iam_role.bedrock_consumer_team_alpha.arn
    }]
  })

  tags = merge(local.common_tags, { ssc_cbrid = "22DH" })
}

# NOTE: aws_iam_policy.assume_bedrock_consumer_team_alpha (above) must be attached
# to the Staging-Claude-Code SSO permission set. This must be done from the AWS
# Organizations management account or its SSO delegated-admin account, as
# sso:ListPermissionSets / sso:AttachCustomerManagedPolicyToPermissionSet are
# not accessible from this member account.

resource "aws_s3_bucket_policy" "invocation_logs" {
  bucket = module.invocation_logs_bucket.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBedrockServiceValidationAndWrite"
        Effect = "Allow"
        Principal = {
          Service = "bedrock.amazonaws.com"
        }
        Action = [
          "s3:GetBucketAcl",
          "s3:PutObject"
        ]
        Resource = [
          module.invocation_logs_bucket.s3_bucket_arn,
          "${module.invocation_logs_bucket.s3_bucket_arn}/*"
        ]
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
      {
        Sid    = "AllowBedrockLoggingRoleWrite"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.bedrock_logging.arn
        }
        Action = [
          "s3:PutObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${module.invocation_logs_bucket.s3_bucket_arn}/*"
      },
      {
        Sid    = "AllowCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = module.invocation_logs_bucket.s3_bucket_arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.primary_region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}-bedrock-audit"
          }
        }
      },
      {
        Sid    = "AllowCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${module.invocation_logs_bucket.s3_bucket_arn}/cloudtrail/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:cloudtrail:${var.primary_region}:${data.aws_caller_identity.current.account_id}:trail/${var.name_prefix}-bedrock-audit"
          }
        }
      }
    ]
  })
}

resource "aws_s3_bucket_policy" "alb_access_logs" {
  bucket = module.alb_access_logs_bucket.s3_bucket_id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowAlbAccessLogsAclCheck"
      Effect = "Allow"
      Principal = {
        Service = "logdelivery.elasticloadbalancing.amazonaws.com"
      }
      Action   = "s3:GetBucketAcl"
      Resource = module.alb_access_logs_bucket.s3_bucket_arn
      }, {
      Sid    = "AllowAlbAccessLogsWrite"
      Effect = "Allow"
      Principal = {
        Service = "logdelivery.elasticloadbalancing.amazonaws.com"
      }
      Action   = "s3:PutObject"
      Resource = "${module.alb_access_logs_bucket.s3_bucket_arn}/${var.alb_access_logs_prefix}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      Condition = {
        StringEquals = {
          "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          "s3:x-amz-acl"      = "bucket-owner-full-control"
        }
        ArnLike = {
          "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:elasticloadbalancing:${var.primary_region}:${data.aws_caller_identity.current.account_id}:loadbalancer/*"
        }
      }
    }]
  })
}