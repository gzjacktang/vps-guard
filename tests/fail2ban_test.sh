#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_fail2ban_test() {
	setup_test_root
	mkdir -p "$TEST_ROOT/fs/etc/fail2ban/jail.d" "$TEST_ROOT/fs/etc/ssh"
	printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
	printf '%s\n' /etc/fail2ban/jail.d/vps-guard.local >"$TEST_ROOT/managed-paths"
	write_stub id 'case "$*" in -u) printf "0\n" ;; -un) printf "root\n" ;; esac'
	write_stub sshd '[[ "${1:-}" == -T ]] && { printf "port 22\n"; exit 0; }; exit 0'
	write_stub systemctl "if [[ \"\$*\" == 'restart fail2ban' && -e '$TEST_ROOT/fail-restart' ]]; then exit 1; fi; exit 0"
	write_stub fail2ban-client "if [[ \"\${1:-}\" == -t && -e '$TEST_ROOT/fail-validate' ]]; then exit 1; fi; [[ \"\$*\" == 'get sshd banip' ]] && { printf '198.51.100.8\\n'; exit 0; }; exit 0"
	TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 22"
}

test_apply_writes_nftables_policy_without_rollback() {
	setup_fail2ban_test
	trap teardown_test_root RETURN

	run_vps_guard fail2ban apply --preset standard --no-whitelist-current-ip --yes

	assert_status 0
	assert_output_contains "Fail2ban sshd 防护已启用。"
	config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
	grep -q '^backend = systemd$' "$config"
	grep -q '^banaction = nftables\[type=multiport\]$' "$config"
	grep -q '^port = 22$' "$config"
	[[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_non_ssh_rollback_arguments_are_rejected() {
	setup_fail2ban_test
	trap teardown_test_root RETURN

	run_vps_guard fail2ban apply --preset standard --rollback-minutes 5 --yes
	assert_status 2
	assert_output_contains "自动回滚仅支持 SSH 管理操作"
	run_vps_guard fail2ban restore snapshot --rollback-minutes 5 --yes
	assert_status 2
	assert_output_contains "自动回滚仅支持 SSH 管理操作"
}

test_live_failure_restores_original_configuration_immediately() {
	setup_fail2ban_test
	trap teardown_test_root RETURN
	printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled = false\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
	chmod 600 "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
	touch "$TEST_ROOT/fail-restart"

	run_vps_guard fail2ban apply --preset standard --no-whitelist-current-ip --yes

	assert_status 1
	assert_output_contains "已尝试原子恢复"
	grep -q '^enabled = false$' "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
	[[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_disable_removes_only_managed_file() {
	setup_fail2ban_test
	trap teardown_test_root RETURN
	printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled = true\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
	chmod 600 "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
	printf '[other]\nenabled = true\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/third-party.local"

	run_vps_guard fail2ban disable --yes

	assert_status 0
	[[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
	[[ -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/third-party.local" ]]
}

test_apply_writes_nftables_policy_without_rollback
test_non_ssh_rollback_arguments_are_rejected
test_live_failure_restores_original_configuration_immediately
test_disable_removes_only_managed_file

printf 'fail2ban_test: ok\n'
