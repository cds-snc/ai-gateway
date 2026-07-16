#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_PATH="${CONFIG_PATH:-${REPO_ROOT}/terragrunt/ai_gateway/configuration_files/litellm_config.yaml}"
LITELLM_BASE_URL="${LITELLM_BASE_URL:-}"
MODEL_ALIAS=""
PROMPT="Write a 3 line poem about reliable infrastructure."
MAX_TOKENS="128"
VIRTUAL_KEY="${LITELLM_VIRTUAL_KEY:-}"

usage() {
  cat <<EOF
Usage: ./scripts/test_local_virtual_key.sh --key <virtual_key> [options]

Sends a test request to a remote LiteLLM endpoint using a virtual key. The
script reads the first model alias from ${CONFIG_PATH} unless you override it.

Required:
  --key <virtual_key>         LiteLLM virtual key to test
  --url <url-or-host>         Remote LiteLLM base URL or host, for example https://gateway.example.ca or ai.cdssandbox.xyz

Options:
  --model-alias <name>        Override the model alias instead of reading config.yaml
  --prompt <text>             Prompt to send in the test request
  --max-tokens <count>        max_tokens for the request, default: ${MAX_TOKENS}
  --config <path>             Alternate LiteLLM config file to inspect
  -h, --help                  Show this help message

Environment fallbacks:
  LITELLM_VIRTUAL_KEY
  LITELLM_BASE_URL
  CONFIG_PATH
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      VIRTUAL_KEY="$2"
      shift 2
      ;;
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

if [[ -z "$VIRTUAL_KEY" ]]; then
  echo "Error: virtual key is required. Use --key or set LITELLM_VIRTUAL_KEY." >&2
  exit 1
fi

if [[ -z "$LITELLM_BASE_URL" ]]; then
  echo "Error: remote LiteLLM URL is required. Use --url or set LITELLM_BASE_URL." >&2
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

if [[ ! "$MAX_TOKENS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-tokens must be an integer." >&2
  exit 1
fi

BASE_URL="${LITELLM_BASE_URL%/}"
if [[ ! "$BASE_URL" =~ ^https?:// ]]; then
  BASE_URL="https://${BASE_URL}"
fi

python3 - "$PROMPT" "$MODEL_ALIAS" "$MAX_TOKENS" <<'PY' | curl -sS \
  -X POST "${BASE_URL}/v1/chat/completions" \
  -H "Authorization: Bearer ${VIRTUAL_KEY}" \
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