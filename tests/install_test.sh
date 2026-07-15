#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_installer_dry_run_only_shows_plan() {
  setup_test_root
  trap teardown_test_root RETURN

  set +e
  COMMAND_OUTPUT="$("$PROJECT_ROOT/install.sh" --dry-run 2>&1)"
  COMMAND_STATUS=$?
  set -e

  assert_status 0
  assert_output_contains "安装目录：/usr/local/lib/vps-guard"
  assert_output_contains "命令入口：/usr/local/sbin/vps-guard"
  assert_output_contains "dry-run：未写入任何文件"
}

test_installer_dry_run_only_shows_plan
