#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_wizard_test() {
  setup_test_root
  umask 077
  mkdir -p "$TEST_ROOT/fs/etc/ssh/sshd_config.d" "$TEST_ROOT/fs/etc/nftables.d" \
    "$TEST_ROOT/fs/etc/vps-guard" "$TEST_ROOT/fs/etc/fail2ban/jail.d"
  printf 'Include /etc/ssh/sshd_config.d/*.conf\nPort 22\n' >"$TEST_ROOT/fs/etc/ssh/sshd_config"
  printf '#!/usr/sbin/nft -f\ninclude "/etc/nftables.d/vps-guard.nft" # vps-guard\n' >"$TEST_ROOT/fs/etc/nftables.conf"
  printf 'table inet vps_guard { }\n' >"$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  printf '%s\n' 'format=2' 'enabled=1' 'ssh_ports=22' 'tcp_ports=' 'udp_ports=' >"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  printf '%s\n' \
    '/etc/ssh/sshd_config' \
    '/etc/ssh/sshd_config.d' \
    '/etc/vps-guard/ssh.conf' \
    '/etc/nftables.conf' \
    '/etc/nftables.d/vps-guard.nft' \
    '/etc/vps-guard/firewall.conf' \
    '/etc/fail2ban/jail.d/vps-guard.local' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub sshd "
if [[ \"\${1:-}\" == '-t' ]]; then exit 0; fi
if [[ \"\${1:-}\" == '-T' ]]; then
  managed='$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf'
  if [[ -r \"\$managed\" ]]; then
    awk 'tolower(\$1) == \"port\" { print \"port \" \$2 }' \"\$managed\"
  else
    awk 'tolower(\$1) == \"port\" { print \"port \" \$2 }' '$TEST_ROOT/fs/etc/ssh/sshd_config'
  fi
  exit 0
fi
exit 1
"
  write_stub ss "
managed='$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf'
prefix=tcp
if [[ \"\$*\" == *'-ltn'* && \"\$*\" != *'-lntup'* ]]; then prefix=''; fi
if [[ -r \"\$managed\" ]]; then
  awk -v prefix=\"\$prefix\" 'tolower(\$1) == \"port\" { printf \"%s%sLISTEN 0 128 0.0.0.0:%s 0.0.0.0:* users:((sshd,pid=1,fd=3))\\n\", prefix, (prefix == \"\" ? \"\" : \" \"), \$2 }' \"\$managed\"
else
  printf '%s%sLISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((sshd,pid=1,fd=3))\\n' \"\$prefix\" \"\${prefix:+ }\"
fi
if [[ \"\$prefix\" == '' ]]; then exit 0; fi
printf '%s\\n' \
  'tcp LISTEN 0 128 0.0.0.0:80 0.0.0.0:* users:((nginx,pid=2,fd=3))' \
  'tcp LISTEN 0 128 127.0.0.1:9000 0.0.0.0:* users:((local,pid=3,fd=3))' \
  'udp UNCONN 0 0 [::]:53 [::]:* users:((named,pid=4,fd=4))'
"
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then exit 0; fi
if [[ \"\$1 \${2:-}\" == 'list ruleset' || \"\$1 \${2:-}\" == '-c -f' ]]; then exit 0; fi
if [[ \"\${1:-}\" == '-f' && -e '$TEST_ROOT/fail-nft-live' ]]; then exit 1; fi
exit 0
"
  write_stub systemd-run "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemd-run.log'; exit 0"
  write_stub systemctl "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemctl.log'
if [[ \"\$*\" == 'is-active --quiet ssh.socket' || \"\$*\" == 'is-enabled --quiet ssh.socket' ]]; then exit 1; fi
if [[ \"\$*\" == 'restart fail2ban' && -e '$TEST_ROOT/fail-f2b-once' ]]; then
  rm -f '$TEST_ROOT/fail-f2b-once'
  exit 1
fi
if [[ \"\$1\" == 'stop' && -e '$TEST_ROOT/break-wizard-state-on-stop' ]]; then
  chmod 0400 '$TEST_ROOT/data/wizards/'*/state
fi
if [[ \"\$1\" == 'stop' && -e '$TEST_ROOT/fail-first-stop-then-break-state' ]]; then
  count=0
  [[ ! -r '$TEST_ROOT/stop-count' ]] || count=\$(cat '$TEST_ROOT/stop-count')
  count=\$((count + 1))
  printf '%s\\n' \"\$count\" >'$TEST_ROOT/stop-count'
  if [[ \"\$count\" -eq 1 ]]; then exit 1; fi
  chmod 0400 '$TEST_ROOT/data/wizards/'*/state
fi
exit 0
"
  write_stub fail2ban-client "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/fail2ban-client.log'
if [[ \"\${1:-}\" == '-t' && -e '$TEST_ROOT/fail-f2b-validate' ]]; then exit 1; fi
exit 0
"
  TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 22"
}

extract_wizard_token() {
  local token
  token="${COMMAND_OUTPUT#*快速安全配置等待确认：}"
  printf '%s\n' "${token%%$'\n'*}"
}

test_standard_plan_uses_one_snapshot_and_commits_from_new_port() {
  local token rollback
  setup_wizard_test
  trap teardown_test_root RETURN

  run_vps_guard wizard apply --plan standard --ssh-port 2222 --tcp 80,443 --udp 53 --yes

  assert_status 0
  assert_output_contains "统一差异与风险摘要"
  assert_output_contains "SSH：22 -> 2222（过渡期：22,2222）"
  assert_output_contains "防火墙：入站默认拒绝；TCP 80,443；UDP 53"
  assert_output_contains "Fail2ban：standard；SSH 端口 22,2222"
  assert_output_contains "云控制台、串行控制台或救援模式"
  [[ "$(find "$TEST_ROOT/data/backups" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')" -eq 1 ]]
  [[ "$(wc -l <"$TEST_ROOT/systemd-run.log" | tr -d ' ')" -eq 1 ]]
  token="$(extract_wizard_token)"
  rollback="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/wizards/$token/state")"
  grep -q '^hook=wizard-standard$' "$TEST_ROOT/data/rollbacks/$rollback/state"
  grep -q '^ssh_ports=22,2222$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^port = 22,2222$' "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  grep -q '^ignoreip = 127.0.0.1/8 ::1 198.51.100.10$' "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"

  run_vps_guard rollback confirm "$rollback"
  assert_status 3
  assert_output_contains "只能通过 wizard confirm"

  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"
  run_vps_guard wizard confirm "$token"
  assert_status 0
  assert_output_contains "快速安全配置已提交"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf")" == "Port 2222" ]]
  grep -q '^ssh_ports=2222$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^port = 2222$' "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local"
  grep -q '^status=confirmed$' "$TEST_ROOT/data/rollbacks/$rollback/state"
  [[ "$(wc -l <"$TEST_ROOT/systemd-run.log" | tr -d ' ')" -eq 1 ]]
}

test_firewall_only_and_fail2ban_only_touch_only_selected_component() {
  setup_wizard_test
  run_vps_guard wizard apply --plan firewall --tcp 80 --udp 53 --yes
  assert_status 0
  assert_output_contains "Fail2ban：保持不变"
  [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  assert_output_contains "未迁移 SSH 端口，因此未创建自动回滚"
  [[ ! -d "$TEST_ROOT/data/wizards" ]]
  [[ ! -e "$TEST_ROOT/systemd-run.log" ]]
  teardown_test_root

  setup_wizard_test
  trap teardown_test_root RETURN
  run_vps_guard wizard apply --plan fail2ban --yes
  assert_status 0
  assert_output_contains "防火墙：保持不变"
  [[ -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  [[ ! -e "$TEST_ROOT/nft.log" || ! -s "$TEST_ROOT/nft.log" ]]
}

test_prepare_failure_and_final_cancel_are_zero_write() {
  local before
  setup_wizard_test
  trap teardown_test_root RETURN
  before="$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")"
  touch "$TEST_ROOT/fail-f2b-validate"

  run_vps_guard wizard apply --plan standard --ssh-port 2222 --tcp 80 --udp 53 --yes
  assert_status 1
  assert_output_contains "候选配置校验失败"
  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == "$before" ]]

  rm -f "$TEST_ROOT/fail-f2b-validate"
  run_vps_guard_with_input $'n\n' wizard apply --plan standard --ssh-port 2222 --tcp 80 --udp 53
  assert_status 0
  assert_output_contains "已取消，未修改任何配置"
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_partial_failure_restores_all_components_and_cancels_timer() {
  local token rollback
  setup_wizard_test
  trap teardown_test_root RETURN
  touch "$TEST_ROOT/fail-f2b-once"

  run_vps_guard wizard apply --plan standard --ssh-port 2222 --tcp 80 --udp 53 --yes

  assert_status 1
  assert_output_contains "已恢复向导开始前的完整配置"
  assert_output_contains "部分应用失败"
  [[ "$(<"$TEST_ROOT/fs/etc/ssh/sshd_config")" == $'Include /etc/ssh/sshd_config.d/*.conf\nPort 22' ]]
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]
  token="$(find "$TEST_ROOT/data/wizards" -mindepth 1 -maxdepth 1 -type d -exec basename {} \;)"
  rollback="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/wizards/$token/state")"
  grep -q '^status=confirmed$' "$TEST_ROOT/data/rollbacks/$rollback/state"
  grep -q '^restart fail2ban$' "$TEST_ROOT/systemctl.log"
}

test_timeout_rollback_restores_start_and_status_derives_rolled_back() {
  local token rollback
  setup_wizard_test
  trap teardown_test_root RETURN

  run_vps_guard wizard apply --plan standard --ssh-port 2222 --tcp 80 --udp 53 --yes
  assert_status 0
  token="$(extract_wizard_token)"
  rollback="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/wizards/$token/state")"

  run_vps_guard rollback run "$rollback"
  assert_status 0
  assert_output_contains "自动回滚完成"
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  [[ ! -e "$TEST_ROOT/fs/etc/fail2ban/jail.d/vps-guard.local" ]]

  run_vps_guard wizard status "$token"
  assert_status 0
  assert_output_contains "状态：rolled-back"
  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"
  run_vps_guard wizard confirm "$token"
  assert_status 3
  assert_output_contains "已不是等待确认状态"
}

test_menu_keeps_draft_across_submenu_and_prefills_detected_ports() {
  setup_wizard_test
  trap teardown_test_root RETURN

  run_vps_guard_with_input $'2\n1\n2222\n80,443\n53\n2\n0\n4\nn\n0\n0\n'

  assert_status 0
  assert_output_contains "1. 标准防护（推荐）"
  assert_output_contains "检测到监听 TCP：80"
  assert_output_contains "检测到监听 UDP：53"
  assert_output_not_contains "检测到监听 TCP：22"
  assert_output_contains "防火墙管理"
  assert_output_contains "4. 继续应用（默认）"
  assert_output_contains "SSH：22 -> 2222"
  assert_output_contains "防火墙：入站默认拒绝；TCP 80,443；UDP 53"
  assert_output_contains "已取消，未修改任何配置"
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_timeout_runtime_failure_is_retryable() {
  local token rollback
  setup_wizard_test
  trap teardown_test_root RETURN

  run_vps_guard wizard apply --plan standard --ssh-port 2222 --tcp 80 --udp 53 --yes
  assert_status 0
  token="$(extract_wizard_token)"
  rollback="$(sed -n 's/^rollback=//p' "$TEST_ROOT/data/wizards/$token/state")"
  # 在应用完成后破坏恢复钩子的配置校验；这样不会影响候选配置预检，
  # 但能确定首次超时回滚进入 failed，随后由 systemd 的重试语义恢复。
  touch "$TEST_ROOT/fail-f2b-validate"

  run_vps_guard rollback run "$rollback"
  assert_status 1
  grep -q '^status=failed$' "$TEST_ROOT/data/rollbacks/$rollback/state"

  rm -f "$TEST_ROOT/fail-f2b-validate"
  run_vps_guard rollback run "$rollback"
  assert_status 0
  assert_output_contains "自动回滚完成"
  grep -q '^retry=' "$TEST_ROOT/data/rollbacks/$rollback/state"
  grep -q '^status=rolled-back$' "$TEST_ROOT/data/rollbacks/$rollback/state"
}

test_confirm_state_tail_is_recoverable_and_corruption_is_rejected() {
  local token rollback state
  setup_wizard_test
  trap teardown_test_root RETURN

  run_vps_guard wizard apply --plan standard --ssh-port 2222 --tcp 80 --udp 53 --yes
  assert_status 0
  token="$(extract_wizard_token)"
  state="$TEST_ROOT/data/wizards/$token/state"
  rollback="$(sed -n 's/^rollback=//p' "$state")"
  touch "$TEST_ROOT/break-wizard-state-on-stop"

  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"
  run_vps_guard wizard confirm "$token"
  assert_status 1
  assert_output_contains "状态收尾失败"
  grep -q '^status=confirmed$' "$TEST_ROOT/data/rollbacks/$rollback/state"
  [[ "$(sed -n 's/^status=//p' "$state" | tail -1)" == committing ]]

  rm -f "$TEST_ROOT/break-wizard-state-on-stop"
  chmod 0600 "$state"
  run_vps_guard wizard confirm "$token"
  assert_status 0
  assert_output_contains "状态收尾已完成"
  [[ "$(sed -n 's/^status=//p' "$state" | tail -1)" == committed ]]

  printf 'plan=standard\n' >>"$state"
  run_vps_guard wizard status "$token"
  assert_status 3
  assert_output_contains "字段缺失或重复：plan"
}

test_confirm_recovery_state_cannot_be_misreported_as_committed() {
  local token rollback state
  setup_wizard_test
  trap teardown_test_root RETURN

  run_vps_guard wizard apply --plan standard --ssh-port 2222 --tcp 80 --udp 53 --yes
  assert_status 0
  token="$(extract_wizard_token)"
  state="$TEST_ROOT/data/wizards/$token/state"
  rollback="$(sed -n 's/^rollback=//p' "$state")"
  touch "$TEST_ROOT/fail-first-stop-then-break-state"
  TEST_SSH_CONNECTION="198.51.100.10 50001 203.0.113.20 2222"

  run_vps_guard wizard confirm "$token"
  assert_status 1
  [[ "$(sed -n 's/^status=//p' "$state" | tail -1)" == recovering ]]
  grep -q '^status=confirmed$' "$TEST_ROOT/data/rollbacks/$rollback/state"
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
  grep -q '^ssh_ports=22$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"

  rm -f "$TEST_ROOT/fail-first-stop-then-break-state"
  chmod 0600 "$state"
  run_vps_guard wizard confirm "$token"
  assert_status 1
  assert_output_contains "目标配置未提交"
  [[ "$(sed -n 's/^status=//p' "$state" | tail -1)" == failed ]]
  if grep -q '^status=committed$' "$state"; then return 1; fi
  [[ ! -e "$TEST_ROOT/fs/etc/ssh/sshd_config.d/00-vps-guard-port.conf" ]]
}

test_standard_plan_uses_one_snapshot_and_commits_from_new_port
test_firewall_only_and_fail2ban_only_touch_only_selected_component
test_prepare_failure_and_final_cancel_are_zero_write
test_partial_failure_restores_all_components_and_cancels_timer
test_timeout_rollback_restores_start_and_status_derives_rolled_back
test_menu_keeps_draft_across_submenu_and_prefills_detected_ports
test_timeout_runtime_failure_is_retryable
test_confirm_state_tail_is_recoverable_and_corruption_is_rejected
test_confirm_recovery_state_cannot_be_misreported_as_committed

printf 'wizard_test: ok\n'
