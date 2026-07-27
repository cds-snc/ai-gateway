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

## Azure OpenAI Key Provisioning (AWS -> Azure Workload Identity Federation)

To let the LiteLLM ECS task provision and rotate Azure OpenAI (Cognitive
Services) API keys, this stack federates the existing AWS IAM task role
(`BedrockConsumer-litellm`, `aws_iam_role.litellm_task`) into an Azure
user-assigned managed identity using [AWS IAM Outbound Identity
Federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_outbound_getting_started.html)
and a Microsoft Entra ID [federated identity
credential](https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust-user-assigned-managed-identity).
No Azure client secret is stored anywhere.

Relevant files: `terragrunt/ai_gateway/azure_variables.tf`,
`azure_provider.tf`, `azure_openai_role.tf`, and the
`aws_iam_role_policy.litellm_task_azure_federation` resource in
`litellm_iam.tf`.

### One-time AWS account setup (out-of-band, not managed by this Terraform)

Enable outbound identity federation once per AWS account, then record the
issuer URL it returns:

```bash
aws iam enable-outbound-web-identity-federation
```

Use that issuer URL as `aws_outbound_federation_issuer_url`.

### Azure inputs

Supply these via `TF_VAR_*` environment variables or a gitignored
`*.auto.tfvars` file (not committed to `staging.hcl`, since they are
account-specific):

- `azure_tenant_id`
- `azure_subscription_id`
- `aws_outbound_federation_issuer_url`

The applying identity/service principal needs Azure `Contributor` (or
`Owner`) on the target subscription/resource group to create the managed
identity, federated credential, custom role definition, and role
assignment.

### How the ECS task uses this

At runtime, the task:

1. Calls AWS STS `GetWebIdentityToken` (permitted by
   `aws_iam_role_policy.litellm_task_azure_federation`) requesting audience
   `api://AzureADTokenExchange`, receiving a short-lived JWT with
   `sub = arn:aws:iam::<account>:role/BedrockConsumer-litellm`.
2. Exchanges that JWT for a Microsoft Entra ID access token via the OAuth2
   client-credentials flow, using `AZURE_CLIENT_ID` / `AZURE_TENANT_ID`
   (injected as container environment variables, see `litellm_ecs.tf`) and
   `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`.
3. Uses that access token to call the Azure Resource Manager API (scope
   `https://management.azure.com/.default`) and read/regenerate keys for
   Azure OpenAI accounts in `azure_resource_group_name`, then (recommended)
   writes the resulting key into AWS Secrets Manager for LiteLLM to consume
   as `AZURE_API_KEY`, matching LiteLLM's [Azure
   provider](https://docs.litellm.ai/docs/providers/azure/) configuration.

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
