#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_fail2ban_test() {
  setup_test_root
  umask 077
  mkdir -p "$TEST_ROOT/fs/etc/fail2ban/jail.d" "$TEST_ROOT/fs/etc/ssh/sshd_config.d"
  printf '%s\n' '/etc/fail2ban/jail.d/vps-guard.local' >"$TEST_ROOT/managed-paths"
  write_stub id 'case "$*" in -u) printf "0\n" ;; -un) printf "root\n" ;; esac'
  # shellcheck disable=SC2016
  write_stub sshd '[[ "${1:-}" == -t ]] && exit 0; [[ "${1:-}" == -T ]] && { printf "port 22\n"; exit 0; }; exit 1'
  write_stub systemd-run "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemd-run.log'"
  write_stub systemctl "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemctl.log'; if [[ \"\$*\" == 'restart fail2ban' && -e '$TEST_ROOT/fail-restart' ]]; then exit 1; fi; exit 0"
  write_stub fail2ban-client "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/fail2ban-client.log'
if [[ \"\${1:-}\" == '-t' && -e '$TEST_ROOT/fail-validate' ]]; then exit 1; fi
if [[ \"\$*\" == '-t' && -e '$TEST_ROOT/fail-live-validate' ]]; then exit 1; fi
if [[ \"\$*\" == 'get sshd banip' ]]; then printf '198.51.100.8 2001:db8::8\\n'; exit 0; fi
if [[ \"\$*\" == 'status' ]]; then printf 'Jail list: sshd\\n'; exit 0; fi
if [[ \"\$*\" == 'status sshd' ]]; then printf 'Currently banned: 2\\n'; exit 0; fi
exit 0
"
  TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 22"
}

test_presets_and_standard_values_are_rendered_without_permanent_bans() {
  local preset
  for preset in lenient standard strict progressive; do
    setup_fail2ban_test
    run_vps_guard_with_input $'n\n' --dry-run fail2ban apply --preset "$preset" --no-whitelist-current-ip --yes
    assert_status 0
    assert_output_contains "预设：$preset"
    assert_output_contains "后端：systemd"
    assert_output_contains "动作：nftables[type=multiport]"
    assert_output_not_contains "bantime：-1"
    [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
    teardown_test_root
  done

  setup_fail2ban_test
  trap teardown_test_root RETURN
  run_vps_guard --dry-run fail2ban apply --preset standard --no-whitelist-current-ip --yes
  assert_output_contains "findtime：600 秒"
  assert_output_contains "maxretry：5"
  assert_output_contains "bantime：3600 秒"
}

test_install_is_separate_and_failure_never_writes_configuration() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  rm -f "$TEST_ROOT/bin/fail2ban-client"
  write_stub apt-get 'exit 1'

  run_vps_guard fail2ban apply --preset standard --no-whitelist-current-ip --yes
  assert_status 3
  assert_output_contains "请先单独执行"
  [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]

  run_vps_guard fail2ban install --yes
  assert_status 1
  assert_output_contains "安装失败"
  [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
}

test_apply_whitelists_current_ip_only_after_confirmation_and_uses_nftables() {
  setup_fail2ban_test
  trap teardown_test_root RETURN

  run_vps_guard_with_input $'y\n' fail2ban apply --preset standard --yes

  assert_status 0
  assert_output_contains "检测到当前管理 IP：198.51.100.10"
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  grep -q '^backend = systemd$' "$config"
  grep -q '^banaction = nftables\[type=multiport\]$' "$config"
  grep -q '^findtime = 600$' "$config"
  grep -q '^maxretry = 5$' "$config"
  grep -q '^bantime = 3600$' "$config"
  grep -q 'ignoreip = 127.0.0.1/8 ::1 198.51.100.10' "$config"
  grep -q -- '--on-active=5m' "$TEST_ROOT/systemd-run.log"
}

test_whitelist_can_be_declined_and_progressive_preset_is_exact() {
  setup_fail2ban_test
  trap teardown_test_root RETURN

  run_vps_guard_with_input $'n\n' fail2ban apply --preset progressive --yes

  assert_status 0
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  grep -q '^bantime.increment = true$' "$config"
  grep -q '^bantime.factor = 1$' "$config"
  grep -q '^bantime.maxtime = 604800$' "$config"
  grep -q '^ignoreip = 127.0.0.1/8 ::1$' "$config"
  ! grep -q '198.51.100.10' "$config"
}

test_existing_configuration_shows_real_unified_diff() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled = true\nmaxretry = 10\n' >"$config"

  run_vps_guard --dry-run fail2ban apply --preset custom --findtime 900 --maxretry 4 --bantime 7200 \
    --increment true --max-bantime 604800 --no-whitelist-current-ip --yes

  assert_status 0
  assert_output_contains "配置文件统一差异"
  assert_output_contains "-maxretry = 10"
  assert_output_contains "+maxretry = 4"
  assert_output_contains "+findtime = 900"
  assert_output_contains "+bantime = 7200"
}

test_custom_boundaries_are_rejected_before_writes() {
  setup_fail2ban_test
  trap teardown_test_root RETURN

  run_vps_guard --dry-run fail2ban apply --preset custom --findtime 59 --maxretry 0 --bantime -1 --no-whitelist-current-ip

  assert_status 2
  assert_output_contains "findtime"
  assert_output_contains "maxretry"
  assert_output_contains "不允许永久封禁"
  [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
}

test_candidate_or_live_validation_failure_restores_original_config() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled = false\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  : >"$TEST_ROOT/fail-validate"

  run_vps_guard --dry-run fail2ban apply --preset standard --no-whitelist-current-ip --yes
  assert_status 1
  assert_output_contains "候选配置检查失败"
  grep -q '^enabled = false$' "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
}

test_status_bans_and_ipv4_ipv6_unban_are_supported() {
  setup_fail2ban_test
  trap teardown_test_root RETURN

  run_vps_guard fail2ban status
  assert_status 0
  assert_output_contains "Jail list: sshd"
  run_vps_guard fail2ban banned
  assert_output_contains "198.51.100.8"
  assert_output_contains "2001:db8::8"
  run_vps_guard fail2ban unban 2001:db8::8
  assert_status 0
  assert_output_contains "已从 sshd jail 解封"
  grep -q 'set sshd unbanip 2001:db8::8' "$TEST_ROOT/fail2ban-client.log"
  run_vps_guard fail2ban unban 192.0.2.99
  assert_status 0
  assert_output_contains "当前未被"
}

test_disable_removes_only_vps_guard_file() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled=true\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  printf '[other]\nenabled=true\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/third-party.local"

  run_vps_guard fail2ban disable --yes

  assert_status 0
  [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
  [[ -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/third-party.local" ]]
}

test_restore_is_selective_and_cli_missing_values_are_rejected() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled = true\nmaxretry = 5\n' >"$config"
  printf '[other]\nenabled = true\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/third-party.local"

  run_vps_guard backup create --label fail2ban-known-good
  assert_status 0
  snapshot="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nenabled = true\nmaxretry = 2\n' >"$config"
  printf '[other]\nenabled = false\n' >"$TEST_ROOT/fs/etc/fail2ban/jail.d/third-party.local"

  run_vps_guard fail2ban restore "$snapshot" --yes
  assert_status 0
  grep -q '^maxretry = 5$' "$config"
  grep -q '^enabled = false$' "$TEST_ROOT/fs/etc/fail2ban/jail.d/third-party.local"

  run_vps_guard fail2ban apply --preset
  assert_status 2
  run_vps_guard fail2ban install unexpected
  assert_status 2
}

test_foreign_same_name_jail_is_never_overwritten_or_deleted() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  printf '# foreign administrator file\n[sshd]\nenabled = true\n' >"$config"

  run_vps_guard fail2ban apply --preset standard --no-whitelist-current-ip --yes
  assert_status 3
  assert_output_contains "并非 VPS Guard 所有"
  grep -q '^# foreign administrator file$' "$config"

  run_vps_guard fail2ban disable --yes
  assert_status 3
  [[ -e "$config" ]]
}

test_malformed_management_session_and_overlapping_timer_are_blocked() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  TEST_SSH_CONNECTION="198.51.100.10"

  run_vps_guard fail2ban apply --preset standard --whitelist-current-ip --yes
  assert_status 3
  assert_output_contains "不能使用 --whitelist-current-ip"

  TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 22"
  run_vps_guard fail2ban apply --preset standard --no-whitelist-current-ip --yes
  assert_status 0
  run_vps_guard fail2ban disable --yes
  assert_status 3
  assert_output_contains "仍有等待确认的"
  [[ -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
}

test_live_failure_keeps_timer_when_immediate_recovery_is_incomplete() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  : >"$TEST_ROOT/fail-restart"

  run_vps_guard fail2ban apply --preset standard --no-whitelist-current-ip --yes

  assert_status 1
  assert_output_contains "自动回滚任务仍保留"
  rollback_dir="$(find "$TEST_ROOT/data/rollbacks" -mindepth 1 -maxdepth 1 -type d | head -1)"
  grep -q '^status=pending$' "$rollback_dir/state"
}

test_restore_rejects_missing_or_tampered_snapshot_file() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nmaxretry = 5\n' >"$config"
  run_vps_guard backup create --label fail2ban-integrity
  snapshot="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  saved="$TEST_ROOT/data/backups/$snapshot/files/etc/fail2ban/jail.d/vps-guard.local"
  printf '\n# tampered\n' >>"$saved"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nmaxretry = 3\n' >"$config"

  run_vps_guard fail2ban restore "$snapshot" --yes

  assert_status 1
  assert_output_contains "校验和不匹配"
  grep -q '^maxretry = 3$' "$config"

  rm -f "$saved"
  run_vps_guard fail2ban restore "$snapshot" --yes
  assert_status 1
  assert_output_contains "文件缺失"
  grep -q '^maxretry = 3$' "$config"
}

test_restore_rejects_file_injected_into_missing_manifest_entry() {
  setup_fail2ban_test
  trap teardown_test_root RETURN
  config="$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  run_vps_guard backup create --label fail2ban-missing
  snapshot="${COMMAND_OUTPUT#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  saved="$TEST_ROOT/data/backups/$snapshot/files/etc/fail2ban/jail.d/vps-guard.local"
  mkdir -p "$(dirname "$saved")"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nmaxretry = 1\n' >"$saved"
  printf '# 由 VPS Guard 管理；请勿在此文件中保存私密信息\n[sshd]\nmaxretry = 5\n' >"$config"

  run_vps_guard fail2ban restore "$snapshot" --yes

  assert_status 1
  assert_output_contains "记录为未启用"
  grep -q '^maxretry = 5$' "$config"
}

test_presets_and_standard_values_are_rendered_without_permanent_bans
test_install_is_separate_and_failure_never_writes_configuration
test_apply_whitelists_current_ip_only_after_confirmation_and_uses_nftables
test_whitelist_can_be_declined_and_progressive_preset_is_exact
test_existing_configuration_shows_real_unified_diff
test_custom_boundaries_are_rejected_before_writes
test_candidate_or_live_validation_failure_restores_original_config
test_status_bans_and_ipv4_ipv6_unban_are_supported
test_disable_removes_only_vps_guard_file
test_restore_is_selective_and_cli_missing_values_are_rejected
test_foreign_same_name_jail_is_never_overwritten_or_deleted
test_malformed_management_session_and_overlapping_timer_are_blocked
test_live_failure_keeps_timer_when_immediate_recovery_is_incomplete
test_restore_rejects_missing_or_tampered_snapshot_file
test_restore_rejects_file_injected_into_missing_manifest_entry

printf 'fail2ban_test: ok\n'
