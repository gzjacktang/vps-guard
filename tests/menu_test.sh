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

  run_vps_guard_with_input $'5\n1\n0\n0\n'

  assert_status 0
  assert_output_contains "5. 状态与诊断"
  assert_output_contains "1. 系统状态"
  assert_output_contains "VPS Guard 系统状态"
  assert_output_contains "已退出"
}

test_root_user_can_run_preflight_from_diagnostics_menu() {
  setup_test_root
  trap teardown_test_root RETURN

  write_stub id 'printf "0\n"'
  write_stub docker 'exit 0'
  write_stub ps 'printf "dockerd /usr/bin/dockerd\n"'

  run_vps_guard_with_input $'5\n2\n0\n0\n'

  assert_status 0
  assert_output_contains "状态与诊断"
  assert_output_contains "2. 网络环境预检"
  assert_output_contains "VPS Guard 网络环境预检（只读）"
  assert_output_contains "容器运行时 Docker：运行中"
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

test_root_user_can_open_firewall_menu_and_view_status() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/vps-guard"
  printf '%s\n' 'enabled=1' 'ssh_ports=22' 'tcp_ports=80' 'udp_ports=' >"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  write_stub id 'printf "0\n"'
  write_stub nft '
if [[ "$*" == "list table inet vps_guard" ]]; then
  exit 0
fi
exit 0
'

  run_vps_guard_with_input $'3\n1\n0\n0\n'

  assert_status 0
  assert_output_contains "防火墙管理"
  assert_output_contains "1. 查看状态"
  assert_output_contains "磁盘配置：已启用"
  assert_output_contains "受保护 SSH TCP：22"
  assert_output_contains "已退出"
}

test_root_user_can_run_status_from_menu
test_root_user_can_run_preflight_from_diagnostics_menu
test_root_user_can_open_backup_menu_and_list_snapshots
test_root_user_can_open_firewall_menu_and_view_status
