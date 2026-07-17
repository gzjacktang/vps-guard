#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

run_installer() {
  local prefix="$1"
  shift
  set +e
  COMMAND_OUTPUT="$(VPS_GUARD_INSTALL_PREFIX="$prefix" "$PROJECT_ROOT/install.sh" "$@" 2>&1)"
  COMMAND_STATUS=$?
  set -e
}

downgrade_installed_fixture_to_0_9_0() {
  local root="$1"
  mv "$root/releases/1.0.0" "$root/releases/0.9.0"
  printf '0.9.0\n' >"$root/releases/0.9.0/VERSION"
  printf '%s\n' 'signature=vps-guard-managed-install-v1' 'version=0.9.0' >"$root/releases/0.9.0/INSTALL-MANIFEST"
  printf 'old-program\n' >"$root/releases/0.9.0/old-marker"
  rm -f "$root/current"
  ln -s releases/0.9.0 "$root/current"
}

test_installer_dry_run_only_shows_complete_plan() {
  setup_test_root
  trap teardown_test_root RETURN
  local prefix="$TEST_ROOT/prefix"

  run_installer "$prefix" --dry-run

  assert_status 0
  assert_output_contains "源码版本：1.0.0"
  assert_output_contains "版本目录：$prefix/lib/vps-guard/releases/1.0.0"
  assert_output_contains "稳定入口：$prefix/sbin/vps-guard"
  assert_output_contains "文件权限：版本目录 0755"
  assert_output_contains "依赖 bash"
  assert_output_contains "不联网、不下载、不执行远程内容"
  assert_output_contains "dry-run：未写入任何文件"
  [[ ! -e "$prefix" ]]
}

test_install_creates_working_launcher_and_versioned_release() {
  setup_test_root
  trap teardown_test_root RETURN
  local prefix="$TEST_ROOT/prefix"

  run_installer "$prefix" --yes

  assert_status 0
  [[ -x "$prefix/sbin/vps-guard" && ! -L "$prefix/sbin/vps-guard" ]]
  [[ "$(readlink "$prefix/lib/vps-guard/current")" == releases/1.0.0 ]]
  [[ -x "$prefix/lib/vps-guard/releases/1.0.0/vps-guard.sh" ]]
  [[ "$(stat -f '%Lp' "$prefix/lib/vps-guard/releases/1.0.0/lib/core.sh" 2>/dev/null || stat -c '%a' "$prefix/lib/vps-guard/releases/1.0.0/lib/core.sh")" == 644 ]]
  COMMAND_OUTPUT="$("$prefix/sbin/vps-guard" version 2>&1)"
  COMMAND_STATUS=$?
  assert_status 0
  assert_output_contains "VPS Guard 1.0.0"
  COMMAND_OUTPUT="$("$prefix/sbin/vps-guard" help 2>&1)"
  COMMAND_STATUS=$?
  assert_status 0
  assert_output_contains "update"
}

test_update_backs_up_active_program_and_keeps_old_release() {
  setup_test_root
  trap teardown_test_root RETURN
  local prefix="$TEST_ROOT/prefix" root backup

  run_installer "$prefix" --yes
  assert_status 0
  root="$prefix/lib/vps-guard"
  downgrade_installed_fixture_to_0_9_0 "$root"

  run_installer "$prefix" --update --yes

  assert_status 0
  assert_output_contains "现有程序已备份"
  [[ "$(readlink "$root/current")" == releases/1.0.0 ]]
  [[ -d "$root/releases/0.9.0" && -d "$root/releases/1.0.0" ]]
  backup="$(find "$root/program-backups" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -r "$backup/old-marker" ]]
  [[ "$(<"$backup/old-marker")" == old-program ]]
  COMMAND_OUTPUT="$("$prefix/sbin/vps-guard" version 2>&1)"
  assert_output_contains "VPS Guard 1.0.0"
}

test_update_rejects_corrupted_active_version_metadata() {
  setup_test_root
  trap teardown_test_root RETURN
  local prefix="$TEST_ROOT/prefix" root

  run_installer "$prefix" --yes
  assert_status 0
  root="$prefix/lib/vps-guard"
  printf '../outside\n' >"$root/releases/1.0.0/VERSION"

  run_installer "$prefix" --update --yes

  assert_status 3
  assert_output_contains "布局或 launcher 归属不可信"
  [[ "$(readlink "$root/current")" == releases/1.0.0 ]]
  [[ ! -d "$root/program-backups" ]]
}

test_update_is_blocked_by_pending_rollback_transaction() {
  setup_test_root
  trap teardown_test_root RETURN
  local prefix="$TEST_ROOT/prefix" root

  run_installer "$prefix" --yes
  assert_status 0
  root="$prefix/lib/vps-guard"
  downgrade_installed_fixture_to_0_9_0 "$root"
  mkdir -p "$prefix/var/lib/vps-guard/rollbacks/rb-pending"
  printf 'status=pending\n' >"$prefix/var/lib/vps-guard/rollbacks/rb-pending/state"

  run_installer "$prefix" --update --yes

  assert_status 3
  assert_output_contains "未完成或状态异常"
  [[ "$(readlink "$root/current")" == releases/0.9.0 ]]
  [[ ! -d "$root/releases/1.0.0" && ! -d "$root/program-backups" ]]
}

test_first_install_launcher_failure_removes_partial_program() {
  setup_test_root
  trap teardown_test_root RETURN
  local prefix="$TEST_ROOT/prefix" command_link="$TEST_ROOT/prefix/sbin/vps-guard"
  write_stub mv "last=\"\${!#}\"; if [[ \"\$last\" == '$command_link' ]]; then exit 1; fi; exec /bin/mv \"\$@\""

  PATH="$TEST_ROOT/bin:$PATH" run_installer "$prefix" --yes

  assert_status 1
  assert_output_contains "正在撤销首次安装"
  [[ ! -e "$command_link" && ! -L "$command_link" ]]
  [[ ! -e "$prefix/lib/vps-guard/current" && ! -L "$prefix/lib/vps-guard/current" ]]
  [[ ! -e "$prefix/lib/vps-guard/releases/1.0.0" ]]
}

test_installer_dry_run_only_shows_complete_plan
test_install_creates_working_launcher_and_versioned_release
test_update_backs_up_active_program_and_keeps_old_release
test_update_rejects_corrupted_active_version_metadata
test_update_is_blocked_by_pending_rollback_transaction
test_first_install_launcher_failure_removes_partial_program

printf 'install_test: ok\n'
