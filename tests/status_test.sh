#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_status_reports_supported_debian() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "x86_64\n"'

  run_vps_guard status

  assert_status 0
  assert_output_contains "Debian GNU/Linux 13 (trixie)"
  assert_output_contains "版本：13"
  assert_output_contains "架构：amd64"
  assert_output_contains "运行权限：root"
  assert_output_contains "支持状态：正式支持"
}

test_status_only_proposes_missing_dependencies() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=ubuntu' \
    'VERSION_ID="24.04"' \
    'PRETTY_NAME="Ubuntu 24.04 LTS"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "aarch64\n"'
  write_stub systemctl 'exit 0'
  write_stub systemd-run 'exit 0'
  write_stub ss 'exit 0'
  write_stub runuser 'exit 0'

  run_vps_guard status

  assert_status 0
  assert_output_contains "依赖 nft：缺失"
  assert_output_contains "建议安装：sudo apt-get install nftables openssh-server diffutils fail2ban"
}

test_status_reports_ssh_and_listening_ports() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'PRETTY_NAME="Debian 13"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "x86_64\n"'
  # shellcheck disable=SC2016
  write_stub systemctl '[[ "$1" == "is-active" ]] && exit 0; exit 1'
  write_stub ss 'printf "%s\n" "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((sshd,pid=1,fd=3))"'

  run_vps_guard status

  assert_status 0
  assert_output_contains "SSH 服务：运行中"
  assert_output_contains "监听：tcp 0.0.0.0:22"
}

test_dry_run_status_is_read_only_and_explicit() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=ubuntu' \
    'VERSION_ID="26.04"' \
    'PRETTY_NAME="Ubuntu 26.04 LTS"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "aarch64\n"'

  run_vps_guard --dry-run status

  assert_status 0
  assert_output_contains "模式：dry-run（只读，不会修改系统）"
  assert_output_contains "Ubuntu 26.04 LTS"
}

test_non_root_user_gets_sudo_guidance() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'PRETTY_NAME="Debian 13"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "1000\n"'
  write_stub uname 'printf "x86_64\n"'

  run_vps_guard status

  assert_status 4
  assert_output_contains "需要 root 权限"
  assert_output_contains "sudo vps-guard"
}

test_missing_system_metadata_returns_failure() {
  setup_test_root
  trap teardown_test_root RETURN
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "x86_64\n"'

  run_vps_guard status

  assert_status 1
  assert_output_contains "无法读取系统信息"
}

test_unsupported_system_returns_stable_exit_code() {
  setup_test_root
  trap teardown_test_root RETURN

  printf '%s\n' \
    'ID=ubuntu' \
    'VERSION_ID="20.04"' \
    'PRETTY_NAME="Ubuntu 20.04 LTS"' >"$TEST_ROOT/os-release"
  write_stub id 'printf "0\n"'
  write_stub uname 'printf "x86_64\n"'

  run_vps_guard status

  assert_status 5
  assert_output_contains "支持状态：未经验证"
}

test_status_reports_supported_debian
test_status_only_proposes_missing_dependencies
test_status_reports_ssh_and_listening_ports
test_dry_run_status_is_read_only_and_explicit
test_non_root_user_gets_sudo_guidance
test_missing_system_metadata_returns_failure
test_unsupported_system_returns_stable_exit_code
