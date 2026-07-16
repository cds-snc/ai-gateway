# Centralized Bedrock AI Gateway

This repository contains the staging infrastructure for an AWS Bedrock gateway built with Terraform and Terragrunt. The deployment centers on a LiteLLM proxy running on ECS Fargate behind an internet-facing ALB, with supporting networking, IAM, logging, and data services.

## Repository Layout

- `terragrunt/ai_gateway/`: main Terragrunt entrypoint and Terraform configuration
- `terragrunt/ai_gateway/configuration_files/litellm_config.yaml`: LiteLLM configuration uploaded to S3
- `scripts/`: helper scripts for imports, model discovery, validation, and operational tasks

## What This Stack Provisions

- VPC, subnets, and Bedrock interface endpoints
- LiteLLM on ECS Fargate behind an ALB with HTTPS support
- Aurora PostgreSQL for LiteLLM persistent storage
- Redis for optional synchronization and caching
- IAM roles and policies for Bedrock access
- S3, CloudWatch, CloudTrail, and KMS resources for logging and encryption

## Prerequisites

- AWS credentials with permissions for the resources managed in `terragrunt/ai_gateway/`
- Terraform
- Terragrunt
- AWS CLI

## Configuration

Primary environment inputs live in `terragrunt/ai_gateway/staging.hcl`.

Review and update values there before planning or applying, especially:

- `billing_tag_value`
- `vpc_cidr`
- `subnet_cidrs`
- `public_subnet_cidrs`
- `allowed_endpoint_ingress_cidrs`
- `gateway_domain_name`
- `gateway_certificate_arn`

`terragrunt/ai_gateway/terragrunt.hcl` also reads these environment variables:

- `AWS_REGION` with default `ca-central-1`
- `AWS_ACCOUNT_ID` with default `123456789012`

## Planning And Applying Locally

Running `terragrunt plan` or `terragrunt apply` from your machine will not work unless you provide the secret values this stack expects.

At minimum, local plan and apply runs need values for:

- the database password
- the Redis auth token
- the LiteLLM master key

You can either:

- generate replacement values for local infrastructure changes
- read the current deployed values from AWS Secrets Manager and supply them before planning or applying

In this stack, those secrets are stored in Secrets Manager under:

- `${name_prefix}/litellm/db-password`
- `${name_prefix}/litellm/redis-auth-token`
- `${name_prefix}/litellm/master-key`

## Deploy

Run from `terragrunt/ai_gateway/`:

```bash
cd terragrunt/ai_gateway
terragrunt init
terragrunt plan
terragrunt apply
```

## Helper Scripts

Run these from the repository root as needed:

- List models exposed by a LiteLLM virtual key:

```bash
bash scripts/list-models.sh <virtual_key> <litellm_base_url>
```

- Send a sample chat completion request through LiteLLM:

```bash
bash scripts/test-bedrock.sh <virtual_key> <litellm_base_url>
```

- List Bedrock inference-capable models or profiles in Canadian regions:

```bash
bash scripts/list_ca_inference_models.sh
```

- Validate public reachability and ALB target health:

```bash
./scripts/verify_public_reachability.sh \
  --gateway-host <alb-dns-name> \
  --cluster ai-gateway-litellm \
  --service litellm \
  --region ca-central-1 \
  --target-group-arn <target-group-arn>
```

- Generate Terraform import commands for existing resources:

```bash
python3 scripts/generate_imports.py
```

## Validation

Basic post-deploy checks:

- `terragrunt plan` completes without unexpected changes
- the ALB DNS name resolves and targets become healthy
- `scripts/list-models.sh` returns model IDs with a valid virtual key
- `scripts/test-bedrock.sh` returns a successful response
- `scripts/verify_public_reachability.sh` reports a passing result
