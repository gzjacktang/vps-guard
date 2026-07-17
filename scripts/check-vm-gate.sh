#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VALIDATION_ROOT="${VPS_GUARD_VM_GATE_ROOT:-$ROOT/validation/vm}"
GATE="$VALIDATION_ROOT/v1.env"

[[ -r "$GATE" ]] || {
  printf '错误：缺少真实 VM 门禁记录：%s\n' "$GATE" >&2
  exit 1
}
# 只接受固定字段，避免 source 未经验证的数据文件。
awk -F= '$1 !~ /^(status|artifact_sha256|debian_result|ubuntu_result)$/ { exit 1 }' "$GATE"
status="$(sed -n 's/^status=//p' "$GATE")"
artifact_sha256="$(sed -n 's/^artifact_sha256=//p' "$GATE")"
debian_result="$(sed -n 's/^debian_result=//p' "$GATE")"
ubuntu_result="$(sed -n 's/^ubuntu_result=//p' "$GATE")"
[[ "$status" == PASS && "$artifact_sha256" =~ ^[0-9a-f]{64}$ && "$debian_result" == PASS && "$ubuntu_result" == PASS ]] || {
  printf '错误：真实 Debian/Ubuntu VM 发布门禁尚未通过。\n' >&2
  exit 1
}

check_result() {
  local file="$1" expected_os="$2" key count value version arch date_utc
  local required=(status os version arch artifact_sha256 sshd systemd nftables fail2ban disconnect_rollback wizard date_utc)
  [[ -f "$file" && ! -L "$file" ]] || return 1
  awk -F= '$1 !~ /^(status|os|version|arch|artifact_sha256|sshd|systemd|nftables|fail2ban|disconnect_rollback|wizard|date_utc)$/ { exit 1 }' "$file" || return 1
  for key in "${required[@]}"; do
    count="$(grep -c "^${key}=" "$file" || true)"
    [[ "$count" -eq 1 ]] || return 1
  done
  [[ "$(sed -n 's/^status=//p' "$file")" == PASS ]] || return 1
  [[ "$(sed -n 's/^os=//p' "$file")" == "$expected_os" ]] || return 1
  version="$(sed -n 's/^version=//p' "$file")"
  arch="$(sed -n 's/^arch=//p' "$file")"
  date_utc="$(sed -n 's/^date_utc=//p' "$file")"
  if [[ "$expected_os" == debian ]]; then
    [[ "$version" == 12 || "$version" == 13 ]] || return 1
  else
    [[ "$version" == 22.04 || "$version" == 24.04 || "$version" == 26.04 ]] || return 1
  fi
  [[ "$arch" == amd64 || "$arch" == arm64 ]] || return 1
  [[ "$date_utc" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [[ "$(sed -n 's/^artifact_sha256=//p' "$file")" == "$artifact_sha256" ]] || return 1
  for key in sshd systemd nftables fail2ban disconnect_rollback wizard; do
    value="$(sed -n "s/^${key}=//p" "$file")"
    [[ "$value" == PASS ]] || return 1
  done
}

check_result "$VALIDATION_ROOT/debian.env" debian || {
  printf '错误：Debian VM 脱敏结果不完整或与 artifact 不匹配。\n' >&2
  exit 1
}
check_result "$VALIDATION_ROOT/ubuntu.env" ubuntu || {
  printf '错误：Ubuntu VM 脱敏结果不完整或与 artifact 不匹配。\n' >&2
  exit 1
}
printf '真实 VM 发布门禁通过：artifact_sha256=%s\n' "$artifact_sha256"
