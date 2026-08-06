#!/usr/bin/env bash
# list_inference_models.sh
# Lists Bedrock inference-capable models/profiles in a given AWS region and,
# for each one, reports whether your current AWS credentials can actually
# invoke it: already accessible, needs an AWS Marketplace subscription, or
# flat-out access denied (SCP/IAM). Covers:
#   - Foundation models available in the region
#   - System-defined inference profiles available in the region
#   - Application inference profiles (account-owned) in the region
#
# Usage: ./scripts/list_inference_models.sh --region <region> [options]

set -euo pipefail

REGION=""
MODEL_FILTER=""
ASSUME_ROLE_ARN=""
VERBOSE="false"
SKIP_ACCESS_CHECK="false"

usage() {
  cat <<EOF
Usage: ./scripts/list_inference_models.sh --region <region> [options]

Lists Bedrock foundation models and inference profiles available in
<region>, then test-invokes each one with your current AWS credentials to
classify access as OK / MARKETPLACE SUBSCRIPTION REQUIRED / ACCESS DENIED /
etc., instead of just listing what exists.

Options:
  --region <region>      AWS region to query, e.g. ca-central-1 (required)
  --model <name-or-id>   Only list/test models whose id matches this regex
  --assume-role <arn>    Assume this IAM role before testing (e.g. the
                         BedrockConsumer-litellm role) instead of using
                         ambient credentials
  --skip-access-check    Only list models, don't attempt to invoke them
  --verbose              Print the raw AWS CLI error/output for each model
  -h, --help             Show this help message

Prerequisites:
  - AWS credentials configured (via AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY,
    SSO, or an IAM role) -- this script surfaces AccessDenied itself as a
    result, it doesn't require the calls to succeed.
  - AWS CLI v2, jq

Examples:
  ./scripts/list_inference_models.sh --region ca-central-1
  ./scripts/list_inference_models.sh --region us-east-1 --model claude-sonnet
  ./scripts/list_inference_models.sh --region ca-central-1 --skip-access-check
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
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
    --skip-access-check)
      SKIP_ACCESS_CHECK="true"
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
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$REGION" ]]; then
  echo "ERROR: --region is required" >&2
  usage >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
print_header() {
  echo ""
  echo "=================================================================="
  echo "  $*"
  echo "=================================================================="
}

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' is required but not installed." >&2
    exit 1
  fi
}

require_cmd aws
require_cmd jq

if ! aws sts get-caller-identity --region "$REGION" &>/dev/null; then
  echo "ERROR: AWS credentials are not configured or invalid." >&2
  exit 1
fi

if [[ -n "$ASSUME_ROLE_ARN" ]]; then
  echo "Assuming role: $ASSUME_ROLE_ARN" >&2
  creds="$(aws sts assume-role \
    --role-arn "$ASSUME_ROLE_ARN" \
    --role-session-name "list-inference-models" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text)"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID="$(echo "$creds" | awk '{print $1}')"
  AWS_SECRET_ACCESS_KEY="$(echo "$creds" | awk '{print $2}')"
  AWS_SESSION_TOKEN="$(echo "$creds" | awk '{print $3}')"
fi

echo "Region: $REGION"
echo "Caller: $(aws sts get-caller-identity --region "$REGION" --query Arn --output text)"

# ---------------------------------------------------------------------------
# Classify an AWS CLI error/output blob into a short, human result.
# ---------------------------------------------------------------------------
classify() {
  local rc="$1" output="$2"
  if [[ "$rc" -eq 0 ]]; then
    echo "OK"
  # Private Marketplace org-catalog control — needs procurement/admin action, not IAM or Terraform
  elif grep -qi "private marketplace eligibility\|cannot be completed at this time" <<<"$output"; then
    echo "PRIVATE MARKETPLACE BLOCKED (procurement admin needed)"
  # Missing aws-marketplace IAM actions on the calling role (fixable with Terraform/IAM)
  elif grep -qi "ViewSubscriptions\|aws-marketplace:Subscribe\|aws-marketplace:View" <<<"$output"; then
    echo "MARKETPLACE IAM PERMISSIONS MISSING (add to role policy)"
  elif grep -qi "marketplace" <<<"$output"; then
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

tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

# Test-invokes a single model/profile id and echoes back a classified result.
# Skips the network call (and prints "NOT TESTED") when --skip-access-check
# is set, since PROVISIONED-only models can't be invoked without a
# provisioned-throughput ARN anyway.
test_access() {
  local model_id="$1"

  if [[ "$SKIP_ACCESS_CHECK" == "true" ]]; then
    echo "NOT TESTED"
    return
  fi

  local output rc
  set +e
  if [[ "$model_id" == *rerank* ]]; then
    local model_arn="arn:aws:bedrock:${REGION}::foundation-model/${model_id}"
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

  if [[ "$VERBOSE" == "true" ]]; then
    echo "--- $model_id ---" >&2
    echo "$output" >&2
    echo "" >&2
  fi

  classify "$rc" "$output"
}

# ---------------------------------------------------------------------------
# Foundation models in the region
# ---------------------------------------------------------------------------
print_header "Foundation Models — $REGION"

mapfile -t FM_ROWS < <(
  aws bedrock list-foundation-models \
    --region "$REGION" \
    --query "modelSummaries[?contains(inferenceTypesSupported, \`ON_DEMAND\`) || contains(inferenceTypesSupported, \`PROVISIONED\`)]" \
    --output json 2>/dev/null \
  | jq -r --arg filter "$MODEL_FILTER" '
      .[]
      | select($filter == "" or (.modelId | test($filter)))
      | [.modelId, .providerName, (.inferenceTypesSupported | join(","))]
      | @tsv
    '
)

if [[ ${#FM_ROWS[@]} -eq 0 ]]; then
  echo "  (no foundation models found, or access denied, for $REGION)"
else
  printf "%-55s %-15s %-20s %s\n" "MODEL ID" "PROVIDER" "INFERENCE TYPES" "ACCESS"
  for row in "${FM_ROWS[@]}"; do
    IFS=$'\t' read -r model_id provider inference_types <<<"$row"
    if [[ "$inference_types" == *ON_DEMAND* ]]; then
      access="$(test_access "$model_id")"
    else
      access="PROVISIONED ONLY (not tested)"
    fi
    printf "%-55s %-15s %-20s %s\n" "$model_id" "$provider" "$inference_types" "$access"
  done
fi

# ---------------------------------------------------------------------------
# System-defined inference profiles in the region
# ---------------------------------------------------------------------------
print_header "System-Defined Inference Profiles — $REGION"

mapfile -t SYS_ROWS < <(
  aws bedrock list-inference-profiles \
    --region "$REGION" \
    --type-equals SYSTEM_DEFINED \
    --output json 2>/dev/null \
  | jq -r --arg filter "$MODEL_FILTER" '
      .inferenceProfileSummaries[]
      | select($filter == "" or (.inferenceProfileId | test($filter)))
      | [.inferenceProfileId, .inferenceProfileName, .status]
      | @tsv
    '
)

if [[ ${#SYS_ROWS[@]} -eq 0 ]]; then
  echo "  (no system-defined profiles found, or access denied, for $REGION)"
else
  printf "%-40s %-30s %-10s %s\n" "PROFILE ID" "NAME" "STATUS" "ACCESS"
  for row in "${SYS_ROWS[@]}"; do
    IFS=$'\t' read -r profile_id name status <<<"$row"
    access="$(test_access "$profile_id")"
    printf "%-40s %-30s %-10s %s\n" "$profile_id" "$name" "$status" "$access"
  done
fi

# ---------------------------------------------------------------------------
# Application inference profiles (account-scoped) in the region
# ---------------------------------------------------------------------------
print_header "Application Inference Profiles (account-owned) — $REGION"

mapfile -t APP_ROWS < <(
  aws bedrock list-inference-profiles \
    --region "$REGION" \
    --type-equals APPLICATION \
    --output json 2>/dev/null \
  | jq -r --arg filter "$MODEL_FILTER" '
      .inferenceProfileSummaries[]
      | select($filter == "" or (.inferenceProfileId | test($filter)))
      | [.inferenceProfileId, .inferenceProfileName, .status]
      | @tsv
    '
)

if [[ ${#APP_ROWS[@]} -eq 0 ]]; then
  echo "  (no application profiles found, or access denied, for $REGION)"
else
  printf "%-40s %-30s %-10s %s\n" "PROFILE ID" "NAME" "STATUS" "ACCESS"
  for row in "${APP_ROWS[@]}"; do
    IFS=$'\t' read -r profile_id name status <<<"$row"
    access="$(test_access "$profile_id")"
    printf "%-40s %-30s %-10s %s\n" "$profile_id" "$name" "$status" "$access"
  done
fi

echo ""
echo "Done."
