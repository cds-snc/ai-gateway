#!/usr/bin/env bash
# check_bedrock_model_access.sh
#
# Confirms which Bedrock models/inference-profiles from
# configuration_files/litellm_config.yaml.tftpl can actually be invoked with
# your current local AWS credentials (or an assumed role). Classifies
# failures (access-denied vs marketplace-subscription-required vs
# not-found vs validation) instead of just pass/fail, since a validation
# error still proves the caller reached the model.
#
# Usage: ./scripts/check_bedrock_model_access.sh [options]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CONFIG_PATH="${CONFIG_PATH:-${REPO_ROOT}/terragrunt/ai_gateway/configuration_files/litellm_config.yaml.tftpl}"
REGION="${AWS_REGION:-ca-central-1}"
ASSUME_ROLE_ARN=""
MODEL_FILTER=""
VERBOSE="false"

usage() {
  cat <<EOF
Usage: ./scripts/check_bedrock_model_access.sh [options]

Parses the aws_bedrock model entries out of
${CONFIG_PATH#"${REPO_ROOT}/"} and attempts a minimal invocation of each
one, reporting whether your current AWS credentials can call it.

Options:
  --config <path>       Alternate litellm config file to parse, default:
                         ${CONFIG_PATH#"${REPO_ROOT}/"}
  --region <region>      AWS region to call, default: ${REGION}
  --model <name-or-id>   Only test models whose alias or model id contains
                         this substring
  --assume-role <arn>    Assume this IAM role before testing (e.g. the
                         BedrockConsumer-litellm role) instead of using
                         ambient credentials
  --verbose              Print the raw AWS CLI error/output for each model
  -h, --help             Show this help message

Prerequisites:
  - AWS credentials configured (via AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY,
    SSO, or an IAM role) with at least read access to attempt bedrock:*
    calls -- this script surfaces AccessDenied itself as a result, it
    doesn't require the calls to succeed.
  - AWS CLI v2, awk

Examples:
  ./scripts/check_bedrock_model_access.sh
  ./scripts/check_bedrock_model_access.sh --model claude-sonnet-4-6 --verbose
  ./scripts/check_bedrock_model_access.sh --assume-role arn:aws:iam::986843603702:role/BedrockConsumer-litellm
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --model)
      MODEL_FILTER="$2"
      shift 2
      ;;
    --assume-role)
      ASSUME_ROLE_ARN="$2"
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

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}

require_cmd aws
require_cmd awk

if [[ ! -f "$CONFIG_PATH" ]]; then
  echo "ERROR: config file not found: $CONFIG_PATH" >&2
  exit 1
fi

if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
  echo "ERROR: AWS credentials are not configured or invalid." >&2
  exit 1
fi

if [[ -n "$ASSUME_ROLE_ARN" ]]; then
  echo "Assuming role: $ASSUME_ROLE_ARN" >&2
  creds="$(aws sts assume-role \
    --role-arn "$ASSUME_ROLE_ARN" \
    --role-session-name "check-bedrock-access" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID="$(echo "$creds" | awk '{print $1}')"
  AWS_SECRET_ACCESS_KEY="$(echo "$creds" | awk '{print $2}')"
  AWS_SESSION_TOKEN="$(echo "$creds" | awk '{print $3}')"
fi

echo "Region: $REGION"
echo "Caller: $(aws sts get-caller-identity --region "$REGION" --query Arn --output text)"
echo ""

# ---------------------------------------------------------------------------
# Parse "model_name" / "model" pairs for entries backed by the aws_bedrock
# credential (static YAML, unaffected by the azure_deployments templating in
# the same file).
# ---------------------------------------------------------------------------
mapfile -t MODEL_LINES < <(awk '
  /^[ ]{2}- model_name:/ {
    if (name != "" && cred == "aws_bedrock") print name "\t" model
    name = $0
    sub(/^[ ]{2}- model_name:[ ]*/, "", name)
    model = ""
    cred = ""
    next
  }
  /^[ ]{6}model:[ ]/ {
    model = $0
    sub(/^[ ]{6}model:[ ]*/, "", model)
    next
  }
  /^[ ]{6}litellm_credential_name:[ ]/ {
    cred = $0
    sub(/^[ ]{6}litellm_credential_name:[ ]*/, "", cred)
    next
  }
  END {
    if (name != "" && cred == "aws_bedrock") print name "\t" model
  }
' "$CONFIG_PATH")

if [[ ${#MODEL_LINES[@]} -eq 0 ]]; then
  echo "ERROR: no aws_bedrock model entries found in $CONFIG_PATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Classify an AWS CLI error/output blob into a short, human result.
# ---------------------------------------------------------------------------
classify() {
  local rc="$1" output="$2"
  if [[ "$rc" -eq 0 ]]; then
    echo "OK"
  elif grep -qi "marketplace\|ViewSubscriptions\|aws-marketplace:Subscribe" <<<"$output"; then
    echo "MARKETPLACE SUBSCRIPTION REQUIRED"
  elif grep -qi "AccessDeniedException" <<<"$output"; then
    echo "ACCESS DENIED"
  elif grep -qi "ResourceNotFoundException" <<<"$output"; then
    echo "NOT FOUND / NOT ENABLED IN REGION"
  elif grep -qi "ValidationException" <<<"$output"; then
    echo "REACHABLE (permissions OK, request body needs adjusting)"
  elif grep -qi "ThrottlingException" <<<"$output"; then
    echo "THROTTLED (retry)"
  else
    echo "ERROR (see --verbose)"
  fi
}

RESULTS=()
tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

for line in "${MODEL_LINES[@]}"; do
  alias_name="${line%%$'\t'*}"
  model_id="${line#*$'\t'}"
  model_id="${model_id#bedrock/}" # strip litellm-only provider prefix

  if [[ -n "$MODEL_FILTER" && "$alias_name" != *"$MODEL_FILTER"* && "$model_id" != *"$MODEL_FILTER"* ]]; then
    continue
  fi

  set +e
  if [[ "$model_id" == *rerank* ]]; then
    model_arn="arn:aws:bedrock:${REGION}::foundation-model/${model_id}"
    output="$(aws bedrock-agent-runtime rerank \
      --region "$REGION" \
      --queries '[{"textQuery":{"text":"ping"},"type":"TEXT"}]' \
      --sources '[{"inlineDocumentSource":{"textDocument":{"text":"pong"},"type":"TEXT"},"type":"INLINE"}]' \
      --reranking-configuration "{\"bedrockRerankingConfiguration\":{\"modelConfiguration\":{\"modelArn\":\"${model_arn}\"},\"numberOfResults\":1},\"type\":\"BEDROCK_RERANKING_MODEL\"}" \
      2>&1)"
    rc=$?
  elif [[ "$model_id" == *embed* ]]; then
    output="$(aws bedrock-runtime invoke-model \
      --region "$REGION" \
      --model-id "$model_id" \
      --body '{"texts":["ping"],"input_type":"search_document"}' \
      --cli-binary-format raw-in-base64-out \
      "$tmp_body" 2>&1)"
    rc=$?
  else
    output="$(aws bedrock-runtime converse \
      --region "$REGION" \
      --model-id "$model_id" \
      --messages '[{"role":"user","content":[{"text":"ping"}]}]' \
      --inference-config '{"maxTokens":8}' \
      2>&1)"
    rc=$?
  fi
  set -e

  result="$(classify "$rc" "$output")"
  RESULTS+=("$alias_name"$'\t'"$model_id"$'\t'"$result")

  if [[ "$VERBOSE" == "true" ]]; then
    echo "--- $alias_name ($model_id) ---"
    echo "$output"
    echo ""
  fi
done

echo ""
echo "=================================================================="
printf "%-24s %-42s %s\n" "MODEL ALIAS" "MODEL ID" "RESULT"
echo "=================================================================="
for r in "${RESULTS[@]}"; do
  IFS=$'\t' read -r alias_name model_id result <<<"$r"
  printf "%-24s %-42s %s\n" "$alias_name" "$model_id" "$result"
done
