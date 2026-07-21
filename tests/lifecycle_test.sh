#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_lifecycle_test() {
	setup_test_root
	mkdir -p "$TEST_ROOT/program/releases/1.0.0/lib" "$TEST_ROOT/data/backups" "$TEST_ROOT/log" "$TEST_ROOT/config"
	printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$TEST_ROOT/program/releases/1.0.0/vps-guard.sh"
	chmod 0755 "$TEST_ROOT/program/releases/1.0.0/vps-guard.sh"
	printf '1.0.0\n' >"$TEST_ROOT/program/releases/1.0.0/VERSION"
	printf '%s\n' 'signature=vps-guard-managed-install-v1' 'version=1.0.0' >"$TEST_ROOT/program/releases/1.0.0/INSTALL-MANIFEST"
	ln -s releases/1.0.0 "$TEST_ROOT/program/current"
	printf 'snapshot\n' >"$TEST_ROOT/data/backups/keep"
	printf 'audit\n' >"$TEST_ROOT/log/audit.log"
	printf 'config\n' >"$TEST_ROOT/config/keep.conf"
	printf '%s\n' '#!/usr/bin/env bash' '# VPS Guard managed launcher v1' "exec $TEST_ROOT/program/current/vps-guard.sh \"\$@\"" >"$TEST_ROOT/vps-guard"
	chmod 0755 "$TEST_ROOT/vps-guard"
	# shellcheck disable=SC2016
	write_stub id 'if [[ "${1:-}" == "-u" ]]; then printf "0\n"; else printf "root\n"; fi'
	export VPS_GUARD_PROGRAM_ROOT="$TEST_ROOT/program"
	export VPS_GUARD_COMMAND_LINK="$TEST_ROOT/vps-guard"
	export VPS_GUARD_CONFIG_DIR="$TEST_ROOT/config"
	export VPS_GUARD_AUDIT_LOG="$TEST_ROOT/log/audit.log"
	export VPS_GUARD_LIFECYCLE_LOCK="$TEST_ROOT/lifecycle.lock"
}

teardown_lifecycle_test() {
	unset VPS_GUARD_PROGRAM_ROOT VPS_GUARD_COMMAND_LINK VPS_GUARD_CONFIG_DIR VPS_GUARD_AUDIT_LOG VPS_GUARD_RELEASE_API VPS_GUARD_LIFECYCLE_LOCK
	teardown_test_root
}

test_default_uninstall_preserves_configuration_data_and_log() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN

	run_vps_guard uninstall --yes

	assert_status 0
	assert_output_contains "系统配置、快照和日志均已保留"
	[[ ! -e "$TEST_ROOT/program" && ! -e "$TEST_ROOT/vps-guard" ]]
	[[ -r "$TEST_ROOT/data/backups/keep" ]]
	[[ -r "$TEST_ROOT/log/audit.log" ]]
	[[ -r "$TEST_ROOT/config/keep.conf" ]]
}

test_purge_uses_the_same_single_confirmation() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN

	run_vps_guard uninstall --yes --purge-data
	assert_status 0
	[[ ! -e "$TEST_ROOT/program" && ! -e "$TEST_ROOT/data" && ! -e "$TEST_ROOT/log/audit.log" ]]
	[[ -r "$TEST_ROOT/config/keep.conf" ]]
}

test_active_rollback_warns_but_allows_uninstall() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	mkdir -p "$TEST_ROOT/data/rollbacks/rb-active"
	printf '%s\n' 'status=pending' >"$TEST_ROOT/data/rollbacks/rb-active/state"

	run_vps_guard uninstall --yes

	assert_status 0
	assert_output_contains "警告"
	assert_output_contains "自动回滚"
	[[ ! -e "$TEST_ROOT/program" && ! -e "$TEST_ROOT/vps-guard" ]]
}

test_untrusted_launcher_blocks_uninstall_without_deleting_files() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	printf '%s\n' '#!/usr/bin/env bash' 'echo unrelated' >"$TEST_ROOT/vps-guard"
	chmod 0755 "$TEST_ROOT/vps-guard"

	run_vps_guard uninstall --yes

	assert_status 3
	assert_output_contains "launcher 归属不可信"
	[[ -d "$TEST_ROOT/program" && -x "$TEST_ROOT/vps-guard" ]]
}

test_missing_rollback_state_warns_but_allows_uninstall() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	mkdir -p "$TEST_ROOT/data/rollbacks/rb-unknown"

	run_vps_guard uninstall --yes

	assert_status 0
	assert_output_contains "警告"
	[[ ! -e "$TEST_ROOT/program" && ! -e "$TEST_ROOT/vps-guard" ]]
}

test_symlink_rollback_state_warns_but_allows_uninstall() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	mkdir -p "$TEST_ROOT/data/rollbacks/rb-link"
	printf 'status=confirmed\n' >"$TEST_ROOT/terminal-state"
	ln -s "$TEST_ROOT/terminal-state" "$TEST_ROOT/data/rollbacks/rb-link/state"

	run_vps_guard uninstall --yes

	assert_status 0
	assert_output_contains "警告"
	[[ ! -e "$TEST_ROOT/program" && ! -e "$TEST_ROOT/vps-guard" ]]
}

test_pending_ssh_enrollment_cleanup_warns_but_allows_uninstall() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	mkdir -p "$TEST_ROOT/data/ssh-enrollments/key-pending"
	printf 'status=pending-cleanup\n' >"$TEST_ROOT/data/ssh-enrollments/key-pending/state"

	run_vps_guard uninstall --yes

	assert_status 0
	assert_output_contains "警告"
	[[ ! -e "$TEST_ROOT/program" && ! -e "$TEST_ROOT/vps-guard" ]]
}

test_launcher_delete_failure_restores_program_directory() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	write_stub rm "if [[ \"\${1:-}\" == '-f' && \"\${2:-}\" == '$TEST_ROOT/vps-guard' ]]; then exit 1; fi; exec /bin/rm \"\$@\""

	run_vps_guard uninstall --yes

	assert_status 1
	assert_output_contains "已尝试恢复程序目录"
	[[ -d "$TEST_ROOT/program/releases/1.0.0" && -x "$TEST_ROOT/vps-guard" ]]
	[[ "$(readlink "$TEST_ROOT/program/current")" == releases/1.0.0 ]]
}

test_lifecycle_lock_blocks_new_security_configuration_transaction() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	mkdir -p "$TEST_ROOT/lifecycle.lock"
	printf '99999\n' >"$TEST_ROOT/lifecycle.lock/pid"

	run_vps_guard ssh migrate --port 2222 --yes

	assert_status 3
	assert_output_contains "安装、更新或卸载事务正在运行"
	[[ ! -e "$TEST_ROOT/data/config-transaction.lock" ]]
}

test_update_check_only_reads_release_metadata() {
	setup_lifecycle_test
	trap teardown_lifecycle_test RETURN
	write_stub curl "printf '%s\\n' '{\"tag_name\":\"v1.1.0\",\"html_url\":\"https://github.com/gzjacktang/vps-guard/releases/tag/v1.1.0\"}'; printf '%s\\n' \"\$*\" >'$TEST_ROOT/curl.args'"
	export VPS_GUARD_RELEASE_API="https://api.github.com/repos/gzjacktang/vps-guard/releases/latest"

	run_vps_guard update check

	assert_status 0
	assert_output_contains "只读取 Release 元数据，不下载或执行脚本"
	assert_output_contains "最新发布：1.1.0"
	assert_output_contains "sudo ./install.sh --update"
	grep -q -- "--proto =https" "$TEST_ROOT/curl.args"
	[[ -e "$TEST_ROOT/program" ]]
}

test_default_uninstall_preserves_configuration_data_and_log
test_purge_uses_the_same_single_confirmation
test_active_rollback_warns_but_allows_uninstall
test_untrusted_launcher_blocks_uninstall_without_deleting_files
test_missing_rollback_state_warns_but_allows_uninstall
test_symlink_rollback_state_warns_but_allows_uninstall
test_pending_ssh_enrollment_cleanup_warns_but_allows_uninstall
test_launcher_delete_failure_restores_program_directory
test_lifecycle_lock_blocks_new_security_configuration_transaction
test_update_check_only_reads_release_metadata

printf 'lifecycle_test: ok\n'
