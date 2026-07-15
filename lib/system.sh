#!/usr/bin/env bash

OS_ID=""
OS_VERSION=""
# 以下状态由 UI 模块读取；ShellCheck 的单文件分析无法识别跨模块使用。
# shellcheck disable=SC2034
OS_PRETTY_NAME=""
SYSTEM_ARCH=""
# shellcheck disable=SC2034
SUPPORT_STATUS=""
MISSING_PACKAGES=()

# 不直接 source os-release，避免以 root 身份执行被篡改文件中的内容。
read_os_value() {
  local file="$1"
  local wanted_key="$2"
  local line key value

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    [[ "$key" == "$wanted_key" ]] || continue
    value="${line#*=}"
    value="${value#\"}"
    value="${value%\"}"
    value="${value#\'}"
    value="${value%\'}"
    printf '%s\n' "$value"
    return 0
  done <"$file"

  return 1
}

detect_system() {
  local os_release="${VPS_GUARD_OS_RELEASE:-/etc/os-release}"
  local raw_arch

  if [[ ! -r "$os_release" ]]; then
    error "无法读取系统信息：$os_release"
    return "$EXIT_FAILURE"
  fi

  OS_ID="$(read_os_value "$os_release" ID || true)"
  OS_VERSION="$(read_os_value "$os_release" VERSION_ID || true)"
  # 此状态由 UI 模块读取。
  # shellcheck disable=SC2034
  OS_PRETTY_NAME="$(read_os_value "$os_release" PRETTY_NAME || true)"
  raw_arch="$(uname -m)"

  case "$raw_arch" in
    x86_64 | amd64) SYSTEM_ARCH="amd64" ;;
    aarch64 | arm64) SYSTEM_ARCH="arm64" ;;
    *) SYSTEM_ARCH="$raw_arch" ;;
  esac

  # 此状态由 UI 模块读取。
  # shellcheck disable=SC2034
  SUPPORT_STATUS="未经验证"
  case "$OS_ID:$OS_VERSION:$SYSTEM_ARCH" in
    debian:12:amd64 | debian:12:arm64 | debian:13:amd64 | debian:13:arm64 | \
      ubuntu:22.04:amd64 | ubuntu:22.04:arm64 | ubuntu:24.04:amd64 | ubuntu:24.04:arm64 | \
      ubuntu:26.04:amd64 | ubuntu:26.04:arm64)
      # 此状态由 UI 模块读取。
      # shellcheck disable=SC2034
      SUPPORT_STATUS="正式支持"
      ;;
  esac
}

check_dependencies() {
  local command package status
  local dependencies=(
    "nft:nftables"
    "ss:iproute2"
    "systemctl:systemd"
    "sshd:openssh-server"
    "fail2ban-client:fail2ban"
  )

  MISSING_PACKAGES=()
  for dependency in "${dependencies[@]}"; do
    command="${dependency%%:*}"
    package="${dependency#*:}"
    status="已安装"
    if ! command_exists "$command"; then
      status="缺失"
      MISSING_PACKAGES+=("$package")
    fi
    printf '依赖 %s：%s\n' "$command" "$status"
  done
}

command_exists() {
  local wanted="$1"
  local search_path="${VPS_GUARD_COMMAND_PATH:-$PATH}"
  local directory
  local old_ifs="$IFS"

  IFS=:
  for directory in $search_path; do
    if [[ -x "${directory:-.}/$wanted" ]]; then
      IFS="$old_ifs"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

show_dependency_install_plan() {
  local package
  local unique_packages=()
  local seen=" "

  for package in "${MISSING_PACKAGES[@]}"; do
    if [[ "$seen" != *" $package "* ]]; then
      unique_packages+=("$package")
      seen+="$package "
    fi
  done

  if [[ "${#unique_packages[@]}" -gt 0 ]]; then
    printf '建议安装：sudo apt-get install'
    printf ' %s' "${unique_packages[@]}"
    printf '\n'
    printf '提示：status 仅展示计划，不会安装或升级任何软件。\n'
  fi
}

show_ssh_status() {
  if ! command_exists systemctl; then
    printf 'SSH 服务：无法检查（缺少 systemctl）\n'
    return 0
  fi

  if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
    printf 'SSH 服务：运行中\n'
  else
    printf 'SSH 服务：未运行或无法识别\n'
  fi
}

show_listening_ports() {
  local protocol _state _recv_queue _send_queue local_address _peer_address process
  local found=0

  if ! command_exists ss; then
    printf '监听端口：无法检查（缺少 ss）\n'
    return 0
  fi

  while read -r protocol _state _recv_queue _send_queue local_address _peer_address process; do
    [[ -n "$protocol" ]] || continue
    printf '监听：%s %s' "$protocol" "$local_address"
    if [[ -n "${process:-}" ]]; then
      printf ' %s' "$process"
    fi
    printf '\n'
    found=1
  done < <(ss -lntupH 2>/dev/null || true)

  if [[ "$found" -eq 0 ]]; then
    printf '监听端口：未发现或权限不足\n'
  fi
}
