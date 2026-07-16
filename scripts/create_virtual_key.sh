#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_PATH="${CONFIG_PATH:-${REPO_ROOT}/terragrunt/ai_gateway/configuration_files/litellm_config.yaml}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
NAME_PREFIX="${NAME_PREFIX:-ai-gateway}"
MASTER_KEY_SECRET_ID="${MASTER_KEY_SECRET_ID:-${NAME_PREFIX}/litellm/master-key}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-}"
MASTER_KEY="${LITELLM_MASTER_KEY:-}"
MODEL_ALIAS=""
DURATION=""
KEY_ALIAS=""

usage() {
  cat <<EOF
Usage: ./scripts/create_virtual_key.sh --url <litellm_base_url> [options]

Provisions a new LiteLLM virtual API key restricted to the model alias declared
in ${CONFIG_PATH}.

Required:
  --url <url>                 LiteLLM base URL, for example https://gateway.example.ca

Options:
  --duration <value>          Key lifetime passed to /key/generate, for example 30d
  --key-alias <name>          Human-friendly label stored with the generated key
  --model-alias <name>        Override the model alias instead of reading config.yaml
  --config <path>             Alternate LiteLLM config file to inspect
  --master-key <key>          Admin master key; defaults to LITELLM_MASTER_KEY or Secrets Manager
  --master-key-secret-id <id> Secrets Manager secret id for the master key
  --region <aws-region>       AWS region for the Secrets Manager lookup
  -h, --help                  Show this help message

Environment fallbacks:
  LITELLM_BASE_URL
  LITELLM_MASTER_KEY
  AWS_REGION
  NAME_PREFIX
  MASTER_KEY_SECRET_ID
  CONFIG_PATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      LITELLM_BASE_URL="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --key-alias)
      KEY_ALIAS="$2"
      shift 2
      ;;
    --model-alias)
      MODEL_ALIAS="$2"
      shift 2
      ;;
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --master-key)
      MASTER_KEY="$2"
      shift 2
      ;;
    --master-key-secret-id)
      MASTER_KEY_SECRET_ID="$2"
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

if [[ -z "$LITELLM_BASE_URL" ]]; then
  echo "Error: LiteLLM base URL is required. Use --url or set LITELLM_BASE_URL." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "Error: config file not found at ${CONFIG_PATH}." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is not installed or not on PATH." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is not installed or not on PATH." >&2
  exit 1
fi

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

if [[ -z "$MASTER_KEY" ]]; then
  if ! command -v aws >/dev/null 2>&1; then
    echo "Error: aws CLI is required to fetch the master key from Secrets Manager." >&2
    exit 1
  fi

  MASTER_KEY="$(aws secretsmanager get-secret-value \
    --secret-id "$MASTER_KEY_SECRET_ID" \
    --region "$AWS_REGION" \
    --query 'SecretString' \
    --output text)"
fi

if [[ "$MASTER_KEY" != sk-* ]]; then
  echo "Error: LiteLLM master key must start with sk-." >&2
  exit 1
fi

BASE_URL="${LITELLM_BASE_URL%/}"
RESPONSE_FILE="$(mktemp)"
cleanup() {
  rm -f "$RESPONSE_FILE"
}
trap cleanup EXIT

HTTP_STATUS="$(python3 - "$MODEL_ALIAS" "$DURATION" "$KEY_ALIAS" <<'PY' | curl -sS -o "$RESPONSE_FILE" -w '%{http_code}' \
  -X POST "${BASE_URL}/key/generate" \
  -H "Authorization: Bearer ${MASTER_KEY}" \
  -H 'Content-Type: application/json' \
  --data-binary @-
import json
import sys

payload = {
    "models": [sys.argv[1]],
    "metadata": {
        "provisioned_by": "scripts/create_virtual_key.sh",
    },
}

if sys.argv[2]:
    payload["duration"] = sys.argv[2]

if sys.argv[3]:
    payload["key_alias"] = sys.argv[3]

print(json.dumps(payload))
PY
)"

if [[ ! "$HTTP_STATUS" =~ ^2 ]]; then
  echo "Virtual key generation failed with HTTP ${HTTP_STATUS}." >&2
  cat "$RESPONSE_FILE" >&2
  exit 1
fi

python3 - "$RESPONSE_FILE" "$MODEL_ALIAS" "$BASE_URL" <<'PY'
import json
import pathlib
import sys

response = json.loads(pathlib.Path(sys.argv[1]).read_text())
key_value = response.get("key") or response.get("token")

if not key_value:
    raise SystemExit(f"Success response did not include a key field: {response}")

print(f"Generated virtual key for model alias: {sys.argv[2]}")
print(f"LiteLLM base URL: {sys.argv[3]}")
print(f"Virtual key: {key_value}")

expires = response.get("expires") or response.get("expiration")
if expires:
    print(f"Expires: {expires}")
PY