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

test_version_needs_no_root_and_lifecycle_arguments_are_strict() {
  setup_test_root
  trap teardown_test_root RETURN
  write_stub id 'printf "1000\n"'

  run_vps_guard version
  assert_status 0
  assert_output_contains "VPS Guard 1.0.0"

  run_vps_guard update unexpected
  assert_status 2
  assert_output_contains "vps-guard update check"

  run_vps_guard uninstall unexpected
  assert_status 4

  write_stub id 'printf "0\n"'
  run_vps_guard uninstall unexpected
  assert_status 2
  assert_output_contains "vps-guard uninstall"
}

test_extra_arguments_are_rejected
test_version_needs_no_root_and_lifecycle_arguments_are_strict
