#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_firewall_test() {
  setup_test_root
  mkdir -p "$TEST_ROOT/fs/etc/nftables.d" "$TEST_ROOT/fs/etc/ssh"
  printf '#!/usr/sbin/nft -f\n' >"$TEST_ROOT/fs/etc/nftables.conf"
  printf '%s\n' \
    '/etc/nftables.conf' \
    '/etc/nftables.d/vps-guard.nft' \
    '/etc/vps-guard/firewall.conf' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub sshd 'printf "port 2222\npasswordauthentication yes\n"'
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$1 \${2:-}\" == 'list ruleset' ]]; then
  exit 0
fi
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  exit 1
fi
if [[ \"\$1 \${2:-}\" == '-c -f' ]]; then
  exit 0
fi
exit 0
"
}

seed_enabled_firewall() {
  mkdir -p "$TEST_ROOT/fs/etc/vps-guard"
  printf '%s\n' \
    'enabled=1' \
    'ssh_ports=2222' \
    'tcp_ports=80' \
    'udp_ports=53' >"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  printf '%s\n' \
    'table inet vps_guard { }' >"$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  printf '%s\n' 'include "/etc/nftables.d/vps-guard.nft" # vps-guard' >>"$TEST_ROOT/fs/etc/nftables.conf"
}

test_firewall_enable_dry_run_shows_checked_dual_stack_baseline_without_writes() {
  setup_firewall_test
  trap teardown_test_root RETURN

  run_vps_guard --dry-run firewall enable \
    --tcp 80,443 --udp 53 --rollback-minutes 5 --yes

  assert_status 0
  assert_output_contains "防火墙规则摘要"
  assert_output_contains "地址族：IPv4 + IPv6（inet 双栈）"
  assert_output_contains "入站策略：默认拒绝"
  assert_output_contains "出站策略：默认允许"
  assert_output_contains "保留 SSH TCP：2222"
  assert_output_contains "开放 TCP：80,443"
  assert_output_contains "开放 UDP：53"
  assert_output_contains "已建立/相关连接、回环、ICMP 与 ICMPv6：允许"
  assert_output_contains "最坏后果：SSH 连接中断，VPS 可能暂时失联"
  assert_output_contains "操作前确认云控制台、串行控制台或救援模式可用"
  assert_output_contains "dry-run：不会写入配置或启动自动回滚"
  grep -q -- '^-c -f ' "$TEST_ROOT/nft.log"
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_firewall_preserves_current_verified_ssh_session_port_and_configured_port() {
  setup_firewall_test
  trap teardown_test_root RETURN
  write_stub sshd 'printf "port 22\n"'
  TEST_SSH_CONNECTION="198.51.100.10 50000 203.0.113.20 2222"

  run_vps_guard --dry-run firewall enable --yes

  assert_status 0
  assert_output_contains "保留 SSH TCP：22,2222"
  TEST_SSH_CONNECTION=""
}

test_firewall_enable_writes_only_managed_scope_and_starts_rollback() {
  local token
  setup_firewall_test
  trap teardown_test_root RETURN
  printf 'table inet third_party { chain input { type filter hook input priority 10; } }\n' >>"$TEST_ROOT/fs/etc/nftables.conf"
  write_stub systemd-run "printf '%s\\n' \"\$*\" >>'$TEST_ROOT/systemd-run.log'"

  run_vps_guard firewall enable --tcp 80,443 --udp 53 --yes

  assert_status 0
  assert_output_contains "防火墙已启用"
  assert_output_contains "自动回滚已启动："
  assert_output_contains "请从新 SSH 会话验证"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  [[ -n "$token" ]]
  grep -q 'table inet third_party' "$TEST_ROOT/fs/etc/nftables.conf"
  [[ "$(grep -Fc 'include "/etc/nftables.d/vps-guard.nft" # vps-guard' "$TEST_ROOT/fs/etc/nftables.conf")" -eq 1 ]]
  grep -q 'table inet vps_guard' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  if grep -q 'destroy table' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"; then
    printf '最低支持版本不兼容 destroy table\n' >&2
    return 1
  fi
  grep -q 'policy drop' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  grep -q 'policy accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  grep -q 'meta l4proto ipv6-icmp accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  grep -q 'tcp dport { 80, 443, 2222 } accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  grep -q 'udp dport { 53 } accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  if grep -Eqi 'chain (forward|nat)' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"; then
    printf '受管配置不应创建 FORWARD 或 NAT 链\n' >&2
    return 1
  fi
  grep -q '^ssh_ports=2222$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^tcp_ports=80,443$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^udp_ports=53$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q -- "-f $TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" "$TEST_ROOT/nft.log"
  if grep -q 'flush ruleset' "$TEST_ROOT/nft.log"; then
    printf '不得清空第三方 ruleset\n' >&2
    return 1
  fi
  if grep 'delete table' "$TEST_ROOT/nft.log" | grep -qv 'delete table inet vps_guard'; then
    printf '不得删除第三方 nftables 表\n' >&2
    return 1
  fi
  [[ -r "$TEST_ROOT/data/rollbacks/$token/state" ]]
  grep -q '^hook=firewall$' "$TEST_ROOT/data/rollbacks/$token/state"
}

test_firewall_syntax_failure_leaves_system_unchanged() {
  local before
  setup_firewall_test
  trap teardown_test_root RETURN
  before="$(<"$TEST_ROOT/fs/etc/nftables.conf")"
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$1 \${2:-}\" == 'list ruleset' ]]; then
  exit 0
fi
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  exit 1
fi
if [[ \"\$1 \${2:-}\" == '-c -f' ]]; then
  exit 1
fi
exit 0
"

  run_vps_guard firewall enable --tcp 80 --yes

  assert_status 1
  assert_output_contains "nftables 语法检查失败，未写入任何配置"
  [[ "$(<"$TEST_ROOT/fs/etc/nftables.conf")" == "$before" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_firewall_timeout_rollback_restores_files_and_runtime_table() {
  local token
  setup_firewall_test
  trap teardown_test_root RETURN
  printf 'table inet third_party { }\n' >>"$TEST_ROOT/fs/etc/nftables.conf"
  write_stub systemd-run 'exit 0'
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$1 \${2:-}\" == 'list ruleset' ]]; then
  exit 0
fi
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  [[ -e '$TEST_ROOT/runtime-active' ]]
  exit \$?
fi
if [[ \"\$1 \${2:-}\" == '-c -f' ]]; then
  exit 0
fi
if [[ \"\$*\" == 'delete table inet vps_guard' ]]; then
  rm -f '$TEST_ROOT/runtime-active'
  exit 0
fi
if [[ \"\$1\" == '-f' && -r \"\${2:-}\" ]]; then
  printf '%s\\n' '---' >>'$TEST_ROOT/nft-payload.log'
  /bin/cat \"\$2\" >>'$TEST_ROOT/nft-payload.log'
  touch '$TEST_ROOT/runtime-active'
fi
exit 0
"

  run_vps_guard firewall enable --tcp 80 --yes
  assert_status 0
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"

  run_vps_guard rollback run "$token"

  assert_status 0
  assert_output_contains "自动回滚完成"
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
  grep -q 'table inet third_party' "$TEST_ROOT/fs/etc/nftables.conf"
  if grep -q 'include "/etc/nftables.d/vps-guard.nft"' "$TEST_ROOT/fs/etc/nftables.conf"; then
    printf '自动回滚后仍残留 include\n' >&2
    return 1
  fi
  [[ "$(grep -c 'delete table inet vps_guard' "$TEST_ROOT/nft.log")" -ge 1 ]]
}

test_firewall_apply_failure_restores_snapshot_immediately() {
  local before apply_counter
  setup_firewall_test
  trap teardown_test_root RETURN
  before="$(<"$TEST_ROOT/fs/etc/nftables.conf")"
  apply_counter="$TEST_ROOT/apply-counter"
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$1 \${2:-}\" == 'list ruleset' || \"\$1 \${2:-}\" == '-c -f' ]]; then
  exit 0
fi
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  exit 1
fi
if [[ \"\$1\" == '-f' ]]; then
  count=0
  [[ -r '$apply_counter' ]] && count=\$(<'$apply_counter')
  count=\$((count + 1))
  printf '%s\\n' \"\$count\" >'$apply_counter'
  [[ \"\$count\" -eq 1 ]] && exit 1
fi
exit 0
"

  run_vps_guard firewall enable --tcp 80 --yes

  assert_status 1
  assert_output_contains "防火墙应用失败，已尝试恢复快照"
  [[ "$(<"$TEST_ROOT/fs/etc/nftables.conf")" == "$before" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
  run_vps_guard audit list
  assert_output_contains "action=firewall.enable"
  assert_output_contains "result=failure"
  assert_output_contains "reason=apply"
}

test_firewall_rollback_schedule_failure_restores_immediately() {
  local before
  setup_firewall_test
  trap teardown_test_root RETURN
  before="$(<"$TEST_ROOT/fs/etc/nftables.conf")"
  write_stub systemd-run 'exit 1'

  run_vps_guard firewall enable --tcp 80 --yes

  assert_status 1
  assert_output_contains "无法安排自动回滚，已尝试恢复原防火墙"
  [[ "$(<"$TEST_ROOT/fs/etc/nftables.conf")" == "$before" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
  run_vps_guard audit list
  assert_output_contains "action=firewall.enable"
  assert_output_contains "result=failure"
  assert_output_contains "reason=rollback-schedule"
}

test_firewall_open_and_close_basic_ports_are_idempotent() {
  local token run_count
  setup_firewall_test
  trap teardown_test_root RETURN
  seed_enabled_firewall
  write_stub systemd-run "printf 'run\\n' >>'$TEST_ROOT/systemd-run.log'"
  write_stub systemctl 'exit 0'

  run_vps_guard firewall open --ports 443,80,443 --protocol tcp --yes
  assert_status 0
  assert_output_contains "端口放行规则已更新"
  grep -q '^tcp_ports=80,443$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q 'tcp dport { 80, 443, 2222 } accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  run_vps_guard rollback confirm "$token"
  assert_status 0

  run_vps_guard firewall open --ports 443 --protocol tcp --yes
  assert_status 0
  assert_output_contains "指定端口已经开放，无需重复操作"

  run_vps_guard firewall close --ports 80 --protocol tcp --yes
  assert_status 0
  assert_output_contains "端口放行规则已关闭"
  grep -q '^tcp_ports=443$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q 'tcp dport { 443, 2222 } accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  run_vps_guard rollback confirm "$token"
  assert_status 0

  run_vps_guard firewall close --ports 80,2222 --protocol tcp --yes
  assert_status 0
  assert_output_contains "指定端口已经关闭，无需重复操作"
  grep -q 'tcp dport { 443, 2222 } accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  run_count="$(wc -l <"$TEST_ROOT/systemd-run.log" | tr -d ' ')"
  [[ "$run_count" -eq 2 ]]
}

test_firewall_update_syntax_check_accounts_for_existing_managed_table() {
  setup_firewall_test
  trap teardown_test_root RETURN
  seed_enabled_firewall
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  exit 0
fi
if [[ \"\$1 \${2:-}\" == 'list ruleset' ]]; then
  exit 0
fi
if [[ \"\$1 \${2:-}\" == '-c -f' ]]; then
  first=\$(sed -n '1p' \"\$3\")
  [[ \"\$first\" == 'delete table inet vps_guard' ]]
  exit \$?
fi
exit 0
"

  run_vps_guard --dry-run firewall open --ports 443 --protocol tcp --yes

  assert_status 0
  assert_output_contains "dry-run：不会写入配置或启动自动回滚"
}

test_firewall_disable_removes_only_managed_scope_with_rollback() {
  local token
  setup_firewall_test
  trap teardown_test_root RETURN
  seed_enabled_firewall
  printf 'table inet third_party { chain input { type filter hook input priority 10; } }\n' >>"$TEST_ROOT/fs/etc/nftables.conf"
  write_stub systemd-run 'exit 0'

  run_vps_guard firewall disable --yes

  assert_status 0
  assert_output_contains "VPS Guard 防火墙已停用"
  assert_output_contains "所有端口将由其他防火墙和上游网络策略决定"
  assert_output_contains "最坏后果：原本受拦截的服务可能暴露到公网"
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
  if grep -q 'include "/etc/nftables.d/vps-guard.nft"' "$TEST_ROOT/fs/etc/nftables.conf"; then
    printf '停用后仍残留 include\n' >&2
    return 1
  fi
  grep -q 'table inet third_party' "$TEST_ROOT/fs/etc/nftables.conf"
  token="${COMMAND_OUTPUT#*自动回滚已启动：}"
  token="${token%%$'\n'*}"
  [[ -r "$TEST_ROOT/data/rollbacks/$token/state" ]]
  grep -q '^hook=firewall$' "$TEST_ROOT/data/rollbacks/$token/state"

  run_vps_guard firewall disable --yes
  assert_status 0
  assert_output_contains "VPS Guard 防火墙已经停用"
}

test_firewall_disable_succeeds_when_managed_runtime_table_is_already_absent() {
  setup_firewall_test
  trap teardown_test_root RETURN
  seed_enabled_firewall
  write_stub systemd-run 'exit 0'
  write_stub nft "
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  exit 1
fi
if [[ \"\$1 \${2:-}\" == 'list ruleset' ]]; then
  exit 0
fi
if [[ \"\$1 \${2:-}\" == '-c -f' || \"\$1\" == '-f' ]]; then
  if grep -q 'delete table inet vps_guard' \"\${3:-\${2:-}}\"; then
    exit 1
  fi
  exit 0
fi
exit 0
"

  run_vps_guard firewall disable --yes

  assert_status 0
  assert_output_contains "VPS Guard 防火墙已停用"
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -e "$TEST_ROOT/fs/etc/vps-guard/firewall.conf" ]]
}

test_firewall_status_reports_configured_and_runtime_state() {
  setup_firewall_test
  trap teardown_test_root RETURN
  seed_enabled_firewall
  write_stub nft "
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  printf 'table inet vps_guard { }\\n'
  exit 0
fi
if [[ \"\$1 \${2:-}\" == 'list ruleset' ]]; then
  exit 0
fi
exit 0
"

  run_vps_guard firewall status

  assert_status 0
  assert_output_contains "磁盘配置：已启用"
  assert_output_contains "内核运行时：已加载 table inet vps_guard"
  assert_output_contains "受保护 SSH TCP：2222"
  assert_output_contains "额外 TCP：80"
  assert_output_contains "额外 UDP：53"
  assert_output_contains "公网可达性：未验证"
}

test_firewall_conflict_is_blocked_before_snapshot_or_write() {
  setup_firewall_test
  trap teardown_test_root RETURN
  write_stub ufw 'printf "Status: active\n"'

  run_vps_guard firewall enable --tcp 80 --yes

  assert_status 3
  assert_output_contains "[阻断] UFW 正在管理防火墙"
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_firewall_refuses_unowned_vps_guard_table_name_collision() {
  setup_firewall_test
  trap teardown_test_root RETURN
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$1 \${2:-}\" == 'list ruleset' ]]; then
  exit 0
fi
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then
  printf 'table inet vps_guard { }\\n'
  exit 0
fi
if [[ \"\$1 \${2:-}\" == '-c -f' ]]; then
  exit 0
fi
exit 0
"

  run_vps_guard firewall enable --tcp 80 --yes

  assert_status 3
  assert_output_contains "发现不属于本工具状态记录的 table inet vps_guard"
  assert_output_contains "拒绝覆盖同名第三方范围"
  if grep -q '^delete table inet vps_guard$' "$TEST_ROOT/nft.log"; then
    printf '不得删除无归属记录的同名运行时表\n' >&2
    return 1
  fi
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_firewall_rejects_advanced_or_invalid_basic_inputs() {
  setup_firewall_test
  trap teardown_test_root RETURN

  run_vps_guard firewall enable --tcp 80-90 --yes
  assert_status 2
  assert_output_contains "TCP 端口只支持"

  run_vps_guard --dry-run firewall enable --tcp 080,80 --yes
  assert_status 0
  assert_output_contains "开放 TCP：80"

  run_vps_guard firewall enable --udp 0,65536 --yes
  assert_status 2
  assert_output_contains "UDP 端口只支持"

  run_vps_guard firewall enable --tcp 80 --rollback-minutes 7 --yes
  assert_status 2
  assert_output_contains "回滚时间只允许 3、5 或 10 分钟"
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_firewall_blocks_overlapping_pending_transactions() {
  setup_firewall_test
  trap teardown_test_root RETURN
  seed_enabled_firewall
  write_stub systemd-run "printf 'run\\n' >>'$TEST_ROOT/systemd-run.log'"

  run_vps_guard firewall open --ports 443 --protocol tcp --yes
  assert_status 0

  run_vps_guard firewall close --ports 80 --protocol tcp --yes
  assert_status 3
  assert_output_contains "仍有等待确认的防火墙自动回滚"
  assert_output_contains "请先验证并确认，或等待其完成"
  [[ "$(wc -l <"$TEST_ROOT/systemd-run.log" | tr -d ' ')" -eq 1 ]]
}

test_firewall_enable_without_confirmation_cancels_safely() {
  setup_firewall_test
  trap teardown_test_root RETURN

  run_vps_guard_with_input $'n\n' firewall enable --tcp 80

  assert_status 0
  assert_output_contains "确认按上述摘要写入"
  assert_output_contains "已取消，未写入防火墙"
  [[ ! -e "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_firewall_update_and_disable_dry_runs_do_not_change_state() {
  local before_config before_state before_main
  setup_firewall_test
  trap teardown_test_root RETURN
  seed_enabled_firewall
  before_config="$(<"$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft")"
  before_state="$(<"$TEST_ROOT/fs/etc/vps-guard/firewall.conf")"
  before_main="$(<"$TEST_ROOT/fs/etc/nftables.conf")"

  run_vps_guard --dry-run firewall open --ports 443 --protocol tcp --yes
  assert_status 0
  assert_output_contains "dry-run：不会写入配置或启动自动回滚"

  run_vps_guard --dry-run firewall disable --yes
  assert_status 0
  assert_output_contains "dry-run：不会删除规则或启动自动回滚"

  [[ "$(<"$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft")" == "$before_config" ]]
  [[ "$(<"$TEST_ROOT/fs/etc/vps-guard/firewall.conf")" == "$before_state" ]]
  [[ "$(<"$TEST_ROOT/fs/etc/nftables.conf")" == "$before_main" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
  [[ ! -d "$TEST_ROOT/data/rollbacks" ]]
}

test_firewall_enable_dry_run_shows_checked_dual_stack_baseline_without_writes
test_firewall_preserves_current_verified_ssh_session_port_and_configured_port
test_firewall_enable_writes_only_managed_scope_and_starts_rollback
test_firewall_syntax_failure_leaves_system_unchanged
test_firewall_timeout_rollback_restores_files_and_runtime_table
test_firewall_apply_failure_restores_snapshot_immediately
test_firewall_rollback_schedule_failure_restores_immediately
test_firewall_open_and_close_basic_ports_are_idempotent
test_firewall_update_syntax_check_accounts_for_existing_managed_table
test_firewall_disable_removes_only_managed_scope_with_rollback
test_firewall_disable_succeeds_when_managed_runtime_table_is_already_absent
test_firewall_status_reports_configured_and_runtime_state
test_firewall_conflict_is_blocked_before_snapshot_or_write
test_firewall_refuses_unowned_vps_guard_table_name_collision
test_firewall_rejects_advanced_or_invalid_basic_inputs
test_firewall_blocks_overlapping_pending_transactions
test_firewall_enable_without_confirmation_cancels_safely
test_firewall_update_and_disable_dry_runs_do_not_change_state
