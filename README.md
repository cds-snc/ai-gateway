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

## Azure OpenAI Access (AWS -> Azure Workload Identity Federation)

This stack federates the existing AWS IAM task role (`BedrockConsumer-litellm`,
`aws_iam_role.litellm_task`) into **two** Azure user-assigned managed
identities using [AWS IAM Outbound Identity
Federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound_getting_started.html)
and a Microsoft Entra ID [federated identity
credential](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity)
per identity. No Azure client secret or Azure OpenAI API key is stored
anywhere:

- `azurerm_user_assigned_identity.litellm_openai_provisioner` — control
  plane. Authorized (via a custom role) to provision/rotate Azure OpenAI
  (Cognitive Services) accounts and keys.
- `azurerm_user_assigned_identity.litellm_openai_inference` — data plane.
  This is what the LiteLLM proxy itself authenticates as when calling Azure
  OpenAI, via a short-lived Entra ID access token. Authorized only with the
  built-in `Cognitive Services OpenAI User` role, scoped to the account.

Keeping these separate limits the blast radius of either identity being
compromised: the data-plane identity can invoke models but not read or
rotate keys, and vice versa.

Relevant files: `terragrunt/ai_gateway/azure_variables.tf`,
`azure_provider.tf`, `azure_openai_role.tf`, and the
`aws_iam_role_policy.litellm_task_azure_federation` resource in
`litellm_iam.tf`.

### AWS account setup

`azure_openai_role.tf` includes `aws_iam_outbound_web_identity_federation.this`,
which manages (enables) [AWS IAM Outbound Identity
Federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound_getting_started.html)
for this account and exposes its account-specific issuer URL as
`aws_iam_outbound_web_identity_federation.this.issuer_identifier` (also
available as the `aws_outbound_web_identity_federation_issuer_url` output).
This is used directly as the `issuer` on both Azure federated identity
credentials — no manual `aws iam enable-outbound-web-identity-federation`
step is required. Note that outbound identity federation can only be
managed by one Terraform resource per account.

### Azure inputs

Supply these via `TF_VAR_*` environment variables or a gitignored
`*.auto.tfvars` file (not committed to `staging.hcl`, since they are
account-specific):

- `azure_tenant_id`
- `azure_subscription_id`

The applying identity/service principal needs Azure `Contributor` (or
`Owner`) on the target subscription/resource group to create the Cognitive
Services account, managed identities, federated credentials, custom role
definition, and role assignments.

### How the ECS task uses this

**Control plane (key provisioning):** the task calls AWS STS
`GetWebIdentityToken` (permitted by
`aws_iam_role_policy.litellm_task_azure_federation`) requesting audience
`api://AzureADTokenExchange`, exchanges it for an Entra ID access token as
`litellm_openai_provisioner` (via `AZURE_PROVISIONER_CLIENT_ID` /
`AZURE_TENANT_ID`), then calls the Azure Resource Manager API to
provision/rotate Azure OpenAI accounts within `azure_resource_group_name`.

**Data plane (model calls):** a sidecar container in the same task
(`azure-token-refresher`, see `litellm_ecs.tf`) loops calling
`sts:GetWebIdentityToken` and writes the resulting JWT to a shared ephemeral
volume, refreshing at roughly half the token's lifetime. The LiteLLM
container reads `AZURE_CLIENT_ID` (the `litellm_openai_inference` identity's
client ID), `AZURE_TENANT_ID`, and `AZURE_FEDERATED_TOKEN_FILE` (the shared
volume path) — the same environment-variable convention AKS workload
identity uses — and its bundled `azure-identity` SDK exchanges that file's
JWT for a short-lived Entra ID access token automatically
(`litellm_settings.enable_azure_ad_token_refresh: true` in
`configuration_files/litellm_config.yaml`). No `AZURE_API_KEY` is ever set on
the LiteLLM container.

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

- Provision a new LiteLLM virtual key restricted to the Haiku model alias from `config.yaml`:

```bash
./scripts/create_virtual_key.sh \
  --url <litellm_base_url> \
  --duration 30d \
  --key-alias haiku-client
```

- Send a test chat completion request through a virtual key:

```bash
./scripts/test_virtual_key.sh \
  --key <virtual_key> \
  --url <litellm_base_url>
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

- Scale the LiteLLM ECS service to a specific desired task count:

```bash
bash scripts/set_ecs_task_desired_count.sh <desired_count>
```

- Force a new ECS deployment so tasks restart and reload the S3-backed config:

```bash
./scripts/restart_litellm.sh
# return immediately without waiting for stabilization
./scripts/restart_litellm.sh --no-wait
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
- `scripts/test_virtual_key.sh` returns a successful response
- `scripts/verify_public_reachability.sh` reports a passing result
