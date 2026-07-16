#!/bin/bash

# Read the desired count from the command line argument
DESIRED_COUNT=$1

#Display error message if no argument is provided
if [ -z "$DESIRED_COUNT" ]; then
    echo "Error: No desired count provided."
    echo "Usage: $0 <desired_count>"
    exit 1
fi



aws ecs update-service --cluster ai-gateway-litellm --service litellm --desired-count "$DESIRED_COUNT" --region ca-central-1 --output json && aws ecs describe-services --cluster ai-gateway-litellm --services litellm --region ca-central-1 --query 'services[0].{status:status,desired:desiredCount,running:runningCount,pending:pendingCount}' --output table