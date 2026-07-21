#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_wizard_test() {
	setup_test_root
	umask 077
	mkdir -p "$TEST_ROOT/fs/etc/ssh" "$TEST_ROOT/fs/etc/nftables.d" "$TEST_ROOT/fs/etc/vps-guard" "$TEST_ROOT/fs/etc/fail2ban/jail.d"
	printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
	printf '#!/usr/sbin/nft -f\n' >"$TEST_ROOT/fs/etc/nftables.conf"
	printf '%s\n' /etc/ssh/sshd_config /etc/nftables.conf /etc/nftables.d/vps-guard.nft /etc/vps-guard/firewall.conf /etc/fail2ban/jail.d/vps-guard.local >"$TEST_ROOT/managed-paths"
	write_stub id 'printf "0\n"'
	write_stub sshd '[[ "${1:-}" == -T ]] && { printf "port 22\n"; exit 0; }; exit 0'
	write_stub ss "printf '%s\\n' 'tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((sshd,pid=1,fd=3))' 'tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:((nginx,pid=2,fd=3))' 'udp UNCONN 0 0 [::]:53 [::]:* users:((named,pid=4,fd=4))'"
	write_stub nft '[[ "$1 ${2:-}" == "-c -f" || "$1 ${2:-}" == "list ruleset" ]] && exit 0; [[ "$*" == "list table inet vps_guard" ]] && exit 1; exit 0'
	write_stub systemctl "if [[ \"\$*\" == 'restart fail2ban' && -e '$TEST_ROOT/fail-fail2ban' ]]; then exit 1; fi; exit 0"
	write_stub fail2ban-client '[[ "${1:-}" == -t ]] && exit 0; exit 0'
	TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 22"
}

test_standard_plan_configures_firewall_and_fail2ban_without_ssh_or_rollback() {
	setup_wizard_test
	trap teardown_test_root RETURN

	run_vps_guard wizard apply --plan standard --tcp 80,443 --udp 53 --yes

	assert_status 0
	assert_output_contains "SSH 配置：保持不变。自动回滚仅在 SSH 管理中可用。"
	assert_output_contains "快速安全配置已应用；SSH 配置未变更，未创建自动回滚。"
	[[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
	grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	grep -q '^tcp_ports=80,443$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	grep -q '^udp_ports=53$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	grep -q '^port = 22$' "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
	[[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_selected_plan_changes_only_its_component() {
	setup_wizard_test
	run_vps_guard wizard apply --plan firewall --tcp 80 --udp 53 --yes
	assert_status 0
	[[ -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
	[[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
	teardown_test_root

	setup_wizard_test
	trap teardown_test_root RETURN
	run_vps_guard wizard apply --plan fail2ban --yes
	assert_status 0
	[[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
	[[ -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
}

test_wizard_rejects_ssh_and_rollback_arguments() {
	setup_wizard_test
	trap teardown_test_root RETURN

	run_vps_guard wizard apply --plan firewall --ssh-port 2222 --yes
	assert_status 2
	assert_output_contains "快速安全配置不支持 --ssh-port"
	run_vps_guard wizard apply --plan firewall --rollback-minutes 5 --yes
	assert_status 2
	assert_output_contains "快速安全配置不支持 --rollback-minutes"
}

test_wizard_failure_restores_snapshot_without_scheduling_rollback() {
	setup_wizard_test
	trap teardown_test_root RETURN
	touch "$TEST_ROOT/fail-fail2ban"

	run_vps_guard wizard apply --plan standard --tcp 80 --udp 53 --yes

	assert_status 1
	assert_output_contains "部分应用失败"
	[[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
	[[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
	[[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
	[[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_menu_excludes_ssh_from_quick_configuration() {
	setup_wizard_test
	trap teardown_test_root RETURN

	run_vps_guard_with_input $'2\n4\n0\n0\n'

	assert_status 0
	assert_output_contains "SSH 端口、密钥与加固请在 SSH 管理中操作"
	assert_output_not_contains "SSH 新端口"
	assert_output_not_contains "1. SSH 管理"
}

test_standard_plan_configures_firewall_and_fail2ban_without_ssh_or_rollback
test_selected_plan_changes_only_its_component
test_wizard_rejects_ssh_and_rollback_arguments
test_wizard_failure_restores_snapshot_without_scheduling_rollback
test_menu_excludes_ssh_from_quick_configuration

printf 'wizard_test: ok\n'
