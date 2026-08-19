# Bedrock Model Selection Policy

Last reviewed: 2026-08-19

This document is the reference checklist for adding Amazon Bedrock models to the
AI Gateway. The source inventory for the review was `models.txt`, generated for
`us-east-1` on 2026-08-19.

## Selection Rules

1. Do not add a model that AWS lists as `Legacy` or `EOL`.
2. Do not add models developed by the China-based providers listed below.
3. Prefer models that are `OK` in the regional access scan.
4. Do not add provisioned-only models until a provisioned-throughput endpoint is
   intentionally managed.
5. Do not add models whose access scan only proves that permissions work but
   whose request body still needs adjustment.
6. When adding a model, record its exact Bedrock model ID, provider, region or
   inference-profile prefix, access result, and lifecycle status in the review
   notes or inventory.

The provider restrictions are based on provider origin or explicit gateway
policy, not the AWS region used to serve the request. A cross-region inference
profile remains excluded if its underlying provider or model is on the
restricted list.

## AWS Legacy and EOL Models

AWS uses the lifecycle states `Active`, `Legacy`, and `EOL`. The table below is
the complete set of models AWS listed as Legacy or pending EOL on the review
date. AWS's page does not list Active models in this table.

| Provider | Model ID | Legacy date | EOL date | Public extended access |
| --- | --- | --- | --- | --- |
| AI21 Labs | `ai21.jamba-1-5-large-v1:0` | 2026-05-26 | 2026-11-26 | 2026-08-26 |
| AI21 Labs | `ai21.jamba-1-5-mini-v1:0` | 2026-05-26 | 2026-11-26 | 2026-08-26 |
| Amazon | `amazon.nova-canvas-v1:0` | 2026-03-30 | 2026-09-30 | - |
| Amazon | `amazon.nova-reel-v1:0` | 2026-03-30 | 2026-09-30 | - |
| Amazon | `amazon.nova-reel-v1:1` | 2026-03-30 | 2026-09-30 | - |
| Amazon | `amazon.nova-premier-v1:0` | 2026-03-13 | 2026-09-14 | - |
| Amazon | `amazon.nova-sonic-v1:0` | 2026-03-13 | 2026-09-14 | - |
| Anthropic | `anthropic.claude-opus-4-1-20250805-v1:0` | 2026-07-08 | 2027-01-08 | 2026-10-08 |
| Anthropic | `anthropic.claude-sonnet-4-20250514-v1:0` | 2026-04-14 | 2026-10-14 | 2026-07-14 |
| Anthropic | `anthropic.claude-3-haiku-20240307-v1:0` | 2026-03-10 | 2026-09-10 | 2026-06-10 |
| Cohere | `cohere.command-r-v1:0` | 2026-02-19 | 2026-08-19 | 2026-05-19 |
| Cohere | `cohere.command-r-plus-v1:0` | 2026-02-19 | 2026-08-19 | 2026-05-19 |
| TwelveLabs | `twelvelabs.marengo-embed-2-7-v1:0` | 2026-05-29 | 2026-11-30 | 2026-08-29 |

AWS documentation says that Legacy models are scheduled for retirement, may
be unavailable to new customers, and cannot receive new provisioned-throughput
endpoints. Requests after the EOL date generally fail. Confirm current status
before every future model update because AWS may add new entries or change
published dates.

Source: [Amazon Bedrock model lifecycle](https://docs.aws.amazon.com/bedrock/latest/userguide/model-lifecycle.html)

## Excluded Providers and Models

The following providers or models are excluded from the gateway by policy. The
listed IDs are models found in the 2026-08-19 inventories, including
system-defined inference profiles.

| Provider | Organization / model family | Bedrock model IDs excluded |
| --- | --- | --- |
| DeepSeek | DeepSeek | `deepseek.v3.2`; `us.deepseek.r1-v1:0` |
| Qwen | Alibaba Cloud / Qwen | `qwen.qwen3-coder-next`; `qwen.qwen3-next-80b-a3b`; `qwen.qwen3-32b-v1:0`; `qwen.qwen3-vl-235b-a22b`; `qwen.qwen3-coder-30b-a3b-v1:0` |
| Kimi / Moonshot AI | Moonshot AI | `moonshotai.kimi-k2.5`; `moonshot.kimi-k2-thinking` |
| MiniMax | MiniMax | `minimax.minimax-m2`; `minimax.minimax-m2.1`; `minimax.minimax-m2.5` |
| Z.AI | Zhipu AI / Z.AI | `zai.glm-4.7-flash`; `zai.glm-4.7`; `zai.glm-5` |
| xAI | xAI | `us.xai.grok-4.6` |

These 16 IDs were removed from
`terragrunt/ai_gateway/configuration_files/litellm_config.yaml.tftpl` on
2026-08-19. They must not be reintroduced under a new LiteLLM alias. The xAI
profile was identified in the `ca-central-1` inventory and is excluded by
gateway policy despite being reachable.

## Adding a Future Model

Before editing `litellm_config.yaml.tftpl`:

1. Identify the provider and verify the provider's development origin from an
   AWS model card or the provider's official documentation.
2. Reject the model if the provider is in the China-developed table above.
3. Check AWS lifecycle status with the Bedrock console or
   `GetFoundationModel` / `ListFoundationModels`. Reject `Legacy` and `EOL`.
4. Confirm that the model is available in the intended region and supports the
   intended inference mode.
5. Run `scripts/list_inference_models.sh --region <region>` and require `OK`
   for the exact model or profile ID.
6. Add the exact ID and an intentional, stable LiteLLM alias. Keep the regional
   credential and routing tags consistent with nearby entries.
7. Update this document when a new provider family is excluded or AWS adds a
   lifecycle entry.

This policy does not infer that every model absent from the AWS Legacy/EOL table
is permanently Active. The AWS API and console are authoritative for the
current lifecycle state.
