locals {
  # Rendered here (rather than inline in the resource) so litellm_ecs.tf can
  # hash the same content for its redeploy-trigger token without
  # re-rendering the template.
  litellm_config_content = templatefile("${path.module}/${var.litellm_config_yaml}", {
    azure_deployments = local.azure_openai_deployments_ordered
  })
}

resource "aws_s3_object" "litellm_config" {
  bucket                 = module.invocation_logs_bucket.s3_bucket_id
  key                    = var.litellm_config_s3_key
  content                = local.litellm_config_content
  content_type           = "application/x-yaml"
  server_side_encryption = "aws:kms"
  kms_key_id             = aws_kms_key.invocation_logs.arn

  tags = merge(local.common_tags, { Name = "${var.name_prefix}-litellm-config" })
}