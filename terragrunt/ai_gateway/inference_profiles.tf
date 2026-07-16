# anthropic.claude-sonnet-4-6 is not available as a direct foundation model in
# ca-central-1 and does not support on-demand invocation by raw model ID.
#
# global.anthropic.claude-sonnet-4-6 is an AWS-managed system-defined inference
# profile that IS active from ca-central-1 and is NOT blocked by the SCP
# (which only denies us.*, eu.*, apac.* prefixes). Consumers must use the
# system-defined profile ID directly — no application inference profile wrapper
# is needed or possible (CreateInferenceProfile rejects system-defined profiles
# as copy_from sources).
#
# Model ID for consumers: global.anthropic.claude-sonnet-4-6
# IAM coverage:           foundation-model/* wildcard in BedrockConsumer policy
