resource "aws_s3_object" "litellm_config" {
  bucket                 = module.invocation_logs_bucket.s3_bucket_id
  key                    = var.litellm_config_s3_key
  content                = file("${path.module}/${var.litellm_config_yaml}")
  content_type           = "application/x-yaml"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.invocation_logs.arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-litellm-config" })
}