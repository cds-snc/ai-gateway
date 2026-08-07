#!/usr/bin/env bash

set -euo pipefail

BASE_URL="https://ai.cdssandbox.xyz"
API_KEY="${LITELLM_API_KEY:-}"
PROMPT="Write a haiku about Canada"
MAX_TOKENS="1024"
TIMEOUT="30"
OUTPUT_DIR=""
VERBOSE="false"

usage() {
  cat <<EOF
Usage: ./scripts/test_models_for_key.sh --key <api_key> [options]

Discovers models exposed by a LiteLLM/OpenAI-compatible gateway key, then sends
one prompt to each model and records pass/fail results.

Required:
  --key <api_key>             API key to test (or set LITELLM_API_KEY)

Options:
  --url <url-or-host>         Gateway base URL, default: ${BASE_URL}
  --prompt <text>             Prompt to send, default: "${PROMPT}"
  --max-tokens <count>        max_tokens for chat completion, default: ${MAX_TOKENS} (min needed for codex models)
  --timeout <seconds>         Curl timeout per request, default: ${TIMEOUT}
  --output-dir <path>         Directory for JSON reports, default: ./logs/model-tests/<timestamp>
  --verbose                   Print per-model status as requests run
  -h, --help                  Show this help message

Examples:
  ./scripts/test_models_for_key.sh --key sk-abc123
  ./scripts/test_models_for_key.sh --key sk-abc123 --url ai.cdssandbox.xyz
  ./scripts/test_models_for_key.sh --key sk-abc123 --prompt "Say hello in French"

Outputs:
  - summary.json: full run summary and per-model result list
  - failures.json: only failed model attempts with request/response context
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)
      API_KEY="$2"
      shift 2
      ;;
    --url)
      BASE_URL="$2"
      shift 2
      ;;
    --prompt)
      PROMPT="$2"
      shift 2
      ;;
    --max-tokens)
      MAX_TOKENS="$2"
      shift 2
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="$2"
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

if [[ -z "$API_KEY" ]]; then
  echo "Error: API key is required. Use --key or set LITELLM_API_KEY." >&2
  exit 1
fi

if [[ ! "$MAX_TOKENS" =~ ^[0-9]+$ ]]; then
  echo "Error: --max-tokens must be an integer." >&2
  exit 1
fi

if [[ ! "$TIMEOUT" =~ ^[0-9]+$ ]]; then
  echo "Error: --timeout must be an integer number of seconds." >&2
  exit 1
fi

for cmd in curl python3 mktemp; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: required command not found on PATH: $cmd" >&2
    exit 1
  fi
done

NORMALIZED_BASE_URL="${BASE_URL%/}"
if [[ ! "$NORMALIZED_BASE_URL" =~ ^https?:// ]]; then
  NORMALIZED_BASE_URL="https://${NORMALIZED_BASE_URL}"
fi

TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$OUTPUT_DIR" ]]; then
  OUTPUT_DIR="./logs/model-tests/${TIMESTAMP}"
fi
mkdir -p "$OUTPUT_DIR"

SUMMARY_FILE="${OUTPUT_DIR}/summary.json"
FAILURES_FILE="${OUTPUT_DIR}/failures.json"
MODELS_FILE="$(mktemp)"

cleanup() {
  rm -f "$MODELS_FILE"
}
trap cleanup EXIT

echo "Discovering models from ${NORMALIZED_BASE_URL}/models ..." >&2
MODELS_HTTP_CODE="$(curl -sS -m "$TIMEOUT" -o "$MODELS_FILE" -w "%{http_code}" \
  -H "Authorization: Bearer ${API_KEY}" \
  "${NORMALIZED_BASE_URL}/models")"

if [[ "$MODELS_HTTP_CODE" -lt 200 || "$MODELS_HTTP_CODE" -ge 300 ]]; then
  echo "Error: failed to fetch models (HTTP ${MODELS_HTTP_CODE})." >&2
  echo "Response body:" >&2
  cat "$MODELS_FILE" >&2
  exit 1
fi

MODEL_COUNT="$(python3 - "$MODELS_FILE" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    payload = json.load(f)

data = payload.get("data")
if not isinstance(data, list):
    raise SystemExit("Invalid /models response: expected object with list at key 'data'.")

print(len(data))
PY
)"

if [[ "$MODEL_COUNT" -eq 0 ]]; then
  echo "No models returned for this key. Writing empty reports to ${OUTPUT_DIR}" >&2
  python3 - "$SUMMARY_FILE" "$FAILURES_FILE" "$NORMALIZED_BASE_URL" "$PROMPT" "$MAX_TOKENS" "$TIMEOUT" <<'PY'
import json
import sys
from datetime import datetime, timezone

summary_path, failures_path, base_url, prompt, max_tokens, timeout = sys.argv[1:7]

summary = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "base_url": base_url,
    "prompt": prompt,
    "max_tokens": int(max_tokens),
    "timeout_seconds": int(timeout),
    "totals": {
        "models_discovered": 0,
        "models_tested": 0,
        "passed": 0,
        "failed": 0,
    },
    "results": [],
}

with open(summary_path, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)

with open(failures_path, "w", encoding="utf-8") as f:
    json.dump([], f, indent=2)
PY
  echo "summary: ${SUMMARY_FILE}" >&2
  echo "failures: ${FAILURES_FILE}" >&2
  exit 0
fi

echo "Discovered ${MODEL_COUNT} model(s). Testing prompt across all models..." >&2

python3 - "$MODELS_FILE" "$NORMALIZED_BASE_URL" "$API_KEY" "$PROMPT" "$MAX_TOKENS" "$TIMEOUT" "$SUMMARY_FILE" "$FAILURES_FILE" "$VERBOSE" <<'PY'
import json
import subprocess
import sys
from datetime import datetime, timezone

(
    models_path,
    base_url,
    api_key,
    prompt,
    max_tokens,
    timeout,
    summary_path,
    failures_path,
    verbose,
) = sys.argv[1:10]

max_tokens = int(max_tokens)
timeout = int(timeout)
verbose = verbose.lower() == "true"

with open(models_path, "r", encoding="utf-8") as f:
    models_payload = json.load(f)

models_data = models_payload.get("data")
if not isinstance(models_data, list):
    raise SystemExit("Invalid /models response: expected object with list at key 'data'.")

model_ids = []
for model in models_data:
    if not isinstance(model, dict):
        continue
    model_id = model.get("id")
    if isinstance(model_id, str) and model_id not in model_ids:
        model_ids.append(model_id)

results = []
failures = []

for idx, model_id in enumerate(model_ids, start=1):
    request_payload = {
        "model": model_id,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
    }

    body = json.dumps(request_payload)
    cmd = [
        "curl",
        "-sS",
        "-m",
        str(timeout),
        "-o",
        "-",
        "-w",
        "\\n__HTTP_CODE__:%{http_code}",
        "-X",
        "POST",
        f"{base_url}/v1/chat/completions",
        "-H",
        f"Authorization: Bearer {api_key}",
        "-H",
        "Content-Type: application/json",
        "--data-binary",
        body,
    ]

    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False)
    except Exception as exc:
        result = {
            "model": model_id,
            "status": "error",
            "http_status": None,
            "success": False,
            "request": request_payload,
            "error": {
                "type": "script_exception",
                "message": str(exc),
            },
        }
        results.append(result)
        failures.append(result)
        if verbose:
            print(f"[{idx}/{len(model_ids)}] FAIL  {model_id} (script exception)", file=sys.stderr)
        continue

    stdout = proc.stdout or ""
    stderr = proc.stderr or ""

    marker = "\n__HTTP_CODE__:"
    if marker in stdout:
        response_body, http_code_str = stdout.rsplit(marker, 1)
        http_code_str = http_code_str.strip()
    else:
        response_body = stdout
        http_code_str = "000"

    try:
        http_code = int(http_code_str)
    except ValueError:
        http_code = 0

    parsed_response = None
    response_text = response_body.strip()
    if response_text:
        try:
            parsed_response = json.loads(response_text)
        except json.JSONDecodeError:
            parsed_response = None

    success = False
    error_obj = None

    if proc.returncode != 0:
        error_obj = {
            "type": "curl_error",
            "message": stderr.strip() or f"curl exited with {proc.returncode}",
            "return_code": proc.returncode,
        }
    elif 200 <= http_code < 300:
        if isinstance(parsed_response, dict) and parsed_response.get("error"):
            error_obj = {
                "type": "api_error_in_success_response",
                "message": str(parsed_response.get("error")),
            }
        else:
            success = True
    else:
        api_error = None
        if isinstance(parsed_response, dict):
            api_error = parsed_response.get("error")
        if api_error is not None:
            error_obj = {
                "type": "api_error",
                "message": str(api_error),
            }
        else:
            error_obj = {
                "type": "http_error",
                "message": f"HTTP {http_code}",
            }

    result = {
        "model": model_id,
        "status": "ok" if success else "error",
        "http_status": http_code if http_code != 0 else None,
        "success": success,
        "request": request_payload,
    }

    if success:
        if isinstance(parsed_response, dict):
            result["response_excerpt"] = {
                "id": parsed_response.get("id"),
                "model": parsed_response.get("model"),
                "choices_count": len(parsed_response.get("choices", []))
                if isinstance(parsed_response.get("choices"), list)
                else None,
            }
    else:
        result["error"] = error_obj
        if parsed_response is not None:
            result["response_body"] = parsed_response
        elif response_text:
            result["response_body_raw"] = response_text
        if stderr.strip():
            result["stderr"] = stderr.strip()
        failures.append(result)

    results.append(result)

    if verbose:
        status_text = "PASS" if success else "FAIL"
        http_text = http_code if http_code else "n/a"
        print(f"[{idx}/{len(model_ids)}] {status_text:<5} {model_id} (http={http_text})", file=sys.stderr)

passed = sum(1 for item in results if item.get("success"))
failed = len(results) - passed

summary = {
    "timestamp_utc": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "base_url": base_url,
    "prompt": prompt,
    "max_tokens": max_tokens,
    "timeout_seconds": timeout,
    "totals": {
        "models_discovered": len(model_ids),
        "models_tested": len(results),
        "passed": passed,
        "failed": failed,
    },
    "results": results,
}

with open(summary_path, "w", encoding="utf-8") as f:
    json.dump(summary, f, indent=2)

with open(failures_path, "w", encoding="utf-8") as f:
    json.dump(failures, f, indent=2)

print(f"PASS: {passed}")
print(f"FAIL: {failed}")
PY

echo "" >&2
echo "Run complete." >&2
echo "summary: ${SUMMARY_FILE}" >&2
echo "failures: ${FAILURES_FILE}" >&2