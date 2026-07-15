#!/usr/bin/env bash

set -u

TEST_ROOT=""
COMMAND_OUTPUT=""
COMMAND_STATUS=0

setup_test_root() {
  TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vps-guard-test.XXXXXX")"
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/fs" "$TEST_ROOT/data" "$TEST_ROOT/log"
}

teardown_test_root() {
  if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
    rm -rf "$TEST_ROOT"
  fi
}

write_stub() {
  local name="$1"
  local body="$2"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "$body"
  } >"$TEST_ROOT/bin/$name"
  chmod +x "$TEST_ROOT/bin/$name"
}

run_vps_guard() {
  set +e
  COMMAND_OUTPUT="$(PATH="$TEST_ROOT/bin:$PATH" \
    VPS_GUARD_OS_RELEASE="$TEST_ROOT/os-release" \
    VPS_GUARD_COMMAND_PATH="$TEST_ROOT/bin" \
    VPS_GUARD_FS_ROOT="$TEST_ROOT/fs" \
    VPS_GUARD_DATA_DIR="$TEST_ROOT/data" \
    VPS_GUARD_AUDIT_LOG="$TEST_ROOT/log/audit.log" \
    VPS_GUARD_MANAGED_PATHS_FILE="$TEST_ROOT/managed-paths" \
    SUDO_USER="${TEST_SUDO_USER:-}" \
    "$PROJECT_ROOT/vps-guard.sh" "$@" 2>&1)"
  COMMAND_STATUS=$?
  set -e
}

run_vps_guard_with_input() {
  local input="$1"
  shift
  set +e
  COMMAND_OUTPUT="$(printf '%s' "$input" | PATH="$TEST_ROOT/bin:$PATH" \
    VPS_GUARD_OS_RELEASE="$TEST_ROOT/os-release" \
    VPS_GUARD_COMMAND_PATH="$TEST_ROOT/bin" \
    VPS_GUARD_FS_ROOT="$TEST_ROOT/fs" \
    VPS_GUARD_DATA_DIR="$TEST_ROOT/data" \
    VPS_GUARD_AUDIT_LOG="$TEST_ROOT/log/audit.log" \
    VPS_GUARD_MANAGED_PATHS_FILE="$TEST_ROOT/managed-paths" \
    SUDO_USER="${TEST_SUDO_USER:-}" \
    "$PROJECT_ROOT/vps-guard.sh" "$@" 2>&1)"
  COMMAND_STATUS=$?
  set -e
}

assert_status() {
  local expected="$1"
  if [[ "$COMMAND_STATUS" -ne "$expected" ]]; then
    printf '期望退出码 %s，实际为 %s\n输出：\n%s\n' "$expected" "$COMMAND_STATUS" "$COMMAND_OUTPUT" >&2
    return 1
  fi
}

assert_output_contains() {
  local expected="$1"
  if [[ "$COMMAND_OUTPUT" != *"$expected"* ]]; then
    printf '输出中未找到：%s\n实际输出：\n%s\n' "$expected" "$COMMAND_OUTPUT" >&2
    return 1
  fi
}

assert_output_not_contains() {
  local unexpected="$1"
  if [[ "$COMMAND_OUTPUT" == *"$unexpected"* ]]; then
    printf '输出中包含不应出现的内容：%s\n实际输出：\n%s\n' "$unexpected" "$COMMAND_OUTPUT" >&2
    return 1
  fi
}
