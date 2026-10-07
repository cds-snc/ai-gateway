# AI Gateway Model Selection Policy

Last reviewed: 2026-10-06

This document is the reference checklist for curating models exposed through the
AI Gateway. The October review uses the configured Bedrock and Azure model lists
and the local `models.json` access scan (plain-text output for `ca-central-1`,
despite its extension). It does not certify live availability or establish that
these are the latest releases outside the configured catalog.

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
7. Leave existing models tagged `archived` unchanged, including their aliases,
   reasoning settings, quotas, and routing. The curation rules below apply only
   to non-archived choices; archived models are retained for existing consumers.
   The explicitly requested GPT-5.6 deduplication below is an exception.
8. Keep only the newest configured version per distinct model family or role.
   Keep separate cost tiers or specialist capabilities only when they serve a
   distinct purpose, and reduce redundant size variants within a family.
9. Expose `-low`, `-medium`, and `-high` aliases for active reasoning models that
   support adjustable effort. Set `reasoning_effort` on the server so clients do
   not need to supply it. Do not invent effort controls for models with fixed or
   automatic reasoning. Existing archived reasoning aliases remain unchanged.
10. Retain at least one embedding model and one image-understanding model.

The provider restrictions are based on provider origin or explicit gateway
policy, not the AWS region used to serve the request. A cross-region inference
profile remains excluded if its underlying provider or model is on the
restricted list.

## Curated Choices

The October review removes 29 active aliases, reducing base choices from 49 to
20. The eight adjustable reasoning models have three explicit presets each,
giving 44 active aliases including presets. The initial curation preserved all
42 archived aliases; subsequent GPT-5.6 deduplication removes 18 redundant
archived aliases, leaving 24. All retained archived definitions are unchanged.
Azure deployments are unchanged; their aliases are generated from the deployment
YAML, and reasoning presets share the existing deployment rather than creating
additional Azure resources.

### Alias Naming

Active aliases use lowercase provider-prefixed names:
`<provider>-<family>-<version-or-tier>[-<effort>]`. Separate words with hyphens,
use dots for multi-part numeric versions (for example `5.5` and `3.5`), and
keep official family or tier identifiers such as `x5` and `27b`. Do not include
the hosting platform, region, inference-profile prefix, or deployment date.
Reasoning presets append `-low`, `-medium`, or `-high` to the base alias.
Archived aliases retain their existing names for compatibility.

| Previous active alias | Consistent alias |
| --- | --- |
| `claude-sonnet-5-5` | `anthropic-claude-sonnet-5.5` |
| `claude-opus-5-5` | `anthropic-claude-opus-5.5` |
| `meta-llama4-maverick` | `meta-llama-4-maverick` |
| `cohere-embed-v4` | `cohere-embed-4` |
| `cohere-rerank` | `cohere-rerank-3.5` |
| `mistral-devstral` | `mistral-devstral-2` |
| `gpt-5.4-mini` | `openai-gpt-5.4-mini` |
| `gpt-5.3-codex` | `openai-gpt-5.3-codex` |
| `text-embedding-3-large` | `openai-text-embedding-3-large` |
| `text-embedding-3-small` | `openai-text-embedding-3-small` |

These renames also apply to each affected model's reasoning presets, keeping
the same effort suffix. Other active aliases already follow this convention.
Clients and virtual-key model allowlists must use the new names after deployment;
the previous active names are not retained as duplicate aliases. Routing,
reasoning settings, quotas, and tags are unchanged. Azure's optional `alias`
field controls the public name independently of `name`, preserving existing
deployment names and Terraform resource addresses.

### GPT-5.6 Deduplication

GPT-5.6 had two archived Bedrock alias sets, `openai-gpt-5.6-*` and `gpt-5.6-*`,
with identical routing and reasoning settings. Keep the former Azure deployment
compatibility names `gpt-5.6-terra`, `gpt-5.6-luna`, and `gpt-5.6-sol`, plus
their `-low`, `-medium`, `-high`, `-xhigh`, and `-max` presets. Remove the 18
matching `openai-gpt-5.6-*` aliases as an explicit exception to archive
preservation. Clients and key model allowlists using a removed alias must switch
to the same name without the `openai-` prefix. This does not change the underlying
model, reasoning level, or AWS credential.

| Provider | Retained non-archived families | Selection rationale |
| --- | --- | --- |
| Anthropic | Claude Sonnet 5.5, Opus 5.5 | Latest configured version of each tier; low/medium/high presets |
| OpenAI / Bedrock | GPT-6.1 Sol, GPT-6 Luna, GPT-6 Astra | Latest configured version per tier; low/medium/high presets |
| OpenAI / Azure | GPT-5.4 Mini, GPT-5.3 Codex | Small-model and coding roles; low/medium/high presets |
| OpenAI / Azure | Text Embedding 3 Large, Small | Current embedding generation with quality/cost tiers |
| Amazon | Nova 2 Lite | Replaces older Nova chat choices; low/medium/high presets |
| Cohere | Embed v4, Rerank v3.5 | One Bedrock embedding and reranking choice; remove v3 embeddings and overlapping Titan/Amazon Rerank entries |
| Meta | Llama 4 Maverick | One current-generation Llama tier with vision; drop Scout |
| Mistral | Large 3 | One general-purpose Mistral choice; remove overlapping Ministral sizes |
| Mistral | Voxtral Small, Magistral Small, Devstral 2 | Audio, reasoning, and coding roles; drop Voxtral Mini |
| Google | Gemma 3 27B | One vision-capable Gemma size instead of three |
| NVIDIA | Nemotron Super 3 120B | One current-generation NVIDIA choice; drop Nano variants |
| Writer | Palmyra X5 | One Palmyra choice; remove the separate Vision 7B entry |

Magistral Small and Nemotron Super retain their base reasoning-capable aliases;
the review does not establish an adjustable Bedrock effort control for them.
Vision remains available through Claude, OpenAI, Llama 4, Gemma 3, and Nova 2
Lite, so removing Palmyra Vision does not remove image understanding.

The old Canada-only `amazon-nova-lite` chat route is removed in favor of Nova 2
Lite's US cross-region profile. This is not a Canada-only replacement; consumers
requiring Canadian-only chat processing need a separately verified current model.
No removed alias is silently redirected to a different model. Keys or clients
referencing removed non-archived aliases must select a retained model.

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

The following providers or models are excluded from new active choices by policy. The
listed IDs are models found in the 2026-08-19 inventories, including
system-defined inference profiles. Restrictions apply to all versions, not just
the IDs in this historical table. xAI is US-based and is excluded by the existing
gateway policy, not by the China-origin rule.

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
The subsequently configured `us.xai.grok-4.7` alias was also removed in the
October review. No non-archived China-origin model was present in the configured
list at that review; newer Kimi and Z.AI entries in the inventory remain excluded.

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
7. Remove superseded non-archived versions in the same family. Preserve archived
   entries, confirm embedding and vision coverage, and add fixed effort aliases
   only where the provider and deployed LiteLLM version support them.
8. Update this document when a new provider family is excluded or AWS adds a
   lifecycle entry.

This policy does not infer that every model absent from the AWS Legacy/EOL table
is permanently Active. The AWS API and console are authoritative for the
current lifecycle state.
