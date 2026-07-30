#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
diabot_dir="$(cd "$script_dir/.." && pwd)"
output_dir="$script_dir/zip"
archive="$output_dir/diabot-fsm-handoff.zip"

files=(
  README.md
  lib/events.dart
  lib/initialization.dart
  lib/orchestrator.dart
  lib/time_engine.dart
  test/fsm_mermaid_contract_test.dart
  test/initialization_test.dart
  test/orchestrator_test.dart
  test/time_engine_test.dart
)

fsm_files=()
while IFS= read -r file; do
  fsm_files+=("${file#"$diabot_dir"/}")
done < <(find "$diabot_dir/docs/fsm" -type f -print | sort)

if [[ ${#fsm_files[@]} -eq 0 ]]; then
  echo "No FSM modules found in docs/fsm." >&2
  exit 1
fi

files+=("${fsm_files[@]}")

command -v zip >/dev/null || {
  echo "The 'zip' command is required to create the FSM handoff archive." >&2
  exit 1
}

for file in "${files[@]}"; do
  if [[ ! -f "$diabot_dir/$file" ]]; then
    echo "Required FSM handoff file is missing: $file" >&2
    exit 1
  fi
done

mkdir -p "$output_dir"
rm -f "$archive"

(
  cd "$diabot_dir"
  zip -q "$archive" "${files[@]}"
)

echo "Created $archive"