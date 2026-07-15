#!/usr/bin/env bash

# ShellCheck 按单文件分析，无法看到由入口和其他模块使用的退出码。
# shellcheck disable=SC2034
readonly EXIT_FAILURE=1
# shellcheck disable=SC2034
readonly EXIT_USAGE=2
readonly EXIT_PERMISSION=4
# shellcheck disable=SC2034
readonly EXIT_UNSUPPORTED=5

error() {
  printf '错误：%s\n' "$*" >&2
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    error "此操作需要 root 权限，请使用 sudo vps-guard"
    return "$EXIT_PERMISSION"
  fi
}

audit_event() {
  local action="$1"
  local result="$2"
  local detail="${3:-}"
  local audit_log="${VPS_GUARD_AUDIT_LOG:-/var/log/vps-guard/audit.log}"
  local actor="${SUDO_USER:-$(id -un 2>/dev/null || printf root)}"
  detail="${detail//$'\n'/ }"
  detail="${detail//$'\r'/ }"
  detail="${detail//$'\t'/ }"
  if [[ "$actor" == *[!A-Za-z0-9._-]* || -z "$actor" ]]; then
    actor="unknown"
  fi
  umask 077
  mkdir -p "$(dirname "$audit_log")"
  chmod 0700 "$(dirname "$audit_log")"
  printf '%s uid=%s actor=%s action=%s result=%s %s\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$(id -u)" "$actor" "$action" "$result" "$detail" >>"$audit_log"
  chmod 0600 "$audit_log"
}

show_audit_log() {
  local audit_log="${VPS_GUARD_AUDIT_LOG:-/var/log/vps-guard/audit.log}"
  if [[ -r "$audit_log" ]]; then
    tail -n 100 "$audit_log"
  else
    printf '暂无审计记录。\n'
  fi
}
