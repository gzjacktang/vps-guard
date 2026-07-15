#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_root_user_can_run_status_from_menu() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'PRETTY_NAME="Debian 13"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "x86_64\n"'

  run_vps_guard_with_input $'5\n0\n'

  assert_status 0
  assert_output_contains "5. 状态与诊断"
  assert_output_contains "VPS Guard 系统状态"
  assert_output_contains "已退出"
}

test_root_user_can_open_backup_menu_and_list_snapshots() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' 'ID=debian' 'VERSION_ID="13"' 'PRETTY_NAME="Debian 13"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "x86_64\n"'

  run_vps_guard_with_input $'6\n2\n0\n0\n'

  assert_status 0
  assert_output_contains "备份与恢复"
  assert_output_contains "2. 列出快照"
  assert_output_contains "暂无快照"
  assert_output_contains "已退出"
}

test_root_user_can_run_status_from_menu
test_root_user_can_open_backup_menu_and_list_snapshots
