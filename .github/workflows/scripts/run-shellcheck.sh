#!/bin/bash
set -euo pipefail

mapfile -t shell_files < <(git ls-files '*.sh')

if [ "${#shell_files[@]}" -eq 0 ]; then
	echo "No shell scripts found to lint."
	exit 0
fi

docker run --rm -v "$PWD:/mnt" --workdir /mnt koalaman/shellcheck:v0.7.1 -P ./bin/ -x "${shell_files[@]}"
