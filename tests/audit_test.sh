#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_snapshot_and_rollback_actions_are_audited() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  TEST_SUDO_USER="alice"

  run_vps_guard backup create --label audit-check
  assert_status 0
  run_vps_guard audit list

  assert_status 0
  assert_output_contains "action=snapshot.create"
  assert_output_contains "result=success"
  assert_output_contains "files=1"
  assert_output_contains "actor=alice"
  TEST_SUDO_USER=""
}

test_failed_rollback_schedule_is_audited() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'exit 1'
  run_vps_guard backup create --label schedule-failure
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"

  run_vps_guard rollback start "$snapshot_id"
  assert_status 1
  run_vps_guard audit list
  assert_output_contains "action=rollback.start"
  assert_output_contains "result=failure"
}

test_failed_snapshot_restore_is_audited() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  run_vps_guard backup create --label restore-failure
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  printf 'tampered\n' >"$TEST_ROOT/data/backups/$snapshot_id/files/etc/ssh/sshd_config"

  run_vps_guard backup restore "$snapshot_id" --yes
  assert_status 1
  run_vps_guard audit list
  assert_output_contains "action=snapshot.restore"
  assert_output_contains "result=failure"
}

test_audit_log_does_not_record_user_supplied_secret_label() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  run_vps_guard backup create --label 'password=supersecret'
  assert_status 0

  run_vps_guard audit list
  assert_output_not_contains "supersecret"
}

test_snapshot_and_audit_storage_are_root_only() {
  local data_mode backup_mode audit_mode
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  run_vps_guard backup create --label permissions
  assert_status 0

  data_mode="$(stat -c '%a' "$TEST_ROOT/data" 2>/dev/null || stat -f '%Lp' "$TEST_ROOT/data")"
  backup_mode="$(stat -c '%a' "$TEST_ROOT/data/backups" 2>/dev/null || stat -f '%Lp' "$TEST_ROOT/data/backups")"
  audit_mode="$(stat -c '%a' "$TEST_ROOT/log/audit.log" 2>/dev/null || stat -f '%Lp' "$TEST_ROOT/log/audit.log")"
  [[ "$data_mode" == "700" && "$backup_mode" == "700" && "$audit_mode" == "600" ]]
}

test_snapshot_io_failure_is_audited() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub cp 'exit 1'

  run_vps_guard backup create --label io-failure
  assert_status 1
  run_vps_guard audit list
  assert_output_contains "action=snapshot.create"
  assert_output_contains "result=failure"
  assert_output_contains "reason=copy"
}

test_snapshot_storage_prepare_failure_is_audited() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub mkdir '
if [[ "$*" == *".tmp/files"* ]]; then
  exit 1
fi
exec /bin/mkdir "$@"
'

  run_vps_guard backup create --label prepare-failure
  assert_status 1
  run_vps_guard audit list
  assert_output_contains "action=snapshot.create"
  assert_output_contains "result=failure"
  assert_output_contains "reason=prepare-snapshot"
}

test_snapshot_directory_traversal_failure_is_audited() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh/sshd_config.d"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/base.conf"
  printf '/etc/ssh/sshd_config.d\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub find "
if [[ \"\$1\" == '$TEST_ROOT/fs/etc/ssh/sshd_config.d' ]]; then
  exit 1
fi
exec /usr/bin/find \"\$@\"
"

  run_vps_guard backup create --label traversal-failure
  assert_status 1
  assert_output_contains "无法展开受管文件列表"
  run_vps_guard audit list
  assert_output_contains "action=snapshot.create"
  assert_output_contains "result=failure"
  assert_output_contains "reason=traverse"
}

test_snapshot_cleanup_failure_does_not_hide_original_audit() {
  local rm_counter
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub cp 'exit 1'
  rm_counter="$TEST_ROOT/rm-counter"
  write_stub rm "
if [[ \"\$*\" == *'.tmp'* ]]; then
  count=0
  [[ -r '$rm_counter' ]] && count=\$(<'$rm_counter')
  count=\$((count + 1))
  printf '%s\n' \"\$count\" >'$rm_counter'
  [[ \"\$count\" -eq 2 ]] && exit 1
fi
exec /bin/rm \"\$@\"
"

  run_vps_guard backup create --label cleanup-failure
  assert_status 1
  run_vps_guard audit list
  assert_output_contains "action=snapshot.create"
  assert_output_contains "result=failure"
  assert_output_contains "reason=copy"
}

test_snapshot_and_rollback_actions_are_audited
test_failed_rollback_schedule_is_audited
test_failed_snapshot_restore_is_audited
test_audit_log_does_not_record_user_supplied_secret_label
test_snapshot_and_audit_storage_are_root_only
test_snapshot_io_failure_is_audited
test_snapshot_storage_prepare_failure_is_audited
test_snapshot_directory_traversal_failure_is_audited
test_snapshot_cleanup_failure_does_not_hide_original_audit
