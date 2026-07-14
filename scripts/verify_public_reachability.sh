#!/usr/bin/env bash

set -euo pipefail

# Validate public reachability behavior for the AI gateway.
# This script checks HTTPS availability, HTTP redirect, target health,
# ECS task interface exposure signals, and optional rollout continuity.

usage() {
  cat <<'EOF'
Usage: verify_public_reachability.sh --gateway-host <host> [options]

Required:
  --gateway-host <host>        Public DNS host of the gateway (no scheme)

Optional:
  --cluster <name>             ECS cluster name (default: ai-gateway-litellm)
  --service <name>             ECS service name (default: litellm)
  --region <region>            AWS region (default: ca-central-1)
  --target-group-arn <arn>     ALB target group ARN for health checks
  --rollout-seconds <n>        Run continuity probe loop for n seconds
  --interval-seconds <n>       Continuity probe interval (default: 5)
  --help                       Show this help message
EOF
}

GATEWAY_HOST=""
CLUSTER="ai-gateway-litellm"
SERVICE="litellm"
REGION="ca-central-1"
TARGET_GROUP_ARN=""
ROLLOUT_SECONDS="0"
INTERVAL_SECONDS="5"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --gateway-host)
      GATEWAY_HOST="$2"
      shift 2
      ;;
    --cluster)
      CLUSTER="$2"
      shift 2
      ;;
    --service)
      SERVICE="$2"
      shift 2
      ;;
    --region)
      REGION="$2"
      shift 2
      ;;
    --target-group-arn)
      TARGET_GROUP_ARN="$2"
      shift 2
      ;;
    --rollout-seconds)
      ROLLOUT_SECONDS="$2"
      shift 2
      ;;
    --interval-seconds)
      INTERVAL_SECONDS="$2"
      shift 2
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$GATEWAY_HOST" ]]; then
  echo "Missing required --gateway-host" >&2
  usage
  exit 1
fi

PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

check_https_available() {
  local code
  code=$(curl -sS -o /dev/null -w "%{http_code}" "https://${GATEWAY_HOST}/health/readiness")
  [[ "$code" -ge 200 && "$code" -lt 500 ]]
}

check_http_redirects() {
  local code location
  code=$(curl -sS -o /dev/null -D /tmp/verify_public_headers.$$ -w "%{http_code}" "http://${GATEWAY_HOST}/health/readiness")
  location=$(grep -i '^location:' /tmp/verify_public_headers.$$ | tail -n1 | awk '{print $2}' | tr -d '\r')
  rm -f /tmp/verify_public_headers.$$ || true
  [[ "$code" == "301" || "$code" == "302" || "$code" == "308" ]] && [[ "$location" == https://* ]]
}

check_target_group_health() {
  [[ -n "$TARGET_GROUP_ARN" ]] || return 0
  local unhealthy
  unhealthy=$(aws elbv2 describe-target-health \
    --region "$REGION" \
    --target-group-arn "$TARGET_GROUP_ARN" \
    --query "TargetHealthDescriptions[?TargetHealth.State!='healthy'] | length(@)" \
    --output text)
  [[ "$unhealthy" == "0" ]]
}

check_no_public_task_interface() {
  local task_arn eni_id public_ip
  task_arn=$(aws ecs list-tasks \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --service-name "$SERVICE" \
    --desired-status RUNNING \
    --query 'taskArns[0]' --output text)

  [[ -n "$task_arn" && "$task_arn" != "None" ]] || return 1

  eni_id=$(aws ecs describe-tasks \
    --region "$REGION" \
    --cluster "$CLUSTER" \
    --tasks "$task_arn" \
    --query "tasks[0].attachments[?type=='ElasticNetworkInterface'].details[?name=='networkInterfaceId'].value | [0]" \
    --output text)

  [[ -n "$eni_id" && "$eni_id" != "None" ]] || return 1

  public_ip=$(aws ec2 describe-network-interfaces \
    --region "$REGION" \
    --network-interface-ids "$eni_id" \
    --query "NetworkInterfaces[0].Association.PublicIp" \
    --output text)

  [[ "$public_ip" == "None" ]]
}

run_rollout_continuity_probe() {
  local end_ts now total success code
  total=0
  success=0
  end_ts=$(( $(date +%s) + ROLLOUT_SECONDS ))

  while true; do
    now=$(date +%s)
    [[ "$now" -lt "$end_ts" ]] || break
    total=$((total + 1))
    code=$(curl -sS -o /dev/null -w "%{http_code}" "https://${GATEWAY_HOST}/health/readiness" || true)
    if [[ "$code" == "200" ]]; then
      success=$((success + 1))
    fi
    sleep "$INTERVAL_SECONDS"
  done

  if [[ "$total" -eq 0 ]]; then
    return 1
  fi

  local rate
  rate=$(( (100 * success) / total ))
  echo "Rollout continuity: ${success}/${total} successful checks (${rate}%)"
  [[ "$rate" -ge 99 ]]
}

check "HTTPS readiness endpoint is reachable" check_https_available
check "HTTP endpoint redirects to HTTPS" check_http_redirects
check "Target group reports healthy targets" check_target_group_health
check "ECS task ENI has no public IP" check_no_public_task_interface

if [[ "$ROLLOUT_SECONDS" -gt 0 ]]; then
  check "Rollout continuity remains >=99% during probe window" run_rollout_continuity_probe
fi

echo
if [[ "$FAIL" -eq 0 ]]; then
  echo "SUMMARY: PASS (${PASS} checks passed, 0 failed)"
  exit 0
fi

echo "SUMMARY: FAIL (${PASS} passed, ${FAIL} failed)"
exit 1
