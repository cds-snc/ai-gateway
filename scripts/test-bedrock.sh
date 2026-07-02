#/bin/bash

set -euo pipefail


# Get key from command line argument
if [ "$#" -ne 2 ]; then
    echo "Usage: $0 <key> <url>"
    exit 1
fi

KEY="$1"

URL="$2"
MODEL="us.anthropic.claude-haiku-4-5-20251001-v1:0"

 # Using Authorization header (OpenAI style)
curl -X POST $URL/v1/chat/completions \
   -H "Authorization: Bearer $KEY" \
   -H "Content-Type: application/json" \
   -d '{"model": "'$MODEL'", "messages": [{"role": "user", "content": "Write a 3 line poem?"}]}'
