# Centralized Bedrock AI Gateway (Terraform + Terragrunt)

This repository contains a staging implementation of an AWS Bedrock gateway with:

- A dedicated VPC and Bedrock interface endpoints.
- A Bifrost gateway running on ECS Fargate behind an internet-facing ALB.
- IAM roles for Bedrock access (currently hardcoded team-alpha and bifrost roles).
- Bedrock invocation logging to S3 and CloudWatch, encrypted with KMS.
- CloudTrail management-event logging for Bedrock API activity.

## Current Repository Layout

- `terraform/modules/ai_gateway/`
  - Main infrastructure code (Terraform module + local Terragrunt config).
- `scripts/`
  - Helper scripts for Bedrock model listing and Bifrost endpoint testing.
- `config.json`
  - Sample Bifrost auth config payload.

## What Is Implemented

### Network and Endpoints

- VPC created through the shared `cds-snc/terraform-modules//vpc` module.
- Interface endpoints for:
  - `bedrock-runtime`
  - `bedrock-agent-runtime`
- Endpoint policies restricted to roles matching `BedrockConsumer-*`.
- Additional NACL rules for ALB <-> ECS traffic on port `8080`.

### Bifrost Runtime

- ECS Fargate service via shared `cds-snc/terraform-modules//ecs` module.
- Container image: `maximhq/bifrost:latest`.
- Internet-facing ALB with:
  - HTTP (`80`) redirecting to HTTPS (`443`)
  - ACM certificate and Route53 zone/record for `bifrost.cdssandbox.xyz`
- ECS Exec enabled for debugging.
- Bifrost secrets in Secrets Manager:
  - `${name_prefix}/bifrost/encryption-key`
  - `${name_prefix}/bifrost/config-json`

### IAM

- `BedrockConsumer-bifrost` task role for ECS.
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
- `bifrost_auth_admin_password`

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

## Helper Scripts

From repository root:

- List models exposed by Bifrost virtual key:

```bash
bash scripts/list-models.sh <virtual_key> <bifrost_base_url>
```

- Send a sample chat completion request to Bifrost:

```bash
bash scripts/test-bedrock.sh <virtual_key> <bifrost_base_url>
```

- List Bedrock inference-capable models/profiles in Canadian regions:

```bash
bash scripts/list_ca_inference_models.sh
```

## Bifrost Config Handling

- `config.json` in repository root is a local sample file only.
- ECS tasks consume `BIFROST_CONFIG` from Secrets Manager
  (`${name_prefix}/bifrost/config-json`).
- If you update local `config.json`, you must manually push that JSON to the
  secret and redeploy/restart the ECS service.

Example secret update:

```bash
aws secretsmanager put-secret-value \
  --region ca-central-1 \
  --secret-id ai-gateway/bifrost/config-json \
  --secret-string file://config.json
```

## Quick Validation Checklist

- `terragrunt plan` completes without unexpected changes.
- `https://bifrost.cdssandbox.xyz` resolves and ALB target is healthy.
- `scripts/list-models.sh` returns model IDs using a valid virtual key.
- `scripts/test-bedrock.sh` returns a completion response.
- CloudTrail receives Bedrock management events.
- Bedrock invocation logs appear in S3 and CloudWatch.
