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
