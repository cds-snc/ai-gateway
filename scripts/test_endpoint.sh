#!/usr/bin/env bash

set -euo pipefail

LITELLM_BASE_URL="${LITELLM_BASE_URL:-}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
SECRET_NAME="${SECRET_NAME:-ai-gateway/litellm/master-key}"
METHOD="${METHOD:-GET}"
ENDPOINT=""
DATA=""
HEADERS=()
TIMEOUT="${TIMEOUT:-30}"
VERBOSE="${VERBOSE:-false}"
INSECURE="${INSECURE:-false}"

usage() {
  cat <<EOF
Usage: ./scripts/test_endpoint.sh [--method METHOD] [--url BASE_URL] ENDPOINT [options]

Fetches the LiteLLM master key from AWS Secrets Manager and makes a request
to a specified endpoint on the LiteLLM backend.

Positional:
  ENDPOINT                    API endpoint path, e.g., /models, /v1/chat/completions

Required (can use env vars):
  --url <url-or-host>         Remote LiteLLM base URL or host, for example https://gateway.example.ca or ai.cdssandbox.xyz
                              Can also use LITELLM_BASE_URL env var

Options:
  --method <METHOD>           HTTP method (GET, POST, PUT, DELETE, etc.), default: GET
  --data <json>               Request body (for POST/PUT requests), pass as JSON string
  --header <name:value>       Add custom header, can be used multiple times
  --secret <name>             AWS Secrets Manager secret name, default: ${SECRET_NAME}
  --region <region>           AWS region, default: ${AWS_REGION}
  --timeout <seconds>         Curl timeout in seconds, default: ${TIMEOUT}
  --insecure                  Skip SSL certificate verification (use with caution)
  --verbose                   Enable verbose curl output for debugging
  -h, --help                  Show this help message

Environment fallbacks:
  LITELLM_BASE_URL
  AWS_REGION
  SECRET_NAME
  METHOD

Examples:
  # List models
  ./scripts/test_endpoint.sh --url https://gateway.example.ca /models

  # Get a specific model
  ./scripts/test_endpoint.sh --url gateway.example.ca /models/claude-haiku

  # Create a chat completion
  ./scripts/test_endpoint.sh --url gateway.example.ca --method POST /v1/chat/completions \\
    --data '{"model":"claude-haiku-4-5","messages":[{"role":"user","content":"Hello"}],"max_tokens":100}'

  # List API keys
  ./scripts/test_endpoint.sh --url gateway.example.ca /key/list

  # With custom headers
  ./scripts/test_endpoint.sh --url gateway.example.ca /models \\
    --header "Accept: application/json" \\
    --header "X-Custom-Header: value"

  # With debugging (verbose output + extended timeout)
  ./scripts/test_endpoint.sh --url gateway.example.ca /models \\
    --verbose --timeout 60

  # Skip SSL verification (for self-signed certificates)
  ./scripts/test_endpoint.sh --url gateway.example.ca /models --insecure

Prerequisites:
  - AWS credentials configured (via AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY or IAM role)
  - AWS CLI installed
  - curl installed
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)
      LITELLM_BASE_URL="$2"
      shift 2
      ;;
    --method)
      METHOD="$2"
      shift 2
      ;;
    --data)
      DATA="$2"
      shift 2
      ;;
    --header)
      HEADERS+=("$2")
      shift 2
      ;;
    --secret)
      SECRET_NAME="$2"
      shift 2
      ;;
    --region)
      AWS_REGION="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --insecure)
      INSECURE="true"
      shift
      ;;
    --verbose)
      VERBOSE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ -z "$ENDPOINT" ]]; then
        ENDPOINT="$1"
      else
        echo "Unexpected argument: $1" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate required arguments
if [[ -z "$LITELLM_BASE_URL" ]]; then
  echo "Error: remote LiteLLM URL is required. Use --url or set LITELLM_BASE_URL." >&2
  exit 1
fi

if [[ -z "$ENDPOINT" ]]; then
  echo "Error: endpoint is required (e.g., /models, /v1/chat/completions)" >&2
  usage >&2
  exit 1
fi

# Check for required commands
for cmd in curl aws; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: $cmd is not installed or not on PATH." >&2
    exit 1
  fi
done

# Format base URL
BASE_URL="${LITELLM_BASE_URL%/}"
if [[ ! "$BASE_URL" =~ ^https?:// ]]; then
  BASE_URL="https://${BASE_URL}"
fi

# Normalize endpoint
if [[ ! "$ENDPOINT" =~ ^/ ]]; then
  ENDPOINT="/${ENDPOINT}"
fi

FULL_URL="${BASE_URL}${ENDPOINT}"

echo "=== LiteLLM Endpoint Test ===" >&2
echo "Method: ${METHOD}" >&2
echo "URL: ${FULL_URL}" >&2
echo "AWS Region: ${AWS_REGION}" >&2
echo "Secret Name: ${SECRET_NAME}" >&2
echo "Timeout: ${TIMEOUT}s" >&2
if [[ "$VERBOSE" == "true" ]]; then
  echo "Verbose: enabled" >&2
fi
if [[ "$INSECURE" == "true" ]]; then
  echo "SSL Verification: disabled (insecure)" >&2
fi
if [[ ${#HEADERS[@]} -gt 0 ]]; then
  echo "Custom Headers: ${#HEADERS[@]}" >&2
fi
echo "" >&2

# Fetch masterkey from AWS Secrets Manager
echo "Fetching masterkey from AWS Secrets Manager..." >&2

# Check AWS credentials first
if ! aws sts get-caller-identity &>/dev/null; then
  echo "Error: AWS credentials are not configured or invalid." >&2
  echo "  Please configure AWS credentials:" >&2
  echo "    - AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables" >&2
  echo "    - Or run 'aws configure'" >&2
  echo "    - Or use an IAM role if running on AWS infrastructure" >&2
  exit 1
fi

echo "✓ AWS credentials verified" >&2

# Fetch secret with timeout
if [[ "$VERBOSE" == "true" ]]; then
  echo "Fetching secret from: ${SECRET_NAME} (region: ${AWS_REGION})" >&2
fi

MASTER_KEY=$(timeout 10 aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --region "$AWS_REGION" \
  --query 'SecretString' \
  --output text)

EXIT_CODE=$?
if [[ $EXIT_CODE -eq 124 ]]; then
  echo "Error: AWS Secrets Manager request timed out (10s)." >&2
  echo "  The endpoint may be slow or unreachable." >&2
  exit 1
elif [[ $EXIT_CODE -ne 0 ]] || [[ -z "$MASTER_KEY" ]]; then
  echo "Error: failed to fetch master key from AWS Secrets Manager (exit code: $EXIT_CODE)." >&2
  echo "  Secret: ${SECRET_NAME}" >&2
  echo "  Region: ${AWS_REGION}" >&2
  echo "" >&2
  echo "Ensure:" >&2
  echo "  1. AWS credentials are configured" >&2
  echo "  2. You have permissions to read the secret" >&2
  echo "  3. The secret exists in the specified region" >&2
  echo "" >&2
  echo "For more details, run:" >&2
  echo "  aws secretsmanager get-secret-value --secret-id '${SECRET_NAME}' --region '${AWS_REGION}'" >&2
  exit 1
fi

echo "✓ Master key retrieved successfully" >&2
echo "Sending ${METHOD} request..." >&2
echo "" >&2

# Build curl command
CURL_ARGS=(
  -sS
  --max-time "$TIMEOUT"
  -X "$METHOD"
  "$FULL_URL"
  -H "Authorization: Bearer ${MASTER_KEY}"
  -H "Content-Type: application/json"
)

# Add verbose flag if requested
if [[ "$VERBOSE" == "true" ]]; then
  CURL_ARGS+=(-v)
fi

# Add insecure flag if requested
if [[ "$INSECURE" == "true" ]]; then
  CURL_ARGS+=(-k)
fi

# Add custom headers
for header in "${HEADERS[@]}"; do
  CURL_ARGS+=(-H "$header")
done

# Add data if provided
if [[ -n "$DATA" ]]; then
  CURL_ARGS+=(--data "$DATA")
fi

# Execute request
curl "${CURL_ARGS[@]}"

echo "" >&2
echo "✓ Request completed" >&2
