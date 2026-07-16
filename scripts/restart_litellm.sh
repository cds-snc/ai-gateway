#!/usr/bin/env bash
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-ai-gateway-litellm}"
SERVICE_NAME="${SERVICE_NAME:-litellm}"
AWS_REGION="${AWS_REGION:-ca-central-1}"
WAIT_FOR_STABLE="true"

usage() {
  cat <<'EOF'
Usage: ./scripts/restart_litellm.sh [--no-wait]

Forces a new ECS deployment for the LiteLLM service so tasks restart and reload
the S3-backed config on startup.

Optional environment overrides:
  CLUSTER_NAME   ECS cluster name (default: ai-gateway-litellm)
  SERVICE_NAME   ECS service name (default: litellm)
  AWS_REGION     AWS region (default: ca-central-1)

Options:
  --no-wait      Return immediately after the deployment is triggered
  -h, --help     Show this help message
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-wait)
      WAIT_FOR_STABLE="false"
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

if ! command -v aws >/dev/null 2>&1; then
  echo "Error: aws CLI is not installed or not on PATH." >&2
  exit 1
fi

echo "Forcing new deployment for service ${SERVICE_NAME} in cluster ${CLUSTER_NAME} (${AWS_REGION})..."
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$SERVICE_NAME" \
  --force-new-deployment \
  --region "$AWS_REGION" \
  --output json >/dev/null

if [[ "$WAIT_FOR_STABLE" == "true" ]]; then
  echo "Waiting for ECS service to stabilize..."
  aws ecs wait services-stable \
    --cluster "$CLUSTER_NAME" \
    --services "$SERVICE_NAME" \
    --region "$AWS_REGION"
fi

aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_NAME" \
  --region "$AWS_REGION" \
  --query 'services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount,deployments:deployments[*].{status:status,rollout:rolloutState,running:runningCount,pending:pendingCount}}' \
  --output table