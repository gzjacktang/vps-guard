#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_supported_system_matrix() {
  local system_case os_id version arch expected_arch

  for system_case in \
    'debian|12|x86_64|amd64' \
    'debian|12|aarch64|arm64' \
    'debian|13|x86_64|amd64' \
    'debian|13|aarch64|arm64' \
    'ubuntu|22.04|x86_64|amd64' \
    'ubuntu|22.04|aarch64|arm64' \
    'ubuntu|24.04|x86_64|amd64' \
    'ubuntu|24.04|aarch64|arm64' \
    'ubuntu|26.04|x86_64|amd64' \
    'ubuntu|26.04|aarch64|arm64'; do
    IFS='|' read -r os_id version arch expected_arch <<<"$system_case"
    setup_test_root
    printf '%s\n' \
      "ID=$os_id" \
      "VERSION_ID=\"$version\"" \
      "PRETTY_NAME=\"$os_id $version\"" >"$TEST_ROOT/os-release"
    write_stub id 'printf "0\n"'
    write_stub uname "printf '%s\\n' '$arch'"

    run_vps_guard status

    assert_status 0
    assert_output_contains "架构：$expected_arch"
    assert_output_contains "支持状态：正式支持"
    teardown_test_root
  done
}

test_supported_system_matrix
