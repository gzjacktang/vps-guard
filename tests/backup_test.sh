#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_user_can_create_and_list_snapshot() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'

  run_vps_guard backup create --label before-change
  assert_status 0
  assert_output_contains "快照已创建："
  assert_output_contains "标签：before-change"

  run_vps_guard backup list
  assert_status 0
  assert_output_contains "before-change"
  assert_output_contains "文件：1"
}

test_user_can_compare_snapshot_with_current_config() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'

  run_vps_guard backup create --label compare
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"

  run_vps_guard backup diff "$snapshot_id"

  assert_status 0
  assert_output_contains "已更改：/etc/ssh/sshd_config"
}

test_user_can_restore_snapshot_after_explicit_confirmation() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'

  run_vps_guard backup create --label restore
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"

  run_vps_guard backup restore "$snapshot_id" --yes
  assert_status 0
  assert_output_contains "快照恢复完成：$snapshot_id"

  run_vps_guard backup diff "$snapshot_id"
  assert_status 0
  assert_output_contains "当前配置与快照一致"
}

test_snapshot_retention_defaults_to_ten() {
  local index listed_count
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'

  for index in $(seq 1 11); do
    run_vps_guard backup create --label "snapshot-$index"
    assert_status 0
  done
  run_vps_guard backup list
  listed_count="$(printf '%s\n' "$COMMAND_OUTPUT" | grep -c '标签：')"
  if [[ "$listed_count" -ne 10 ]]; then
    printf '期望保留 10 份快照，实际为 %s\n%s\n' "$listed_count" "$COMMAND_OUTPUT" >&2
    return 1
  fi
}

test_snapshot_recursively_captures_managed_directory() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh/sshd_config.d"
  printf 'PasswordAuthentication yes\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/10-provider.conf"
  printf 'PermitRootLogin yes\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/20-admin.conf"
  printf '/etc/ssh/sshd_config.d\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'

  run_vps_guard backup create --label directory
  assert_output_contains "文件：2"
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"

  printf 'PasswordAuthentication no\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/10-provider.conf"
  printf 'X11Forwarding no\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/99-new.conf"
  run_vps_guard backup diff "$snapshot_id"
  assert_output_contains "新增：/etc/ssh/sshd_config.d/99-new.conf"
  run_vps_guard backup restore "$snapshot_id" --yes
  assert_status 0
  run_vps_guard backup diff "$snapshot_id"
  assert_output_contains "当前配置与快照一致"
}

test_restore_removes_managed_file_that_was_absent_in_snapshot() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  printf '/etc/fail2ban/jail.d/vps-guard.local\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'

  run_vps_guard backup create --label absent-file
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  mkdir -p "$TEST_ROOT/fs/etc/fail2ban/jail.d"
  printf '[sshd]\nenabled=true\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"

  run_vps_guard backup diff "$snapshot_id"
  assert_output_contains "新增：/etc/fail2ban/jail.d/vps-guard.local"

  run_vps_guard backup restore "$snapshot_id" --yes
  assert_status 0
  run_vps_guard backup diff "$snapshot_id"
  assert_output_contains "当前配置与快照一致"
}

test_corrupted_snapshot_is_rejected_before_overwrite() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  run_vps_guard backup create --label corruption
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"

  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf 'tampered\n' >"$TEST_ROOT/data/backups/$snapshot_id/files/etc/ssh/sshd_config"
  run_vps_guard backup restore "$snapshot_id" --yes

  assert_status 1
  assert_output_contains "快照文件校验失败"
  if [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" != "Port 2222" ]]; then
    printf '校验失败后当前配置被覆盖\n' >&2
    return 1
  fi
}

test_partial_restore_failure_rolls_back_all_replaced_files() {
  local snapshot_id mv_counter
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf 'PasswordAuthentication yes\n' >"$TEST_ROOT/fs/etc/ssh/auth.conf"
  printf '%s\n' '/etc/ssh/sshd_config' '/etc/ssh/auth.conf' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  run_vps_guard backup create --label atomicity
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"

  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf 'PasswordAuthentication no\n' >"$TEST_ROOT/fs/etc/ssh/auth.conf"
  mv_counter="$TEST_ROOT/mv-counter"
  write_stub mv "
if [[ \"\$1\" == *'.vps-guard-stage.'* ]]; then
  count=0
  [[ -r '$mv_counter' ]] && count=\$(<'$mv_counter')
  count=\$((count + 1))
  printf '%s\\n' \"\$count\" >'$mv_counter'
  [[ \"\$count\" -eq 2 ]] && exit 1
fi
exec /bin/mv \"\$@\"
"

  run_vps_guard backup restore "$snapshot_id" --yes

  assert_status 1
  assert_output_contains "恢复失败，已回退先前文件"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == "Port 2222" ]]
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/auth.conf")" == "PasswordAuthentication no" ]]
}

test_failure_while_staging_second_current_file_rolls_back_first() {
  local snapshot_id mv_counter
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf 'PasswordAuthentication yes\n' >"$TEST_ROOT/fs/etc/ssh/auth.conf"
  printf '%s\n' '/etc/ssh/sshd_config' '/etc/ssh/auth.conf' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  run_vps_guard backup create --label atomic-current
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf 'PasswordAuthentication no\n' >"$TEST_ROOT/fs/etc/ssh/auth.conf"
  mv_counter="$TEST_ROOT/mv-original-counter"
  write_stub mv "
if [[ \"\$2\" == *'.vps-guard-original.'* ]]; then
  count=0
  [[ -r '$mv_counter' ]] && count=\$(<'$mv_counter')
  count=\$((count + 1))
  printf '%s\\n' \"\$count\" >'$mv_counter'
  [[ \"\$count\" -eq 2 ]] && exit 1
fi
exec /bin/mv \"\$@\"
"

  run_vps_guard backup restore "$snapshot_id" --yes

  assert_status 1
  assert_output_contains "无法暂存当前配置"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == "Port 2222" ]]
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/auth.conf")" == "PasswordAuthentication no" ]]
}

test_restore_dry_run_lists_deletions_without_changing_files() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh/sshd_config.d"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/base.conf"
  printf '/etc/ssh/sshd_config.d\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  run_vps_guard backup create --label restore-dry-run
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config.d/new.conf"

  run_vps_guard --dry-run backup restore "$snapshot_id" --yes

  assert_status 0
  assert_output_contains "将恢复：/etc/ssh/sshd_config.d/base.conf"
  assert_output_contains "将删除：/etc/ssh/sshd_config.d/new.conf"
  [[ -f "$TEST_ROOT/fs/etc/ssh/sshd_config.d/new.conf" ]]
}

test_user_can_create_and_list_snapshot
test_user_can_compare_snapshot_with_current_config
test_user_can_restore_snapshot_after_explicit_confirmation
test_snapshot_retention_defaults_to_ten
test_snapshot_recursively_captures_managed_directory
test_restore_removes_managed_file_that_was_absent_in_snapshot
test_corrupted_snapshot_is_rejected_before_overwrite
test_partial_restore_failure_rolls_back_all_replaced_files
test_failure_while_staging_second_current_file_rolls_back_first
test_restore_dry_run_lists_deletions_without_changing_files
