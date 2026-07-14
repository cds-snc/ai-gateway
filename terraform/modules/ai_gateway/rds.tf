data "aws_secretsmanager_secret_version" "litellm_rds_password" {
  secret_id  = aws_secretsmanager_secret.litellm_db_password.id
  depends_on = [aws_secretsmanager_secret_version.litellm_db_password]
}

module "litellm_rds" {
  source = "github.com/cds-snc/terraform-modules//rds?ref=main"

  name              = "litellm"
  database_name     = var.litellm_database_name
  username          = var.litellm_database_username
  password          = data.aws_secretsmanager_secret_version.litellm_rds_password.secret_string
  engine            = "aurora-postgresql"
  engine_version    = var.litellm_rds_engine_version
  instance_class    = var.litellm_rds_instance_class
  instances         = var.litellm_rds_instances
  use_proxy         = false
  vpc_id            = module.gateway_vpc.vpc_id
  subnet_ids        = toset(module.gateway_vpc.private_subnet_ids)
  billing_tag_value = var.billing_tag_value

  backup_retention_period             = var.litellm_rds_backup_retention_period
  preferred_backup_window             = var.litellm_rds_preferred_backup_window
  prevent_cluster_deletion            = false
  skip_final_snapshot                 = true
  serverless_min_capacity             = var.litellm_rds_serverless_min_capacity
  serverless_max_capacity             = var.litellm_rds_serverless_max_capacity
  iam_database_authentication_enabled = false
  security_group_ids                  = [aws_security_group.litellm_rds.id]
}