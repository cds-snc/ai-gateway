#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${STACK_DIR:-terragrunt/ai_gateway}"
IMPORT_FILE="${IMPORT_FILE:-$STACK_DIR/import.generated.tf}"
AUTO_APPROVE="${AUTO_APPROVE:-false}"
TERRAGRUNT_BIN="${TERRAGRUNT_BIN:-terragrunt}"
NO_COLOR="${NO_COLOR:-true}"
FAIL_LOG="${FAIL_LOG:-$STACK_DIR/import-failures.log}"

if [[ ! -f "$IMPORT_FILE" ]]; then
  echo "Import file not found: $IMPORT_FILE" >&2
  exit 1
fi

if ! command -v "$TERRAGRUNT_BIN" >/dev/null 2>&1; then
  echo "Terragrunt binary not found: $TERRAGRUNT_BIN" >&2
  exit 1
fi

cd "$STACK_DIR"

FAIL_LOG_BASENAME="$(basename "$FAIL_LOG")"
: > "$FAIL_LOG_BASENAME"

mapfile -t TARGETS < <(grep -E '^\s*to\s*=\s*' "$(basename "$IMPORT_FILE")" | sed -E 's/^\s*to\s*=\s*//')
mapfile -t IDS < <(grep -E '^\s*id\s*=\s*' "$(basename "$IMPORT_FILE")" | sed -E 's/^\s*id\s*=\s*"(.*)"\s*$/\1/')

if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  echo "No import targets found in $IMPORT_FILE" >&2
  exit 1
fi

if [[ "${#TARGETS[@]}" -ne "${#IDS[@]}" ]]; then
  echo "Mismatched import blocks: ${#TARGETS[@]} targets vs ${#IDS[@]} ids" >&2
  exit 1
fi

TOTAL="${#TARGETS[@]}"
FAILED=0
echo "Found $TOTAL imports in $IMPORT_FILE"
echo "Using targeted apply for import blocks (one target per run)."
echo "Failures will be logged to $STACK_DIR/$FAIL_LOG_BASENAME"

for ((i=0; i<TOTAL; i++)); do
  target="${TARGETS[$i]}"
  id="${IDS[$i]}"
  current=$((i + 1))

  echo
  echo "[$current/$TOTAL] Ready to import: $target"
  echo "            ID: $id"

  if [[ "$AUTO_APPROVE" != "true" ]]; then
    read -r -p "Press Enter to run this import (Ctrl+C to stop)... " _
  fi

  APPLY_CMD=("$TERRAGRUNT_BIN" apply "-target=$target")
  if [[ "$AUTO_APPROVE" == "true" ]]; then
    APPLY_CMD+=("-auto-approve")
  fi
  if [[ "$NO_COLOR" == "true" ]]; then
    APPLY_CMD+=("-no-color")
  fi

  set +e
  "${APPLY_CMD[@]}"
  rc=$?
  set -e

  if [[ "$rc" -ne 0 ]]; then
    FAILED=$((FAILED + 1))
    printf '%s | target=%s | id=%s | exit_code=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$target" "$id" "$rc" >> "$FAIL_LOG_BASENAME"
    echo "Import apply failed for target: $target" >&2
    echo "Continuing to next target..." >&2
    continue
  fi

  echo "Import succeeded: $target"
done

echo
if [[ "$FAILED" -gt 0 ]]; then
  echo "Completed with $FAILED failures out of $TOTAL imports."
  echo "See failure log: $STACK_DIR/$FAIL_LOG_BASENAME"
  exit 1
fi

echo "All imports completed successfully."
