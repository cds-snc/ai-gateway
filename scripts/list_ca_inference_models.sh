#!/usr/bin/env bash
# list_ca_inference_models.sh
# Queries AWS Bedrock for all inference-capable models available in Canadian regions.
# Covers:
#   - Foundation models available in ca-central-1 and ca-west-2
#   - System-defined inference profiles with a Canadian region prefix
#   - Application inference profiles in the current account/region

set -euo pipefail

CA_REGIONS=("ca-central-1" "ca-west-2")

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

# ---------------------------------------------------------------------------
# Foundation models per Canadian region
# ---------------------------------------------------------------------------
for region in "${CA_REGIONS[@]}"; do
  print_header "Foundation Models — $region"

  aws bedrock list-foundation-models \
    --region "$region" \
    --query "modelSummaries[?contains(inferenceTypesSupported, \`ON_DEMAND\`) || contains(inferenceTypesSupported, \`PROVISIONED\`)].[modelId,modelName,providerName,inferenceTypesSupported[0]]" \
    --output table 2>/dev/null \
  || echo "  (no results or access denied for $region)"
done

# ---------------------------------------------------------------------------
# System-defined inference profiles
# List profiles and filter to those whose region prefix indicates Canada.
# System profiles use prefixes like ca. or have regions embedded in the ARN.
# ---------------------------------------------------------------------------
print_header "System-Defined Inference Profiles (all regions, filtered to ca.*)"

for region in "${CA_REGIONS[@]}"; do
  echo ""
  echo "--- Profiles returned from $region endpoint ---"

  aws bedrock list-inference-profiles \
    --region "$region" \
    --type-equals SYSTEM_DEFINED \
    --output json 2>/dev/null \
  | jq -r '
      .inferenceProfileSummaries[]
      | select(
          (.inferenceProfileId | startswith("ca.")) or
          (.models[]?.modelArn | test(":(ca-central-1|ca-west-2)::"))
        )
      | [.inferenceProfileId, .inferenceProfileName, .status]
      | @tsv
    ' \
  | column -t -s $'\t' \
  || echo "  (no matching profiles or access denied for $region)"
done

# ---------------------------------------------------------------------------
# Application inference profiles (account-scoped, per Canadian region)
# ---------------------------------------------------------------------------
print_header "Application Inference Profiles (account-owned)"

for region in "${CA_REGIONS[@]}"; do
  echo ""
  echo "--- $region ---"

  aws bedrock list-inference-profiles \
    --region "$region" \
    --type-equals APPLICATION \
    --output json 2>/dev/null \
  | jq -r '
      .inferenceProfileSummaries[]
      | [.inferenceProfileId, .inferenceProfileName, .status, (.models[]?.modelArn // "n/a")]
      | @tsv
    ' \
  | column -t -s $'\t' \
  || echo "  (no application profiles or access denied for $region)"
done

echo ""
echo "Done."
