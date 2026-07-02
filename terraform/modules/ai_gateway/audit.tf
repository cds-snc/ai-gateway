module "invocation_logs_bucket" {
  source = "github.com/cds-snc/terraform-modules//S3?ref=main"

  billing_tag_value = var.billing_tag_value
  bucket_name       = "${var.name_prefix}-${data.aws_caller_identity.current.account_id}-${var.primary_region}-invocation-logs"
  kms_key_arn       = aws_kms_key.invocation_logs.arn

  versioning = {
    enabled = true
  }

  tags = local.common_tags
}

resource "aws_cloudwatch_log_group" "invocation" {
  name              = "/aws/bedrock/${var.name_prefix}/invocations"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.invocation_logs.arn
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "guardrail_events" {
  name              = "/aws/bedrock/${var.name_prefix}/guardrail-events"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.invocation_logs.arn
  tags              = local.common_tags
}

resource "aws_bedrock_model_invocation_logging_configuration" "this" {
  depends_on = [aws_s3_bucket_policy.invocation_logs]

  logging_config {
    text_data_delivery_enabled      = var.enable_prompt_and_completion_logging

    s3_config {
      bucket_name = module.invocation_logs_bucket.s3_bucket_id
      key_prefix  = "invocations/"
    }

    cloudwatch_config {
      log_group_name             = aws_cloudwatch_log_group.invocation.name
      role_arn                   = aws_iam_role.bedrock_logging.arn
    }
  }
}

resource "aws_cloudtrail" "bedrock_audit" {
  depends_on = [aws_s3_bucket_policy.invocation_logs]

  name                          = "${var.name_prefix}-bedrock-audit"
  s3_bucket_name                = module.invocation_logs_bucket.s3_bucket_id
  s3_key_prefix                 = "cloudtrail"
  kms_key_id                    = aws_kms_key.invocation_logs.arn
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_logging                = true

  # Capture all Bedrock API calls as management events. InvokeModel, Converse,
  # and ConverseStream are logged by CloudTrail as management events (not data
  # events), so this selector is sufficient to capture every Claude Code call
  # regardless of whether traffic routes through the VPC endpoint or the public
  # Bedrock API. VPC flow logs only capture traffic inside the VPC; CloudTrail
  # is the correct tool for Bedrock API observability.
  advanced_event_selector {
    name = "BedrockManagementEvents"

    field_selector {
      field  = "eventCategory"
      equals = ["Management"]
    }
  }

  tags = local.common_tags
}