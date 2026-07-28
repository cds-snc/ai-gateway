# Staging-only non-sensitive Terragrunt environment inputs for ai_gateway.
# Usage:
#   cp staging.tfvars.example staging.hcl
#   terragrunt plan
#   terragrunt apply

inputs = {
	name_prefix         = "ai-gateway"
	billing_tag_value   = "SRE"
	data_classification = "unclassified"
	primary_region      = "ca-central-1"

	vpc_cidr                       = "10.80.0.0/16"
	subnet_cidrs                   = ["10.80.0.0/24", "10.80.1.0/24"]
	public_subnet_cidrs            = ["10.80.100.0/24", "10.80.101.0/24"]
	allowed_endpoint_ingress_cidrs = ["10.0.0.0/8"]

	enable_prompt_and_completion_logging = true

	litellm_image                = "ghcr.io/berriai/litellm-database:v1.90.2"
	litellm_desired_count        = 1
	litellm_force_redeploy_token = ""

	litellm_database_name     = "litellm"
	litellm_database_username = "litellm_admin"
	litellm_postgres_ssl_mode = "require"

	litellm_rds_engine_version          = "16.4"
	litellm_rds_instance_class          = "db.serverless"
	litellm_rds_instances               = 1
	litellm_rds_serverless_min_capacity = 0.5
	litellm_rds_serverless_max_capacity = 4
	litellm_rds_backup_retention_period = 7
	litellm_rds_preferred_backup_window = "03:00-04:00"

	litellm_redis_engine_version     = "7.1"
	litellm_redis_node_type          = "cache.t4g.micro"
	litellm_redis_num_cache_clusters = 1

	litellm_config_s3_key        = "litellm/config.yaml"
	litellm_local_model_cost_map = "True"

	# Gateway DNS/TLS: HTTPS is mandatory in this module.
	gateway_domain_name = "ai.cdssandbox.xyz"
	# Leave empty to auto-request/manage ACM cert in this account.
	gateway_certificate_arn           = ""
	gateway_subject_alternative_names = []
	gateway_tls_policy                = "ELBSecurityPolicy-TLS13-1-2-2021-06"

	approved_public_listener_ports = [80, 443]
	public_ingress_cidrs           = ["0.0.0.0/0"]

	enable_alb_access_logs = true
	alb_access_logs_prefix = "alb-access"

	listener_nacl_rule_start         = 60
	health_check_interval_seconds    = 15
	health_check_timeout_seconds     = 5
	health_check_healthy_threshold   = 3
	health_check_unhealthy_threshold = 2

	litellm_container_port = 4000
	litellm_task_cpu       = 1024
	litellm_task_memory    = 2048
	litellm_use_redis      = false

	# Azure workload identity federation (AWS litellm_task role -> Azure
	# managed identity) for provisioning/rotating Azure OpenAI keys.
	# azure_tenant_id and azure_subscription_id are account-specific and must
	# be supplied via TF_VAR_* environment variables or a gitignored
	# staging.auto.tfvars rather than committed here. See README.md. The AWS
	# outbound web identity federation issuer URL is managed directly by
	# Terraform (aws_iam_outbound_web_identity_federation) and does not need
	# to be supplied here.
	azure_location              = "canadacentral"
	azure_resource_group_name   = "ai-gateway-openai"
	azure_create_resource_group = true
	azure_managed_identity_name = "ai-gateway-litellm-openai-provisioner"
	azure_federation_audience   = "api://AzureADTokenExchange"

	# Inference-only identity (data plane) and the Azure OpenAI account itself.
	azure_inference_identity_name = "ai-gateway-litellm-openai-inference"
	azure_openai_account_name     = "ai-gateway-openai-account"
	azure_openai_sku_name         = "S0"
	# Leave empty to default to azure_openai_account_name.
	azure_openai_custom_subdomain_name = ""

	# Sidecar that refreshes the Azure federated token file (litellm_ecs.tf).
	azure_token_sidecar_image                      = "public.ecr.aws/aws-cli/aws-cli:2.36.6"
	azure_federated_token_refresh_duration_seconds = 300
}
