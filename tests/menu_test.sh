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

	run_vps_guard_with_input $'1\n1\n0\n0\n'

	assert_status 0
	assert_output_contains "1. 状态与诊断"
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

	run_vps_guard_with_input $'1\n2\n0\n0\n'

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

	run_vps_guard_with_input $'4\n1\n0\n0\n'

	assert_status 0
	assert_output_contains "nftables 防火墙"
	assert_output_contains "1. 查看状态"
	assert_output_contains "磁盘配置：已启用"
	assert_output_contains "受保护 SSH TCP：22"
	assert_output_contains "已退出"
}

test_root_user_can_open_ssh_migration_submenu() {
	setup_test_root
	trap teardown_test_root RETURN
	write_stub id 'printf "0\n"'

	run_vps_guard_with_input $'3\n0\n0\n'

	assert_status 0
	assert_output_contains "SSH 管理"
	assert_output_contains "1. 查看实际配置与风险"
	assert_output_contains "2. SSH 端口管理"
	assert_output_contains "3. SSH 密钥设置"
	assert_output_contains "4. 可选 SSH 加固"
	assert_output_contains "5. SSH 快照恢复"
	assert_output_contains "已退出"
}

test_root_user_can_open_nested_ssh_key_menu() {
	setup_test_root
	trap teardown_test_root RETURN
	write_stub id 'printf "0\n"'

	run_vps_guard_with_input $'3\n3\n0\n0\n'

	assert_status 0
	assert_output_contains "SSH 密钥设置"
	assert_output_contains "生成 Ed25519 密钥"
	assert_output_contains "导入并校验公钥"
	assert_output_contains "3. 从新密钥会话确认"
	assert_output_not_contains "客户端 Ed25519 生成引导"
}

test_root_user_can_open_lifecycle_menu_and_view_version() {
	setup_test_root
	trap teardown_test_root RETURN
	write_stub id 'printf "0\n"'

	run_vps_guard_with_input $'7\n1\n0\n0\n'

	assert_status 0
	assert_output_contains "设置、更新与卸载"
	assert_output_contains "手动检查 GitHub Release"
	assert_output_contains "卸载程序（保留配置、快照和日志）"
	assert_output_contains "VPS Guard 1.0.0"
}

test_lifecycle_uninstall_cancel_returns_to_lifecycle_menu() {
	setup_test_root
	trap teardown_test_root RETURN
	write_stub id 'printf "0\n"'

	run_vps_guard_with_input $'7\n3\nn\n0\n0\n'

	assert_status 0
	assert_output_contains "确认卸载？[y/N]"
	assert_output_contains "已取消卸载。"
	assert_output_contains "设置、更新与卸载"
}

test_backup_menu_excludes_rollback_controls() {
	setup_test_root
	trap teardown_test_root RETURN
	write_stub id 'printf "0\n"'

	run_vps_guard_with_input $'6\n0\n0\n'

	assert_status 0
	assert_output_contains "5. 设置快照保留数量"
	assert_output_not_contains "启动自动回滚"
	assert_output_not_contains "查询自动回滚"
}

test_firewall_menu_keeps_advanced_rules_at_first_level() {
	setup_test_root
	trap teardown_test_root RETURN
	write_stub id 'printf "0\n"'

	run_vps_guard_with_input $'4\n0\n0\n'

	assert_status 0
	assert_output_contains "6. 开放高级规则"
	assert_output_contains "7. 关闭高级规则"
	assert_output_contains "8. 查询三层端口状态"
	assert_output_not_contains "高级规则与三层端口状态"
}

test_root_user_can_run_status_from_menu
test_root_user_can_run_preflight_from_diagnostics_menu
test_root_user_can_open_backup_menu_and_list_snapshots
test_root_user_can_open_firewall_menu_and_view_status
test_root_user_can_open_ssh_migration_submenu
test_root_user_can_open_nested_ssh_key_menu
test_root_user_can_open_lifecycle_menu_and_view_version
test_lifecycle_uninstall_cancel_returns_to_lifecycle_menu
test_backup_menu_excludes_rollback_controls
test_firewall_menu_keeps_advanced_rules_at_first_level
