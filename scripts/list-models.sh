#/bin/bash

set -euo pipefail


# Get key from command line argument
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <key> <url>"
    exit 1
fi

KEY="$1"

URL="$2"
# Lists models across providers allowed by the virtual key
curl -sS "$URL/v1/models" \
  -H "x-bf-vk: $KEY"
  

# # Using Authorization header (OpenAI style)
# curl -X POST http://localhost:8080/v1/chat/completions \
#   -H "Authorization: Bearer $KEY" \
#   -H "Content-Type: application/json" \
#   -d '{"model": "", "messages": [...]}'
