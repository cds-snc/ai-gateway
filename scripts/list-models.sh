#!/usr/bin/env bash

set -euo pipefail


# Get key from command line argument
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <key> <url>"
    exit 1
fi

KEY="$1"
URL="$2"

# Lists models exposed by LiteLLM using OpenAI-compatible auth.
curl -sS "$URL/models" \
  -H "Authorization: Bearer $KEY"
