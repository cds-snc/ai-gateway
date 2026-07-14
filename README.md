# Centralized Bedrock AI Gateway (Terraform + Terragrunt)

This repository contains a staging implementation of an AWS Bedrock gateway with:

- A dedicated VPC and Bedrock interface endpoints.
- A LiteLLM proxy running on ECS Fargate behind an internet-facing ALB.
- IAM roles for Bedrock access (currently hardcoded team-alpha and litellm roles).
- Bedrock invocation logging to S3 and CloudWatch, encrypted with KMS.
- CloudTrail management-event logging for Bedrock API activity.
- Aurora PostgreSQL (CDS RDS module) for LiteLLM persistent storage.
- Elasticache Redis for multi-node synchronization and caching.

## Current Repository Layout

- `terraform/modules/ai_gateway/`
  - Main infrastructure code (Terraform module + local Terragrunt config).
- `scripts/`
  - Helper scripts for Bedrock model listing and LiteLLM endpoint testing.

## What Is Implemented

### Network and Endpoints

- VPC created through the shared `cds-snc/terraform-modules//vpc` module.
- Interface endpoints for:
  - `bedrock-runtime`
  - `bedrock-agent-runtime`
- Endpoint policies restricted to roles matching `BedrockConsumer-*`.
- Additional NACL rules for ALB <-> ECS traffic on port `4000`.

### LiteLLM Runtime

- ECS Fargate service via shared `cds-snc/terraform-modules//ecs` module.
- Container image: `ghcr.io/berriai/litellm-database:main-v1.90.2`.
- Internet-facing ALB with:
  - HTTPS (`443`) serving application traffic when a certificate is configured
  - HTTP (`80`) permanently redirecting to HTTPS when HTTPS is enabled
  - Optional ACM certificate creation and DNS validation in this workload account
- Optional delegated Route53 child hosted zone support (for example `ai.cdssandbox.xyz`).
- ECS Exec enabled for debugging.
- LiteLLM configuration loaded from S3 object `litellm/config.yaml`.
- LiteLLM secrets in Secrets Manager:
  - `${name_prefix}/litellm/master-key`
  - `${name_prefix}/litellm/db-password`
  - `${name_prefix}/litellm/redis-auth-token`

### Data Stores

- Aurora PostgreSQL cluster via shared `cds-snc/terraform-modules//rds` module.
- Elasticache Redis replication group via native Terraform resources
  (no CDS module currently available).

### IAM

- `BedrockConsumer-litellm` task role for ECS.
- `BedrockConsumer-team-alpha` role with Bedrock invoke/list permissions.
- A customer-managed policy to allow assuming `BedrockConsumer-team-alpha`
  (attachment to IAM Identity Center permission sets must be done in the org
  management or delegated admin account).

### Logging and Encryption

- S3 invocation log bucket via shared `cds-snc/terraform-modules//S3` module.
- KMS key + alias for log encryption.
- CloudWatch log groups for invocation and guardrail events.
- Bedrock model invocation logging configuration.
- CloudTrail trail writing Bedrock management events to the same S3 bucket.

## Important Current-State Notes

- The repository does not currently include a `live/` Terragrunt structure.
  Deployments are run directly from `terraform/modules/ai_gateway`.
- `teams.yaml` exists as onboarding/reference data, but it is not currently
  consumed by Terraform resources in this module.
- There is no `scripts/redeploy-bifrost-config.sh` in this repository.
- `enable_prompt_and_completion_logging` currently defaults to `true` in
  `variables.tf`.

## Prerequisites

- AWS credentials with permissions for VPC, IAM, ECS, ALB, Route53, ACM,
  CloudTrail, KMS, S3, CloudWatch Logs, Bedrock, and Secrets Manager.
- Terraform `>= 1.6.0`.
- Terragrunt.
- AWS CLI and `jq` (for helper scripts).

## Configure

### 1. Update Terraform inputs

Edit `terraform/modules/ai_gateway/variables.tf` defaults or provide values
through Terragrunt/Terraform inputs for at least:

- `billing_tag_value`
- `vpc_cidr`
- `subnet_cidrs`
- `public_subnet_cidrs`
- `allowed_endpoint_ingress_cidrs`
- `litellm_master_key_placeholder` (or rotate secret after apply)
- `litellm_db_password_placeholder` (or rotate secret after apply)
- `litellm_redis_auth_token_placeholder` (or rotate secret after apply)

For custom gateway domains and certificate management in this repo, configure:

- `gateway_domain_name` (for example `ai.cdssandbox.xyz`)
- `gateway_certificate_arn` (optional existing ACM certificate ARN; leave empty to auto-create)

### 2. Update Terragrunt environment values

`terraform/modules/ai_gateway/terragrunt.hcl` reads:

- `AWS_REGION` (default `ca-central-1`)
- `AWS_ACCOUNT_ID` (default `123456789012`)

Set these in your environment before planning/applying.

## Deploy

Run from `terraform/modules/ai_gateway`:

```bash
cd terraform/modules/ai_gateway
terragrunt init
terragrunt plan
terragrunt apply
```

After apply, use the Terraform output `gateway_delegation_name_servers` to create
an NS delegation from the parent `cdssandbox.xyz` zone when delegation is managed
outside this repository/account.

## Helper Scripts

From repository root:

- List models exposed by LiteLLM virtual key:

```bash
bash scripts/list-models.sh <virtual_key> <litellm_base_url>
```

- Send a sample chat completion request to LiteLLM:

```bash
bash scripts/test-bedrock.sh <virtual_key> <litellm_base_url>
```

- Validate public reachability behavior and security boundary:

```bash
./scripts/verify_public_reachability.sh \
  --gateway-host <alb-dns-name> \
  --cluster ai-gateway-litellm \
  --service litellm \
  --region ca-central-1 \
  --target-group-arn <target-group-arn>
```

- List Bedrock inference-capable models/profiles in Canadian regions:

```bash
bash scripts/list_ca_inference_models.sh
```

## LiteLLM Secret Rotation

Secret values are Terraform-managed. Updating these variables in
`terraform/modules/ai_gateway/staging.tfvars` and re-running `terragrunt apply`
will:

- update the Secrets Manager values
- update Aurora PostgreSQL to use the new database password
- rotate the ElastiCache Redis auth token in place
- register a new LiteLLM ECS task definition revision so tasks restart on the
  new credentials

Inputs:

- `litellm_master_key_placeholder`
- `litellm_db_password_placeholder`
- `litellm_redis_auth_token_placeholder`

Optional manual rollout trigger:

- `litellm_force_redeploy_token`

For ad hoc emergency rotation outside Terraform, update the AWS resources and
Secrets Manager values together before redeploying LiteLLM. Rotating the secret
value alone creates drift and can break connectivity on the next task restart.

## Quick Validation Checklist

- `terragrunt plan` completes without unexpected changes.
- ALB DNS name resolves and target is healthy.
- HTTP endpoint redirects to HTTPS and HTTPS readiness check succeeds.
- `scripts/list-models.sh` returns model IDs using a valid virtual key.
- `scripts/test-bedrock.sh` returns a completion response.
- `scripts/verify_public_reachability.sh` returns PASS summary.
- LiteLLM readiness endpoint (`/health/readiness`) returns success.
- CloudTrail receives Bedrock management events.
- Bedrock invocation logs appear in S3 and CloudWatch.
