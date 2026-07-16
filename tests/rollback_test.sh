#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_user_can_schedule_and_query_rollback() {
  local snapshot_id token
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemd-run.log'"

  run_vps_guard backup create --label rollback-base
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"

  run_vps_guard rollback start "$snapshot_id" --minutes 5
  assert_status 0
  assert_output_contains "自动回滚已启动："
  assert_output_contains "将在 5 分钟后执行"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"

  run_vps_guard rollback status "$token"
  assert_status 0
  assert_output_contains "状态：等待确认"
  assert_output_contains "快照：$snapshot_id"
}

test_confirmation_cancels_pending_rollback_idempotently() {
  local snapshot_id token
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'exit 0'
  write_stub systemctl "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemctl.log'; exit 0"

  run_vps_guard backup create --label confirm-base
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  run_vps_guard rollback start "$snapshot_id" --minutes 3
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"

  run_vps_guard rollback confirm "$token"
  assert_status 0
  assert_output_contains "已确认，自动回滚已取消"
  if ! grep -q '\.timer' "$TEST_ROOT/systemctl.log" || ! grep -q '\.service' "$TEST_ROOT/systemctl.log"; then
    printf '确认操作没有同时停止 timer 与 service\n' >&2
    return 1
  fi

  run_vps_guard rollback confirm "$token"
  assert_status 0
  assert_output_contains "此前已经确认"

  run_vps_guard rollback status "$token"
  assert_output_contains "状态：已确认"
}

test_timer_execution_restores_snapshot_and_is_idempotent() {
  local snapshot_id token
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'exit 0'

  run_vps_guard backup create --label timer-base
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  run_vps_guard rollback start "$snapshot_id"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"

  run_vps_guard rollback run "$token"
  assert_status 0
  assert_output_contains "自动回滚完成"

  run_vps_guard rollback run "$token"
  assert_status 0
  assert_output_contains "此前已经回滚"

  run_vps_guard backup diff "$snapshot_id"
  assert_output_contains "当前配置与快照一致"
}

test_timer_waits_for_active_configuration_transaction() {
  local snapshot_id token rollback_pid
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'exit 0'

  run_vps_guard backup create --label serialized-rollback
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  run_vps_guard rollback start "$snapshot_id"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"

  mkdir -p "$TEST_ROOT/data/.config-transaction.owner.test-wait"
  printf '%s\n' "$$" >"$TEST_ROOT/data/.config-transaction.owner.test-wait/pid"
  printf '%s\n' '.config-transaction.owner.test-wait' >"$TEST_ROOT/data/config-transaction.lock"
  PATH="$TEST_ROOT/bin:$PATH" \
    VPS_GUARD_FS_ROOT="$TEST_ROOT/fs" \
    VPS_GUARD_DATA_DIR="$TEST_ROOT/data" \
    VPS_GUARD_AUDIT_LOG="$TEST_ROOT/log/audit.log" \
    VPS_GUARD_MANAGED_PATHS_FILE="$TEST_ROOT/managed-paths" \
    "$PROJECT_ROOT/vps-guard.sh" rollback run "$token" >"$TEST_ROOT/rollback-wait.out" 2>&1 &
  rollback_pid=$!
  sleep 0.2
  kill -0 "$rollback_pid"
  grep -q 'Port 2222' "$TEST_ROOT/fs/etc/ssh/sshd_config"

  rm -rf "$TEST_ROOT/data/config-transaction.lock"
  wait "$rollback_pid"
  grep -q '自动回滚完成' "$TEST_ROOT/rollback-wait.out"
  grep -q 'Port 22' "$TEST_ROOT/fs/etc/ssh/sshd_config"
}

test_timer_lock_timeout_is_audited_and_stale_lock_is_retryable() {
  local snapshot_id token
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'exit 0'
  run_vps_guard backup create --label lock-timeout
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  run_vps_guard rollback start "$snapshot_id"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"

  mkdir -p "$TEST_ROOT/data/.config-transaction.owner.test-timeout"
  printf '%s\n' "$$" >"$TEST_ROOT/data/.config-transaction.owner.test-timeout/pid"
  printf '%s\n' '.config-transaction.owner.test-timeout' >"$TEST_ROOT/data/config-transaction.lock"
  set +e
  COMMAND_OUTPUT="$(PATH="$TEST_ROOT/bin:$PATH" \
    VPS_GUARD_FS_ROOT="$TEST_ROOT/fs" \
    VPS_GUARD_DATA_DIR="$TEST_ROOT/data" \
    VPS_GUARD_AUDIT_LOG="$TEST_ROOT/log/audit.log" \
    VPS_GUARD_MANAGED_PATHS_FILE="$TEST_ROOT/managed-paths" \
    VPS_GUARD_CONFIG_LOCK_WAIT_SECONDS=1 \
    "$PROJECT_ROOT/vps-guard.sh" rollback run "$token" 2>&1)"
  COMMAND_STATUS=$?
  set -e
  assert_status 3
  assert_output_contains "systemd 将重试"
  grep -q 'reason=config-transaction-lock' "$TEST_ROOT/log/audit.log"
  grep -q 'Port 2222' "$TEST_ROOT/fs/etc/ssh/sshd_config"

  rm -rf "$TEST_ROOT/data/config-transaction.lock"
  : >"$TEST_ROOT/data/config-transaction.lock"
  run_vps_guard rollback run "$token"
  assert_status 0
  assert_output_contains "自动回滚完成"
  grep -q 'Port 22' "$TEST_ROOT/fs/etc/ssh/sshd_config"
}

test_dry_run_does_not_create_systemd_task_or_state() {
  local snapshot_id
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'printf "unexpected systemd call\n" >&2; exit 1'
  run_vps_guard backup create --label dry-run-base
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"

  run_vps_guard --dry-run rollback start "$snapshot_id" --minutes 10

  assert_status 0
  assert_output_contains "dry-run：将在 10 分钟后"
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_concurrent_confirm_wins_over_timer_run() {
  local snapshot_id token confirm_pid run_pid
  local common_env=()
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'exit 0'
  write_stub systemctl 'sleep 1; exit 0'
  run_vps_guard backup create --label concurrency-base
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  run_vps_guard rollback start "$snapshot_id"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  printf 'Port 2222\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"

  common_env=(
    "PATH=$TEST_ROOT/bin:$PATH"
    "VPS_GUARD_FS_ROOT=$TEST_ROOT/fs"
    "VPS_GUARD_DATA_DIR=$TEST_ROOT/data"
    "VPS_GUARD_AUDIT_LOG=$TEST_ROOT/log/audit.log"
    "VPS_GUARD_MANAGED_PATHS_FILE=$TEST_ROOT/managed-paths"
  )
  env "${common_env[@]}" "$PROJECT_ROOT/vps-guard.sh" rollback confirm "$token" >"$TEST_ROOT/confirm.out" 2>&1 &
  confirm_pid=$!
  sleep 0.1
  env "${common_env[@]}" "$PROJECT_ROOT/vps-guard.sh" rollback run "$token" >"$TEST_ROOT/run.out" 2>&1 &
  run_pid=$!
  wait "$confirm_pid"
  wait "$run_pid"

  if [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" != "Port 2222" ]]; then
    printf '并发确认后仍执行了回滚\n' >&2
    return 1
  fi
  if [[ "$(<"$TEST_ROOT/run.out")" != *"任务已经确认，不执行回滚"* ]]; then
    printf '并发 run 未观察到 confirmed 状态\n%s\n' "$(<"$TEST_ROOT/run.out")" >&2
    return 1
  fi
}

test_dry_run_confirm_does_not_stop_or_change_pending_task() {
  local snapshot_id token
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/etc/ssh"
  printf 'Port 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '/etc/ssh/sshd_config\n' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub systemd-run 'exit 0'
  write_stub systemctl 'printf "unexpected stop\n" >&2; exit 1'
  run_vps_guard backup create --label dry-confirm
  snapshot_id="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  run_vps_guard rollback start "$snapshot_id"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"

  run_vps_guard --dry-run rollback confirm "$token"
  assert_status 0
  assert_output_contains "dry-run：将取消自动回滚"
  run_vps_guard rollback status "$token"
  assert_output_contains "状态：等待确认"
}

test_user_can_schedule_and_query_rollback
test_confirmation_cancels_pending_rollback_idempotently
test_timer_execution_restores_snapshot_and_is_idempotent
test_timer_waits_for_active_configuration_transaction
test_timer_lock_timeout_is_audited_and_stale_lock_is_retryable
test_dry_run_does_not_create_systemd_task_or_state
test_concurrent_confirm_wins_over_timer_run
test_dry_run_confirm_does_not_stop_or_change_pending_task
