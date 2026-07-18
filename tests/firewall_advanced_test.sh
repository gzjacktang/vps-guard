#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

setup_advanced_firewall_test() {
  setup_test_root
  mkdir -p "$TEST_ROOT/fs/etc/nftables.d" "$TEST_ROOT/fs/etc/vps-guard" "$TEST_ROOT/fs/etc/ssh"
  printf '#!/usr/sbin/nft -f\ninclude "/etc/nftables.d/vps-guard.nft" # vps-guard\n' >"$TEST_ROOT/fs/etc/nftables.conf"
  printf 'table inet vps_guard { }\n' >"$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  printf '%s\n' \
    'format=2' \
    'enabled=1' \
    'ssh_ports=2222' \
    'tcp_ports=80' \
    'udp_ports=53' >"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  printf '%s\n' \
    '/etc/nftables.conf' \
    '/etc/nftables.d/vps-guard.nft' \
    '/etc/vps-guard/firewall.conf' >"$TEST_ROOT/managed-paths"
  write_stub id 'printf "0\n"'
  write_stub sshd 'printf "port 2222\npasswordauthentication yes\n"'
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then exit 0; fi
if [[ \"\$1 \${2:-}\" == 'list ruleset' || \"\$1 \${2:-}\" == '-c -f' ]]; then exit 0; fi
exit 0
"
if [[ "\$1" == '-f' ]]; then exit 0; fi
  write_stub systemctl 'exit 0'
  write_stub ss 'printf "%s\n" "tcp LISTEN 0 128 0.0.0.0:8080 0.0.0.0:* users:((\"node\",pid=42,fd=3))" "tcp LISTEN 0 128 0.0.0.0:443 0.0.0.0:* users:((\"nginx\",pid=12,fd=3))" "udp UNCONN 0 0 [::]:53 [::]:* users:((\"named\",pid=9,fd=4))"'
}

test_inbound_advanced_rule_normalizes_expands_and_is_idempotent() {
  local runs
  setup_advanced_firewall_test
  trap teardown_test_root RETURN

  run_vps_guard firewall open --ports '443,80-82,81,443' --protocol both \
    --direction inbound --family ipv4 --source 198.51.100.0/24 --interface eth0 --yes

  assert_status 0
  assert_output_contains "规范化端口：80-82,443"
  assert_output_contains "重复端口或重叠区间"
  assert_output_contains "潜在覆盖：基础双栈全来源规则"
  grep -q '^rule=accept|input|tcp|ipv4|80-82,443|198.51.100.0/24|eth0$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^rule=accept|input|udp|ipv4|80-82,443|198.51.100.0/24|eth0$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q 'ip saddr 198.51.100.0/24 iifname "eth0" tcp dport { 80-82, 443 } accept' "$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  run_vps_guard firewall open --ports 80-82,443 --protocol both \
    --direction inbound --family ipv4 --source 198.51.100.0/24 --interface eth0 --yes
  assert_status 0
  assert_output_contains "已经开放，无需重复操作"
  [[ ! -e "$TEST_ROOT/systemd-run.log" ]]
}

test_inbound_close_subtracts_ranges_and_preserves_other_rules() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  printf '%s\n' \
    'rule=accept|input|tcp|ipv4|80-82,443|198.51.100.0/24|eth0' \
    'rule=accept|input|udp|ipv6|5353|2001:db8::/32|eth1' >>"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"

  run_vps_guard firewall close --ports 81 --protocol tcp \
    --direction inbound --family ipv4 --source 198.51.100.0/24 --interface eth0 --yes

  assert_status 0
  grep -q '^rule=accept|input|tcp|ipv4|80,82,443|198.51.100.0/24|eth0$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^rule=accept|input|udp|ipv6|5353|2001:db8::/32|eth1$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  [[ ! -e "$TEST_ROOT/systemd-run.log" ]]
}

test_outbound_close_warns_without_scheduling_rollback() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  write_stub nft "
printf '%s\\n' \"\$*\" >>'$TEST_ROOT/nft.log'
if [[ \"\$*\" == 'list table inet vps_guard' ]]; then exit 0; fi
if [[ \"\$1 \${2:-}\" == 'list ruleset' || \"\$1 \${2:-}\" == '-c -f' ]]; then exit 0; fi
if [[ "\$1" == '-f' ]]; then exit 0; fi
exit 0
"

  run_vps_guard firewall close --ports 53,443 --protocol both \
    --direction outbound --family dual --source all --yes

  assert_status 0
  assert_output_contains "高级风险警告"
  assert_output_contains "DNS、APT/HTTPS、NTP"
  grep -q '^rule=drop|output|tcp|ipv4|53,443|\*|\*$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^rule=drop|output|udp|ipv6|53,443|\*|\*$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  config="$TEST_ROOT/fs/etc/nftables.d/vps-guard.nft"
  established_line="$(grep -n 'ct state established,related accept' "$config" | tail -1 | cut -d: -f1)"
  drop_line="$(grep -n 'meta nfproto ipv4 tcp dport { 53, 443 } drop' "$config" | cut -d: -f1)"
  [[ "$established_line" -lt "$drop_line" ]]
}

test_invalid_dimensions_fail_before_snapshot() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN

  run_vps_guard firewall open --ports 22 --protocol tcp --direction inbound --family dual --source 198.51.100.0/24 --yes
  assert_status 2
  assert_output_contains "不能使用 dual"
  run_vps_guard firewall open --ports 22 --protocol tcp --direction inbound --family ipv6 --source 198.51.100.0/24 --yes
  assert_status 2
  assert_output_contains "不匹配"
  run_vps_guard firewall open --ports 22 --protocol tcp --direction inbound --family ipv4 --source all --interface 'eth0" accept' --yes
  assert_status 2
  assert_output_contains "接口名称无效"
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_outbound_dry_run_and_rejected_confirmation_are_read_only() {
  local before
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  before="$(<"$TEST_ROOT/fs/etc/vps-guard/firewall.conf")"

  run_vps_guard --dry-run firewall close --ports 53 --protocol udp \
    --direction outbound --family dual --source all --yes
  assert_status 0
  assert_output_contains "高级风险警告"
  assert_output_contains "dry-run：不会写入配置"
  [[ "$(<"$TEST_ROOT/fs/etc/vps-guard/firewall.conf")" == "$before" ]]

  run_vps_guard_with_input $'n\n' firewall close --ports 53 --protocol udp \
    --direction outbound --family dual --source all
  assert_status 0
  assert_output_contains "已取消，未写入防火墙"
  [[ "$(<"$TEST_ROOT/fs/etc/vps-guard/firewall.conf")" == "$before" ]]
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_filtered_status_reports_rules_listener_and_external_evidence() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  printf '%s\n' 'rule=accept|input|tcp|ipv4|443|198.51.100.0/24|eth0' >>"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"

  run_vps_guard firewall status --ports 443 --protocol tcp --direction inbound --family ipv4 \
    --source 198.51.100.0/24 --interface eth0 --external-confirm reachable

  assert_status 0
  assert_output_contains "三层端口状态"
  assert_output_contains "VPS Guard 规则：允许"
  assert_output_contains "本机监听：是"
  assert_output_contains "nginx"
  assert_output_contains "用户本次确认可达（非工具探测）"
}

test_idempotent_close_still_warns_when_service_listens() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN

  run_vps_guard firewall close --ports 8080 --protocol tcp --direction inbound --family ipv4 --source all --yes

  assert_status 0
  assert_output_contains "已经关闭，无需重复操作"
  assert_output_contains "服务仍在本机监听"
  assert_output_contains "node"
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_advanced_close_refuses_to_claim_closed_under_broader_basic_rule() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN

  run_vps_guard firewall close --ports 80 --protocol tcp --direction inbound \
    --family ipv4 --source 198.51.100.8 --yes

  assert_status 3
  assert_output_contains "基础双栈全来源规则仍放行"
  [[ ! -d "$TEST_ROOT/data/backups" ]]
}

test_filtered_status_distinguishes_partial_coverage_and_ss_failure() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  printf '%s\n' 'rule=accept|input|tcp|ipv4|443|198.51.100.0/24|eth0' >>"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"

  run_vps_guard firewall status --ports 443 --protocol tcp --direction inbound --family dual \
    --source 198.51.100.0/24 --interface eth0
  assert_status 0
  assert_output_contains "部分匹配"

  run_vps_guard firewall status --ports 80-81 --protocol tcp --direction inbound --family dual --source all
  assert_status 0
  assert_output_contains "部分匹配"

  write_stub ss 'exit 1'
  run_vps_guard firewall status --ports 443 --protocol tcp --direction inbound --family ipv4 \
    --source 198.51.100.0/24 --interface eth0
  assert_status 0
  assert_output_contains "本机监听：未知（ss 状态不可读）"
}

test_filtered_status_rejects_corrupted_advanced_state() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  printf '%s\n' 'rule=accept|input|tcp|ipv4|443|*|eth0|injected' >>"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"

  run_vps_guard firewall status --ports 443 --protocol tcp --direction inbound --family ipv4 --source all

  assert_status 3
  assert_output_contains "状态包含无效高级规则"
}

test_cidr_containment_drives_close_and_status_safely() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  printf '%s\n' 'rule=accept|input|tcp|ipv4|443|198.51.100.0/24|eth0' >>"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"

  run_vps_guard firewall status --ports 443 --protocol tcp --direction inbound --family ipv4 \
    --source 198.51.100.10 --interface eth0
  assert_status 0
  assert_output_contains "VPS Guard 规则：允许"

  run_vps_guard firewall close --ports 443 --protocol tcp --direction inbound --family ipv4 \
    --source 198.51.100.10 --interface eth0 --yes
  assert_status 3
  assert_output_contains "更宽来源或接口规则仍放行"
}

test_all_source_close_removes_narrower_source_rules() {
  setup_advanced_firewall_test
  trap teardown_test_root RETURN
  printf '%s\n' \
    'rule=accept|input|tcp|ipv4|443|198.51.100.0/24|eth0' \
    'rule=accept|input|tcp|ipv4|443|203.0.113.8|eth1' \
    'rule=accept|input|udp|ipv4|443|203.0.113.8|eth1' \
    'rule=accept|input|tcp|ipv6|443|2001:db8::/32|eth1' \
    'rule=drop|output|tcp|ipv4|443|203.0.113.8|eth1' >>"$TEST_ROOT/fs/etc/vps-guard/firewall.conf"

  run_vps_guard firewall close --ports 443 --protocol tcp --direction inbound --family ipv4 \
    --source all --yes
  assert_status 0
  if grep -q '^rule=accept|input|tcp|ipv4|443|' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"; then
    printf 'all 来源关闭后仍有更窄来源规则\n' >&2
    return 1
  fi
  grep -q '^rule=accept|input|udp|ipv4|443|203.0.113.8|eth1$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^rule=accept|input|tcp|ipv6|443|2001:db8::/32|eth1$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  grep -q '^rule=drop|output|tcp|ipv4|443|203.0.113.8|eth1$' "$TEST_ROOT/fs/etc/vps-guard/firewall.conf"
  [[ ! -e "$TEST_ROOT/systemd-run.log" ]]
}

test_inbound_advanced_rule_normalizes_expands_and_is_idempotent
test_inbound_close_subtracts_ranges_and_preserves_other_rules
test_outbound_close_warns_without_scheduling_rollback
test_invalid_dimensions_fail_before_snapshot
test_outbound_dry_run_and_rejected_confirmation_are_read_only
test_filtered_status_reports_rules_listener_and_external_evidence
test_idempotent_close_still_warns_when_service_listens
test_advanced_close_refuses_to_claim_closed_under_broader_basic_rule
test_filtered_status_distinguishes_partial_coverage_and_ss_failure
test_filtered_status_rejects_corrupted_advanced_state
test_cidr_containment_drives_close_and_status_safely
test_all_source_close_removes_narrower_source_rules

printf 'firewall_advanced_test: ok\n'
