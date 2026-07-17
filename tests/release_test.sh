#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_version_license_and_single_file_artifact() {
  setup_test_root
  trap teardown_test_root RETURN
  local single="$TEST_ROOT/vps-guard-single.sh"

  [[ "$(<"$PROJECT_ROOT/VERSION")" == 1.0.0 ]]
  grep -q '^Copyright (c) 2026 jLjT$' "$PROJECT_ROOT/LICENSE"
  "$PROJECT_ROOT/scripts/build-single.sh" "$single" >/dev/null

  [[ -x "$single" ]]
  [[ "$(grep -c '^#!/usr/bin/env bash$' "$single")" -eq 1 ]]
  if grep -q '^source .*lib/' "$single"; then return 1; fi
  # shellcheck disable=SC2016
  grep -Fq 'VPS_GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"' "$single"
  # shellcheck disable=SC2016
  grep -Fq 'VPS_GUARD_COMMAND="${VPS_GUARD_COMMAND:-$VPS_GUARD_ROOT/$(basename "${BASH_SOURCE[0]}")}"' "$single"
  bash -n "$single"
  COMMAND_OUTPUT="$($single version 2>&1)"
  COMMAND_STATUS=$?
  assert_status 0
  assert_output_contains "VPS Guard 1.0.0"
  COMMAND_OUTPUT="$($single help 2>&1)"
  COMMAND_STATUS=$?
  assert_status 0
  assert_output_contains "uninstall"
}

test_sensitive_scan_rejects_private_key_material() {
  setup_test_root
  trap teardown_test_root RETURN
  local fixture="$TEST_ROOT/fixture.txt"
  printf '%s\n' '-----BEGIN OPENSSH'\ 'PRIVATE KEY-----' 'not-a-real-key' >"$fixture"

  set +e
  COMMAND_OUTPUT="$("$PROJECT_ROOT/scripts/check-sensitive.sh" "$fixture" 2>&1)"
  COMMAND_STATUS=$?
  set -e

  assert_status 1
  assert_output_contains "包含私钥或凭据模式"
}

test_sensitive_scan_rejects_non_documentation_ipv6_address() {
  setup_test_root
  trap teardown_test_root RETURN
  local fixture="$TEST_ROOT/fixture.txt"
  # 运行时构造真实 IPv6 地址，避免源码中出现字面量触发敏感扫描
  local bad_ipv6
  printf -v bad_ipv6 '%04x:%04x:%04x::%04x' 0x2606 0x4700 0x4700 0x1111
  printf '%s\n' "server=$bad_ipv6" >"$fixture"

  set +e
  COMMAND_OUTPUT="$("$PROJECT_ROOT/scripts/check-sensitive.sh" "$fixture" 2>&1)"
  COMMAND_STATUS=$?
  set -e

  assert_status 1
  assert_output_contains "非文档保留 IPv6 地址"
}

test_real_vm_gate_is_fail_closed_until_verified() {
  set +e
  COMMAND_OUTPUT="$("$PROJECT_ROOT/scripts/check-vm-gate.sh" 2>&1)"
  COMMAND_STATUS=$?
  set -e
  assert_status 1
  assert_output_contains "尚未通过"
}

test_version_license_and_single_file_artifact
test_sensitive_scan_rejects_private_key_material
test_sensitive_scan_rejects_non_documentation_ipv6_address
test_real_vm_gate_is_fail_closed_until_verified

printf 'release_test: ok\n'
