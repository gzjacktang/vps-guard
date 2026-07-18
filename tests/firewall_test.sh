#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_firewall_test() {
	setup_test_root
	mkdir -p "$TEST_ROOT/fs/etc/nftables.d" "$TEST_ROOT/fs/etc/ssh"
	printf '#!/usr/sbin/nft -f\n' >"$TEST_ROOT/fs/etc/nftables.conf"
	printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
	printf '%s\n' /etc/nftables.conf /etc/nftables.d/vps-guard.nft /etc/vps-guard/firewall.conf >"$TEST_ROOT/managed-paths"
	write_stub id 'printf "0\n"'
	write_stub sshd 'printf "port 2222\n"'
	write_stub nft "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'; [[ \"\$1 \${2:-}\" == '-c -f' || \"\$1 \${2:-}\" == 'list ruleset' ]] && exit 0; [[ \"\$*\" == 'list table inet vps_guard' ]] && exit 1; [[ \"\$1\" == '-f' && -e '$TEST_ROOT/fail-live' ]] && exit 1; exit 0"
}

seed_enabled_firewall() {
	mkdir -p "$TEST_ROOT/fs/etc/vps-guard"
	printf '%s\n' enabled=1 ssh_ports=2222 tcp_ports=80 udp_ports=53 >"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	printf 'table inet vps_guard { }\n' >"$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
	printf 'include "/etc/nftables.d/vps-guard.nft" # vps-guard\n' >>"$TEST_ROOT/fs/etc/nftables.conf"
}

test_open_bootstraps_nftables_without_prior_enable() {
	setup_firewall_test
	trap teardown_test_root RETURN

	run_vps_guard firewall open --ports 8443 --protocol tcp --yes

	assert_status 0
	assert_output_contains "端口放行规则已更新。"
	grep -q '^enabled=1$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	grep -q '^ssh_ports=2222$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	grep -q '^tcp_ports=8443$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	grep -q 'tcp dport { 2222, 8443 } accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
	[[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_enable_preserves_third_party_tables_and_uses_isolated_nftables_table() {
	setup_firewall_test
	trap teardown_test_root RETURN
	printf 'table inet third_party { chain input { type filter hook input priority 10; } }\n' >>"$TEST_ROOT/fs/etc/nftables.conf"

	run_vps_guard firewall enable --tcp 80,443 --udp 53 --yes

	assert_status 0
	assert_output_contains "nftables 防火墙已启用。"
	grep -q 'table inet third_party' "$TEST_ROOT/fs/etc/nftables.conf"
	grep -q 'table inet vps_guard' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
	if grep -q 'flush ruleset' "$TEST_ROOT/nft.log"; then return 1; fi
	[[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_non_ssh_rollback_argument_is_rejected() {
	setup_firewall_test
	trap teardown_test_root RETURN

	run_vps_guard firewall enable --tcp 80 --rollback-minutes 5 --yes

	assert_status 2
	assert_output_contains "自动回滚仅支持 SSH 管理"
	[[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
}

test_runtime_failure_restores_snapshot_immediately() {
	setup_firewall_test
	trap teardown_test_root RETURN
	before="$(<"$TEST_ROOT/fs/etc/nftables.conf")"
	touch "$TEST_ROOT/fail-live"

	run_vps_guard firewall enable --tcp 80 --yes

	assert_status 1
	assert_output_contains "防火墙应用失败，已尝试恢复快照"
	[[ "$(<"$TEST_ROOT/fs/etc/nftables.conf")" == "$before" ]]
	[[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
	[[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
	[[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_open_close_and_disable_use_nftables_menu_contract() {
	setup_firewall_test
	trap teardown_test_root RETURN
	seed_enabled_firewall

	run_vps_guard firewall open --ports 443 --protocol tcp --yes
	assert_status 0
	grep -q '^tcp_ports=80,443$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	run_vps_guard firewall close --ports 80 --protocol tcp --yes
	assert_status 0
	grep -q '^tcp_ports=443$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
	run_vps_guard firewall disable --yes
	assert_status 0
	assert_output_contains "nftables 防火墙已停用。"
	[[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
}

test_open_bootstraps_nftables_without_prior_enable
test_enable_preserves_third_party_tables_and_uses_isolated_nftables_table
test_non_ssh_rollback_argument_is_rejected
test_runtime_failure_restores_snapshot_immediately
test_open_close_and_disable_use_nftables_menu_contract

printf 'firewall_test: ok\n'
