#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
passed=0
failed=0

for test_file in "$ROOT"/tests/*_test.sh; do
  if bash "$test_file"; then
    printf 'ok - %s\n' "$(basename "$test_file")"
    passed=$((passed + 1))
  else
    printf 'not ok - %s\n' "$(basename "$test_file")"
    failed=$((failed + 1))
  fi
done

printf '\n通过：%s，失败：%s\n' "$passed" "$failed"
[[ "$failed" -eq 0 ]]
