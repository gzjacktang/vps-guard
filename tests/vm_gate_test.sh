#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"
# 可移植 sed -i：Linux 和 macOS 兼容
portable_sed() { sed -i.bak "$@" && rm -f "${*: -1}.bak"; }

# ---- 辅助：构建完整合法门禁，然后替换单个文件 ----
setup_valid_gate() {
  local gate_root="$1"
  local sha256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  mkdir -p "$gate_root"

  cat >"$gate_root/v1.env" <<GATE
status=PASS
artifact_sha256=$sha256
debian_result=PASS
ubuntu_result=PASS
GATE

  cat >"$gate_root/debian.env" <<DEB
status=PASS
os=debian
version=12
arch=amd64
artifact_sha256=$sha256
sshd=PASS
systemd=PASS
nftables=PASS
fail2ban=PASS
disconnect_rollback=PASS
wizard=PASS
date_utc=2026-07-15T10:00:00Z
DEB

  cat >"$gate_root/ubuntu.env" <<UBU
status=PASS
os=ubuntu
version=24.04
arch=amd64
artifact_sha256=$sha256
sshd=PASS
systemd=PASS
nftables=PASS
fail2ban=PASS
disconnect_rollback=PASS
wizard=PASS
date_utc=2026-07-15T10:00:00Z
UBU
}

run_vm_gate() {
  local gate_root="$1"
  set +e
  COMMAND_OUTPUT="$(VPS_GUARD_VM_GATE_ROOT="$gate_root" "$PROJECT_ROOT/scripts/check-vm-gate.sh" 2>&1)"
  COMMAND_STATUS=$?
  set -e
}

# ---- 测试：合法门禁通过 ----
test_valid_gate_passes() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"

  run_vm_gate "$gate_root"
  assert_status 0
  assert_output_contains "真实 VM 发布门禁通过"
}

# ---- 测试：不支持的 Debian 版本被拒绝 ----
test_rejects_unsupported_debian_version() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"
  # Debian 11 不在支持范围
  portable_sed 's/^version=12$/version=11/' "$gate_root/debian.env"

  run_vm_gate "$gate_root"
  assert_status 1
}

# ---- 测试：不支持的 Ubuntu 版本被拒绝 ----
test_rejects_unsupported_ubuntu_version() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"
  # Ubuntu 20.04 不在支持范围
  portable_sed 's/^version=24\.04$/version=20.04/' "$gate_root/ubuntu.env"

  run_vm_gate "$gate_root"
  assert_status 1
}

# ---- 测试：非 amd64/arm64 架构被拒绝 ----
test_rejects_unsupported_arch() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"
  portable_sed 's/^arch=amd64$/arch=i386/' "$gate_root/debian.env"

  run_vm_gate "$gate_root"
  assert_status 1
}

# ---- 测试：无效日期格式被拒绝 ----
test_rejects_invalid_date_format() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"
  # 缺少时区 Z 后缀
  portable_sed 's/^date_utc=.*$/date_utc=2026-07-15T10:00:00/' "$gate_root/debian.env"

  run_vm_gate "$gate_root"
  assert_status 1
}

# ---- 测试：占位日期被拒绝 ----
test_rejects_placeholder_date() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"
  portable_sed 's/^date_utc=.*$/date_utc=PENDING/' "$gate_root/debian.env"

  run_vm_gate "$gate_root"
  assert_status 1
}

# ---- 测试：缺少必填字段被拒绝 ----
test_rejects_missing_required_field() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"
  # 删除 systemd 字段
  grep -v '^systemd=' "$gate_root/debian.env" >"$gate_root/debian.tmp"
  mv "$gate_root/debian.tmp" "$gate_root/debian.env"

  run_vm_gate "$gate_root"
  assert_status 1
}

# ---- 测试：符号链接文件被拒绝 ----
test_rejects_symlink_env_file() {
  setup_test_root
  trap teardown_test_root RETURN
  local gate_root="$TEST_ROOT/vm"
  setup_valid_gate "$gate_root"
  # 将 debian.env 替换为符号链接
  mv "$gate_root/debian.env" "$gate_root/debian.real"
  ln -s "$gate_root/debian.real" "$gate_root/debian.env"

  run_vm_gate "$gate_root"
  assert_status 1
}

test_valid_gate_passes
test_rejects_unsupported_debian_version
test_rejects_unsupported_ubuntu_version
test_rejects_unsupported_arch
test_rejects_invalid_date_format
test_rejects_placeholder_date
test_rejects_missing_required_field
test_rejects_symlink_env_file

printf 'vm_gate_test: ok\n'
