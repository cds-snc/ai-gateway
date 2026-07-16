#!/usr/bin/env bash
set -euo pipefail

# Fail if any YAML/YML file contains a literal tab character.
# YAML indentation must use spaces; tabs can break parsing at runtime.

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  # CI should enforce this on repository files, not generated cache artifacts.
  mapfile -t yaml_files < <(git ls-files "*.yml" "*.yaml")
else
  mapfile -t yaml_files < <(find . -type f \( -name "*.yml" -o -name "*.yaml" \) \
    -not -path "*/.git/*" \
    -not -path "*/.terragrunt-cache/*")
fi

if [[ ${#yaml_files[@]} -eq 0 ]]; then
  echo "No YAML files found."
  exit 0
fi

if grep -nHP "\t" "${yaml_files[@]}"; then
  echo
  echo "ERROR: Found tab character(s) in YAML file(s). Use spaces for indentation."
  exit 1
fi

echo "YAML tab check passed: no tab characters found."
