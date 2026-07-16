#!/usr/bin/env bash

rollback_root() {
  printf '%s/rollbacks\n' "$(backup_data_dir)"
}

config_transaction_lock_dir() {
  printf '%s/config-transaction.lock\n' "$(backup_data_dir)"
}

prepare_config_transaction_lock_owner() {
  local lock_dir owner_dir
  lock_dir="$(config_transaction_lock_dir)"
  mkdir -p "$(dirname "$lock_dir")" || return "$EXIT_FAILURE"
  owner_dir="$(mktemp -d "$(dirname "$lock_dir")/.config-transaction.owner.XXXXXX")" || return "$EXIT_FAILURE"
  printf '%s\n' "${BASHPID:-$$}" >"$owner_dir/pid" || {
    rm -rf "$owner_dir"
    return "$EXIT_FAILURE"
  }
  CONFIG_TRANSACTION_OWNER_DIR="$owner_dir"
}

acquire_prepared_config_transaction_lock() {
  local owner_dir="$1" lock_dir owner_name
  lock_dir="$(config_transaction_lock_dir)"
  owner_name="${owner_dir##*/}"
  (
    set -o noclobber
    printf '%s\n' "$owner_name" >"$lock_dir"
  ) 2>/dev/null
}

release_config_transaction_lock() {
  local owner_dir="$1" lock_dir owner_name current=""
  lock_dir="$(config_transaction_lock_dir)"
  owner_name="${owner_dir##*/}"
  [[ ! -f "$lock_dir" || -L "$lock_dir" ]] || current="$(sed -n '1p' "$lock_dir" 2>/dev/null || true)"
  [[ "$current" != "$owner_name" ]] || rm -f "$lock_dir"
  rm -rf "$owner_dir"
}

clear_stale_config_transaction_lock() {
  local lock_dir target owner_dir owner=""
  lock_dir="$(config_transaction_lock_dir)"
  if [[ -f "$lock_dir" && ! -L "$lock_dir" ]]; then
    target="$(sed -n '1p' "$lock_dir" 2>/dev/null || true)"
    case "$target" in
      .config-transaction.owner.*) owner_dir="$(dirname "$lock_dir")/$target" ;;
      *)
        [[ "$(sed -n '1p' "$lock_dir" 2>/dev/null || true)" == "$target" ]] || return 1
        rm -f "$lock_dir"
        return $?
        ;;
    esac
    owner="$(sed -n '1p' "$owner_dir/pid" 2>/dev/null || true)"
    [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null && return 1
    [[ "$(sed -n '1p' "$lock_dir" 2>/dev/null || true)" == "$target" ]] || return 1
    rm -f "$lock_dir" || return 1
    rm -rf "$owner_dir"
    return 0
  fi
  # 兼容开发预览版留下的旧式目录锁；有效 PID 仍视为活动事务。
  if [[ -d "$lock_dir" ]]; then
    owner="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)"
    [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null && return 1
    rm -rf "$lock_dir"
    return $?
  fi
  [[ ! -e "$lock_dir" ]]
}

with_config_transaction_lock() (
  local owner_dir
  CONFIG_TRANSACTION_OWNER_DIR=""
  prepare_config_transaction_lock_owner || return $?
  owner_dir="$CONFIG_TRANSACTION_OWNER_DIR"
  if ! acquire_prepared_config_transaction_lock "$owner_dir"; then
    if ! clear_stale_config_transaction_lock || ! acquire_prepared_config_transaction_lock "$owner_dir"; then
      release_config_transaction_lock "$owner_dir"
      error "另一个配置事务正在准备或写入"
      return "$EXIT_CONFLICT"
    fi
  fi
  trap 'release_config_transaction_lock "$owner_dir"' EXIT INT TERM
  [[ "$(sed -n '1p' "$(config_transaction_lock_dir)" 2>/dev/null || true)" == "${owner_dir##*/}" ]] || return "$EXIT_CONFLICT"
  "$@"
)

with_config_transaction_lock_wait() (
  local owner_dir max_seconds ticks=0
  max_seconds="${VPS_GUARD_CONFIG_LOCK_WAIT_SECONDS:-60}"
  [[ "$max_seconds" =~ ^[0-9]+$ && "$max_seconds" -ge 1 && "$max_seconds" -le 600 ]] || max_seconds=60
  CONFIG_TRANSACTION_OWNER_DIR=""
  prepare_config_transaction_lock_owner || return $?
  owner_dir="$CONFIG_TRANSACTION_OWNER_DIR"
  while ! acquire_prepared_config_transaction_lock "$owner_dir"; do
    clear_stale_config_transaction_lock || true
    ticks=$((ticks + 1))
    if [[ "$ticks" -ge $((max_seconds * 10)) ]]; then
      release_config_transaction_lock "$owner_dir"
      error "配置事务锁等待超过 ${max_seconds} 秒；拒绝与仍可能写入的进程并发恢复"
      return "$EXIT_CONFLICT"
    fi
    sleep 0.1
  done
  trap 'release_config_transaction_lock "$owner_dir"' EXIT INT TERM
  [[ "$(sed -n '1p' "$(config_transaction_lock_dir)" 2>/dev/null || true)" == "${owner_dir##*/}" ]] || return "$EXIT_CONFLICT"
  "$@"
)

validate_rollback_token() {
  local token="$1"
  [[ -n "$token" && "$token" != "." && "$token" != ".." && "$token" != *[!A-Za-z0-9._-]* ]]
}

rollback_state_dir() {
  local token="$1"
  validate_rollback_token "$token" || {
    error "回滚令牌不合法"
    return "$EXIT_USAGE"
  }
  printf '%s/%s\n' "$(rollback_root)" "$token"
}

read_state_value() {
  local state_file="$1"
  local key="$2"
  sed -n "s/^${key}=//p" "$state_file"
}

acquire_rollback_lock() {
  local state_dir="$1"
  local lock_dir="$state_dir/lock"
  local owner
  for _ in {1..50}; do
    if mkdir "$lock_dir" 2>/dev/null; then
      printf '%s\n' "$$" >"$lock_dir/pid"
      return 0
    fi
    owner="$(sed -n '1p' "$lock_dir/pid" 2>/dev/null || true)"
    if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$lock_dir"
      continue
    fi
    sleep 0.1
  done
  error "回滚任务正由另一个进程处理"
  return "$EXIT_FAILURE"
}

release_rollback_lock() {
  rm -rf "$1/lock"
}

start_rollback() {
  local snapshot_id="$1"
  local minutes="$2"
  local hook="${3:-none}"
  local snapshot_dir token state_dir unit command_path

  case "$minutes" in
    3 | 5 | 10) ;;
    *)
      error "回滚时间只允许 3、5 或 10 分钟"
      return "$EXIT_USAGE"
      ;;
  esac
  case "$hook" in
    none | firewall | ssh-firewall | ssh-restore | ssh-hardening) ;;
    *)
      error "不支持的回滚钩子：$hook"
      return "$EXIT_USAGE"
      ;;
  esac

  snapshot_dir="$(snapshot_directory "$snapshot_id")" || return $?
  [[ -r "$snapshot_dir/manifest.tsv" ]] || {
    error "快照不存在：$snapshot_id"
    return "$EXIT_FAILURE"
  }

  token="rb-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
  unit="vps-guard-rollback-$token"
  command_path="${VPS_GUARD_COMMAND:-$VPS_GUARD_ROOT/vps-guard.sh}"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run：将在 %s 分钟后从快照 %s 自动回滚。\n' "$minutes" "$snapshot_id"
    return 0
  fi

  state_dir="$(rollback_state_dir "$token")"
  umask 077
  if ! mkdir -p "$state_dir" || ! printf 'token=%s\nsnapshot=%s\nminutes=%s\nunit=%s\nhook=%s\nstatus=pending\n' \
    "$token" "$snapshot_id" "$minutes" "$unit" "$hook" >"$state_dir/state"; then
    audit_event rollback.start failure "token=$token snapshot=$snapshot_id reason=state-write"
    error "无法写入自动回滚状态"
    return "$EXIT_FAILURE"
  fi

  if ! systemd-run --quiet --unit="$unit" --on-active="${minutes}m" --property=Type=oneshot \
    --property=Restart=on-failure --property=RestartSec=30s --collect \
    "$command_path" rollback run "$token"; then
    printf 'status=schedule-failed\n' >>"$state_dir/state"
    audit_event rollback.start failure "token=$token snapshot=$snapshot_id reason=schedule-failed"
    error "无法创建 systemd 自动回滚任务"
    return "$EXIT_FAILURE"
  fi

  audit_event rollback.start success "token=$token snapshot=$snapshot_id minutes=$minutes"
  printf '自动回滚已启动：%s\n将在 %s 分钟后执行。\n' "$token" "$minutes"
}

show_rollback_status() {
  local token="$1"
  local state_dir state_file status snapshot minutes
  state_dir="$(rollback_state_dir "$token")" || return $?
  state_file="$state_dir/state"
  [[ -r "$state_file" ]] || {
    error "未找到回滚任务：$token"
    return "$EXIT_FAILURE"
  }
  acquire_rollback_lock "$state_dir" || return $?
  status="$(read_state_value "$state_file" status | tail -1)"
  snapshot="$(read_state_value "$state_file" snapshot | tail -1)"
  minutes="$(read_state_value "$state_file" minutes | tail -1)"
  release_rollback_lock "$state_dir"
  case "$status" in
    pending) status="等待确认" ;;
    confirmed) status="已确认" ;;
    rolled-back) status="已回滚" ;;
    failed) status="回滚失败" ;;
    schedule-failed) status="调度失败" ;;
  esac
  printf '令牌：%s\n状态：%s\n快照：%s\n窗口：%s 分钟\n' "$token" "$status" "$snapshot" "$minutes"
}

confirm_rollback_under_lock() {
  local token="$1"
  local allow_managed="${2:-0}"
  local state_dir state_file status unit hook
  state_dir="$(rollback_state_dir "$token")" || return $?
  state_file="$state_dir/state"
  status="$(read_state_value "$state_file" status | tail -1)"
  hook="$(read_state_value "$state_file" hook | tail -1)"
  if [[ "$allow_managed" -ne 1 ]]; then
    case "$hook" in
      ssh-firewall)
        error "SSH 迁移回滚只能通过 ssh confirm 提交，不能直接取消"
        return "$EXIT_CONFLICT"
        ;;
      ssh-hardening)
        error "SSH 加固回滚只能通过 ssh harden confirm 提交，不能直接取消"
        return "$EXIT_CONFLICT"
        ;;
    esac
  fi
  case "$status" in
    confirmed)
      printf '此前已经确认，无需重复操作。\n'
      return 0
      ;;
    pending) ;;
    rolled-back)
      printf '回滚已经执行，无法再取消。\n'
      return 0
      ;;
    *)
      error "当前状态不能确认：$status"
      return "$EXIT_FAILURE"
      ;;
  esac

  unit="$(read_state_value "$state_file" unit | tail -1)"
  if ! systemctl stop "$unit.timer" "$unit.service" 2>/dev/null; then
    audit_event rollback.confirm failure "token=$token reason=cancel-failed"
    error "无法取消 systemd 回滚任务，状态保持等待确认"
    return "$EXIT_FAILURE"
  fi
  if ! printf 'status=confirmed\nconfirmed=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file"; then
    audit_event rollback.confirm failure "token=$token reason=state-write"
    error "systemd 任务已停止，但无法写入确认状态"
    return "$EXIT_FAILURE"
  fi
  audit_event rollback.confirm success "token=$token"
  printf '已确认，自动回滚已取消。\n'
}

confirm_rollback() {
  local token="$1"
  local allow_managed="${2:-0}"
  local state_dir state_file result=0
  state_dir="$(rollback_state_dir "$token")" || return $?
  state_file="$state_dir/state"
  [[ -r "$state_file" ]] || {
    error "未找到回滚任务：$token"
    return "$EXIT_FAILURE"
  }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run：将取消自动回滚 %s，但不会停止 systemd 单元或写入状态。\n' "$token"
    return 0
  fi
  acquire_rollback_lock "$state_dir" || return $?
  confirm_rollback_under_lock "$token" "$allow_managed" || result=$?
  release_rollback_lock "$state_dir"
  return "$result"
}

run_rollback() {
  local token="$1" result=0
  with_config_transaction_lock_wait run_rollback_unlocked "$@" || result=$?
  if [[ "$result" -ne 0 ]]; then
    audit_event rollback.run failure "token=$token reason=config-transaction-lock"
    error "自动回滚尚未执行；systemd 将重试。若事务进程持续卡住，请从带外控制台终止该进程后执行：vps-guard rollback run $token"
  fi
  return "$result"
}

run_rollback_unlocked() {
  local token="$1"
  local state_dir state_file status snapshot hook
  state_dir="$(rollback_state_dir "$token")" || return $?
  state_file="$state_dir/state"
  [[ -r "$state_file" ]] || {
    error "未找到回滚任务：$token"
    return "$EXIT_FAILURE"
  }
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'dry-run：将执行自动回滚 %s，但不会恢复文件或写入状态。\n' "$token"
    return 0
  fi
  acquire_rollback_lock "$state_dir" || return $?
  status="$(read_state_value "$state_file" status | tail -1)"
  case "$status" in
    rolled-back)
      release_rollback_lock "$state_dir"
      printf '此前已经回滚，无需重复操作。\n'
      return 0
      ;;
    confirmed)
      release_rollback_lock "$state_dir"
      printf '任务已经确认，不执行回滚。\n'
      return 0
      ;;
    pending | running) ;;
    failed)
      release_rollback_lock "$state_dir"
      error "此前回滚失败，未重复执行"
      return "$EXIT_FAILURE"
      ;;
    *)
      release_rollback_lock "$state_dir"
      error "当前状态不能执行回滚：$status"
      return "$EXIT_FAILURE"
      ;;
  esac

  snapshot="$(read_state_value "$state_file" snapshot | tail -1)"
  hook="$(read_state_value "$state_file" hook | tail -1)"
  hook="${hook:-none}"
  if ! printf 'status=running\n' >>"$state_file"; then
    audit_event rollback.run failure "token=$token snapshot=$snapshot reason=state-write"
    release_rollback_lock "$state_dir"
    error "无法写入回滚运行状态"
    return "$EXIT_FAILURE"
  fi
  if restore_snapshot "$snapshot" 1 && run_rollback_hook "$hook"; then
    if ! printf 'status=rolled-back\nfinished=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file"; then
      audit_event rollback.run failure "token=$token snapshot=$snapshot reason=state-write-after-restore"
      release_rollback_lock "$state_dir"
      error "配置已恢复，但无法写入完成状态"
      return "$EXIT_FAILURE"
    fi
    audit_event rollback.run success "token=$token snapshot=$snapshot"
    release_rollback_lock "$state_dir"
    printf '自动回滚完成：%s\n' "$token"
  else
    printf 'status=failed\n' >>"$state_file" || true
    audit_event rollback.run failure "token=$token snapshot=$snapshot"
    release_rollback_lock "$state_dir"
    error "自动回滚失败：$token"
    return "$EXIT_FAILURE"
  fi
}

run_rollback_hook() {
  # 文件快照恢复不会自动改变 sshd 或 nftables 运行时；网络事务必须同步两者，避免磁盘已恢复但旧规则仍生效。
  case "$1" in
    none | "") return 0 ;;
    firewall) reload_firewall_runtime ;;
    ssh-firewall | ssh-restore)
      local firewall_status=0 ssh_status=0
      reload_firewall_runtime || firewall_status=$?
      reload_sshd_runtime || ssh_status=$?
      [[ "$firewall_status" -eq 0 && "$ssh_status" -eq 0 ]]
      ;;
    ssh-hardening) reload_sshd_runtime ;;
    *)
      error "无法执行未知回滚钩子：$1"
      return "$EXIT_FAILURE"
      ;;
  esac
}

rollback_cli() {
  local action="${1:-}"
  local minutes=5

  case "$action" in
    start)
      [[ "$#" -ge 2 ]] || {
        error "用法：vps-guard rollback start <快照ID> [--minutes 3|5|10]"
        return "$EXIT_USAGE"
      }
      local snapshot_id="$2"
      shift 2
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --minutes)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            minutes="$2"
            shift 2
            ;;
          *)
            error "rollback start 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      start_rollback "$snapshot_id" "$minutes"
      ;;
    status)
      [[ "$#" -eq 2 ]] || return "$EXIT_USAGE"
      show_rollback_status "$2"
      ;;
    confirm)
      [[ "$#" -eq 2 ]] || return "$EXIT_USAGE"
      confirm_rollback "$2"
      ;;
    run)
      [[ "$#" -eq 2 ]] || return "$EXIT_USAGE"
      run_rollback "$2"
      ;;
    *)
      error "用法：vps-guard rollback <start|status|confirm|run>"
      return "$EXIT_USAGE"
      ;;
  esac
}
