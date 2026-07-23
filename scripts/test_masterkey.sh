#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_PATH="${CONFIG_PATH:-${REPO_ROOT}/terragrunt/ai_gateway/configuration_files/litellm_config.yaml}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
SECRET_NAME="${SECRET_NAME:-ai-gateway/litellm/master-key}"
MODEL_ALIAS=""
PROMPT="Write a 3 line poem about reliable infrastructure."
MAX_TOKENS="128"
ENDPOINT="${ENDPOINT:-/v1/chat/completions}"

usage() {
  cat <<EOF
Usage: ./scripts/test_masterkey.sh --url <url-or-host> [options]

Fetches the LiteLLM master key from AWS Secrets Manager and sends a test
request to the backend. The script reads the first model alias from
${CONFIG_PATH} unless you override it.

Required:
  --url <url-or-host>         Remote LiteLLM base URL or host, for example https://gateway.example.ca or ai.cdssandbox.xyz

Options:
  --model-alias <name>        Override the model alias instead of reading config.yaml
  --prompt <text>             Prompt to send in the test request
  --max-tokens <count>        max_tokens for the request, default: ${MAX_TOKENS}
  --config <path>             Alternate LiteLLM config file to inspect
  --secret <name>             AWS Secrets Manager secret name, default: ${SECRET_NAME}
  --endpoint <path>           LiteLLM endpoint path, default: ${ENDPOINT}
  --region <region>           AWS region, default: ${AWS_REGION}
  -h, --help                  Show this help message

Environment fallbacks:
  LITELLM_BASE_URL
  CONFIG_PATH
  AWS_REGION
  SECRET_NAME

Prerequisites:
  - AWS credentials configured (via AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or IAM role)
  - AWS CLI installed
  - curl installed
  - python3 installed
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      LITELLM_BASE_URL="$2"
      shift 2
      ;;
    --model-alias)
      MODEL_ALIAS="$2"
      shift 2
      ;;
    --prompt)
      PROMPT="$2"
      shift 2
      ;;
    --max-tokens)
      MAX_TOKENS="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --secret)
      SECRET_NAME="$2"
      shift 2
      ;;
    --endpoint)
      ENDPOINT="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "$LITELLM_BASE_URL" ]]; then
  echo "Error: remote LiteLLM URL is required. Use --url or set LITELLM_BASE_URL." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Error: config file not found at ${CONFIG_PATH}." >&2
  exit 1
fi

# Check for required commands
for cmd in curl python3 aws; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is not installed or not on PATH." >&2
    exit 1
  fi
done

# Extract model alias from config if not provided
if [[ -z "$MODEL_ALIAS" ]]; then
  MODEL_ALIAS="$(python3 - "$CONFIG_PATH" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text()
match = re.search(r"^\s*-\s*model_name:\s*['\"]?([^'\"\s#]+)['\"]?", text, re.MULTILINE)
if not match:
    raise SystemExit("Could not find a model_name entry in config.yaml")
print(match.group(1))
PY
  )"
fi

if [[ ! "$MAX_TOKENS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-tokens must be an integer." >&2
  exit 1
fi

# Format base URL
BASE_URL="${LITELLM_BASE_URL%/}"
if [[ ! "$BASE_URL" =~ ^https?:// ]]; then
  BASE_URL="https://${BASE_URL}"
fi

echo "=== LiteLLM Masterkey Test ===" >&2
echo "AWS Region: ${AWS_REGION}" >&2
echo "Secret Name: ${SECRET_NAME}" >&2
echo "LiteLLM URL: ${BASE_URL}" >&2
echo "Model Alias: ${MODEL_ALIAS}" >&2
echo "Endpoint: ${ENDPOINT}" >&2
echo "" >&2

# Fetch masterkey from AWS Secrets Manager
echo "Fetching masterkey from AWS Secrets Manager..." >&2
MASTER_KEY=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text 2>/dev/null)

if [[ -z "$MASTER_KEY" ]]; then
  echo "Error: failed to fetch master key from AWS Secrets Manager." >&2
  echo "  Secret: ${SECRET_NAME}" >&2
  echo "  Region: ${AWS_REGION}" >&2
  echo "" >&2
  echo "Ensure:" >&2
  echo "  1. AWS credentials are configured" >&2
  echo "  2. You have permissions to read the secret" >&2
  echo "  3. The secret exists in the specified region" >&2
  exit 1
fi

echo "✓ Master key retrieved successfully" >&2
echo "Sending test request..." >&2
echo "" >&2

# Send test request with masterkey
python3 - "$PROMPT" "$MODEL_ALIAS" "$MAX_TOKENS" <<'PY' | curl -sS \
  -X POST "${BASE_URL}${ENDPOINT}" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  --data-binary @-
import json
import sys

payload = {
    "model": sys.argv[2],
    "messages": [
        {
            "role": "user",
            "content": sys.argv[1],
        }
    ],
    "max_tokens": int(sys.argv[3]),
}

print(json.dumps(payload))
PY
