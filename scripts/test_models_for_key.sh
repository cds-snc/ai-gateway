#!/usr/bin/env bash

set -euo pipefail

BASE_URL="https://ai.cdssandbox.xyz"
API_KEY="${LITELLM_API_KEY:-}"
PROMPT="Write a haiku about Canada"
MAX_TOKENS="1024"
TIMEOUT="30"
OUTPUT_DIR=""
VERBOSE="false"

usage() {
  cat <<EOF
Usage: ./scripts/test_models_for_key.sh --key <api_key> [options]

Discovers models exposed by a LiteLLM/OpenAI-compatible gateway key, infers
chat vs embedding vs rerank capabilities, then sends one test request per model
and records pass/fail results.

Required:
  --key <api_key>             API key to test (or set LITELLM_API_KEY)

Options:
  --url <url-or-host>         Gateway base URL, default: ${BASE_URL}
  --prompt <text>             Prompt to send, default: "${PROMPT}"
  --max-tokens <count>        max_tokens for chat completion, default: ${MAX_TOKENS} (min needed for codex models)
  --timeout <seconds>         Curl timeout per request, default: ${TIMEOUT}
  --output-dir <path>         Directory for JSON reports, default: ./logs/model-tests/<timestamp>
  --verbose                   Print per-model status as requests run
  -h, --help                  Show this help message

Examples:
  ./scripts/test_models_for_key.sh --key sk-abc123
  ./scripts/test_models_for_key.sh --key sk-abc123 --url ai.cdssandbox.xyz
  ./scripts/test_models_for_key.sh --key sk-abc123 --prompt "Say hello in French"

Outputs:
  - summary.json: full run summary and per-model result list
  - failures.json: only failed model attempts with request/response context
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      API_KEY="$2"
      shift 2
      ;;
    --url)
      BASE_URL="$2"
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
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    --verbose)
      VERBOSE="true"
      shift
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

if [[ -z "$API_KEY" ]]; then
  echo "Error: API key is required. Use --key or set LITELLM_API_KEY." >&2
  exit 1
fi

if [[ ! "$MAX_TOKENS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-tokens must be an integer." >&2
  exit 1
fi

if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "Error: --timeout must be an integer number of seconds." >&2
  exit 1
fi

for cmd in curl python3 mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found on PATH: $cmd" >&2
    exit 1
  fi
done

NORMALIZED_BASE_URL="${BASE_URL%/}"
if [[ ! "$NORMALIZED_BASE_URL" =~ ^https?:// ]]; then
  NORMALIZED_BASE_URL="https://${NORMALIZED_BASE_URL}"
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="./logs/model-tests/${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"

SUMMARY_FILE="${OUTPUT_DIR}/summary.json"
FAILURES_FILE="${OUTPUT_DIR}/failures.json"
MODELS_FILE="$(mktemp)"

cleanup() {
  rm -f "$MODELS_FILE"
}
trap cleanup EXIT

echo "Discovering models from ${NORMALIZED_BASE_URL}/models ..." >&2
MODELS_HTTP_CODE="$(curl -sS -m "$TIMEOUT" -o "$MODELS_FILE" -w "%{http_code}" \
  -H "Authorization: Bearer ${API_KEY}" \
  "${NORMALIZED_BASE_URL}/models")"

if [[ "$MODELS_HTTP_CODE" -lt 200 || "$MODELS_HTTP_CODE" -ge 300 ]]; then
  echo "Error: failed to fetch models (HTTP ${MODELS_HTTP_CODE})." >&2
  echo "Response body:" >&2
  cat "$MODELS_FILE" >&2
  exit 1
fi

RUNNER="./scripts/test_models_for_key_runner.py"

MODEL_COUNT="$(python3 "$RUNNER" count --models-file "$MODELS_FILE")"

if [[ "$MODEL_COUNT" -eq 0 ]]; then
  echo "No models returned for this key. Writing empty reports to ${OUTPUT_DIR}" >&2
  python3 "$RUNNER" write-empty \
    --summary-file "$SUMMARY_FILE" \
    --failures-file "$FAILURES_FILE" \
    --base-url "$NORMALIZED_BASE_URL" \
    --prompt "$PROMPT" \
    --max-tokens "$MAX_TOKENS" \
    --timeout "$TIMEOUT"
  echo "summary: ${SUMMARY_FILE}" >&2
  echo "failures: ${FAILURES_FILE}" >&2
  exit 0
fi

echo "Discovered ${MODEL_COUNT} model(s). Testing models across chat/embedding/rerank endpoints..." >&2

RUNNER_ARGS=(
  run
  --models-file "$MODELS_FILE"
  --base-url "$NORMALIZED_BASE_URL"
  --api-key "$API_KEY"
  --prompt "$PROMPT"
  --max-tokens "$MAX_TOKENS"
  --timeout "$TIMEOUT"
  --summary-file "$SUMMARY_FILE"
  --failures-file "$FAILURES_FILE"
)

if [[ "$VERBOSE" == "true" ]]; then
  RUNNER_ARGS+=(--verbose)
fi

python3 "$RUNNER" "${RUNNER_ARGS[@]}"

echo "" >&2
echo "Run complete." >&2
echo "summary: ${SUMMARY_FILE}" >&2
echo "failures: ${FAILURES_FILE}" >&2