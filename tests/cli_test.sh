#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_extra_arguments_are_rejected() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'PRETTY_NAME="Debian 13"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "x86_64\n"'

  run_vps_guard status extra

  assert_status 2
  assert_output_contains "status 不接受额外参数"
}

test_extra_arguments_are_rejected
