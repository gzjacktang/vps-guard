#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/test_helper.sh
source "$PROJECT_ROOT/tests/test_helper.sh"

test_preflight_reports_container_and_vpn_facts_without_writes() {
  local before after
  setup_test_root
  trap teardown_test_root RETURN

  write_stub id 'printf "0\n"'
  write_stub docker 'exit 0'
  write_stub wg 'printf "interface: wg0\n  listening port: 51820\n"'
  # 变量由生成的 stub 在运行时展开。
  # shellcheck disable=SC2016
  write_stub systemctl '
if [[ "$1 $2 $3" == "is-active --quiet docker" ]]; then
  exit 0
fi
exit 3
'
  write_stub ip 'printf "2: docker0: <BROADCAST,UP> mtu 1500\n3: wg0: <POINTOPOINT,UP> mtu 1420\n"'
  write_stub ss 'printf "udp UNCONN 0 0 0.0.0.0:51820 0.0.0.0:* users:((\\\"wg\\\",pid=10,fd=3))\n"'
  write_stub ps 'printf "dockerd /usr/bin/dockerd\n"'

  before="$(find "$TEST_ROOT" -type f ! -path "$TEST_ROOT/bin/*" -exec shasum -a 256 {} \; | sort)"
  run_vps_guard preflight
  after="$(find "$TEST_ROOT" -type f ! -path "$TEST_ROOT/bin/*" -exec shasum -a 256 {} \; | sort)"

  assert_status 0
  assert_output_contains "[事实] 容器运行时 Docker：运行中"
  assert_output_contains "[事实] VPN WireGuard：已检测"
  assert_output_contains "[事实] 相关接口：docker0"
  assert_output_contains "[事实] 相关接口：wg0"
  assert_output_contains "51820"
  [[ "$before" == "$after" ]]
}

test_preflight_blocks_conflicting_firewall_managers() {
  setup_test_root
  trap teardown_test_root RETURN

  write_stub id 'printf "0\n"'
  write_stub ufw 'printf "Status: active\n"'
  write_stub firewall-cmd 'printf "running\n"'
  write_stub iptables-save 'printf "*filter\n-A INPUT -p tcp --dport 22 -j ACCEPT\nCOMMIT\n"'

  run_vps_guard preflight

  assert_status 3
  assert_output_contains "[阻断] UFW 正在管理防火墙"
  assert_output_contains "[阻断] firewalld 正在管理防火墙"
  assert_output_contains "[阻断] iptables 中存在活动规则"
  assert_output_contains "请退出并继续使用现有管理器，或先手动迁移/停用后重试"
}

test_preflight_reports_other_runtimes_vpns_panels_and_cloud_agents() {
  setup_test_root
  trap teardown_test_root RETURN

  write_stub id 'printf "0\n"'
  write_stub podman 'exit 0'
  write_stub lxc-info 'exit 0'
  write_stub openvpn 'exit 0'
  write_stub tailscale 'exit 0'
  write_stub 1pctl 'exit 0'
  write_stub ps 'printf "%s\n" \
    "podman podman system service" \
    "lxc-start /usr/bin/lxc-start -n app" \
    "openvpn /usr/sbin/openvpn --config server.conf" \
    "tailscaled /usr/sbin/tailscaled" \
    "BT-Panel /www/server/panel/BT-Panel" \
    "1panel /opt/1panel/1panel" \
    "cpsrvd /usr/local/cpanel/cpsrvd" \
    "sw-cp-server /usr/sbin/sw-cp-server" \
    "cloudflared /usr/bin/cloudflared tunnel run" \
    "amazon-ssm-agent /usr/bin/amazon-ssm-agent"'
  write_stub ip 'printf "4: lxcbr0: <UP> mtu 1500\n5: tailscale0: <UP> mtu 1280\n"'
  write_stub ss 'printf "%s\n" \
    "tcp LISTEN 0 128 0.0.0.0:7800 0.0.0.0:* users:((\\\"1panel\\\",pid=20,fd=5))" \
    "udp UNCONN 0 0 0.0.0.0:1194 0.0.0.0:* users:((\\\"openvpn\\\",pid=21,fd=6))" \
    "tcp LISTEN 0 128 0.0.0.0:2087 0.0.0.0:* users:((\\\"cpsrvd\\\",pid=22,fd=7))" \
    "tcp LISTEN 0 128 0.0.0.0:8443 0.0.0.0:* users:((\\\"sw-cp-server\\\",pid=23,fd=8))" \
    "tcp LISTEN 0 128 127.0.0.1:20241 0.0.0.0:* users:((\\\"cloudflared\\\",pid=24,fd=9))"'

  run_vps_guard preflight

  assert_status 0
  assert_output_contains "[事实] 容器运行时 Podman：运行中"
  assert_output_contains "[事实] 容器运行时 LXC：运行中"
  assert_output_contains "[事实] VPN OpenVPN：已检测"
  assert_output_contains "[事实] VPN Tailscale：已检测"
  assert_output_contains "[事实] 控制面板 宝塔：已检测"
  assert_output_contains "[事实] 控制面板 1Panel：已检测"
  assert_output_contains "[事实] 控制面板 cPanel：已检测"
  assert_output_contains "[事实] 控制面板 Plesk：已检测"
  assert_output_contains "[事实] 云代理 Cloudflare Tunnel：已检测"
  assert_output_contains "[事实] 云代理 Amazon SSM Agent：已检测"
  assert_output_contains "[待确认] 请确认保留控制面板和 VPN 的实际监听端口与接口"
  assert_output_contains "0.0.0.0:7800"
  assert_output_contains "0.0.0.0:1194"
  assert_output_contains "0.0.0.0:2087"
  assert_output_contains "0.0.0.0:8443"
  assert_output_contains "127.0.0.1:20241"
}

test_preflight_invokes_only_read_only_network_commands() {
  local calls
  setup_test_root
  trap teardown_test_root RETURN

  calls="$TEST_ROOT/bin/calls"
  write_stub id 'printf "0\n"'
  write_stub ufw "printf 'ufw %s\\n' \"\$*\" >>'$calls'; printf 'Status: inactive\\n'"
  write_stub firewall-cmd "printf 'firewall-cmd %s\\n' \"\$*\" >>'$calls'; printf 'not running\\n'"
  write_stub iptables-save "printf 'iptables-save %s\\n' \"\$*\" >>'$calls'"
  write_stub nft "printf 'nft %s\\n' \"\$*\" >>'$calls'"
  write_stub systemctl "printf 'systemctl %s\\n' \"\$*\" >>'$calls'; exit 3"
  write_stub ip "printf 'ip %s\\n' \"\$*\" >>'$calls'"
  write_stub ss "printf 'ss %s\\n' \"\$*\" >>'$calls'"
  write_stub ps "printf 'ps %s\\n' \"\$*\" >>'$calls'"

  run_vps_guard preflight

  assert_status 0
  assert_output_contains "UFW：已安装，未检测到活动状态"
  [[ "$(<"$calls")" == *"ufw status"* ]]
  [[ "$(<"$calls")" == *"firewall-cmd --state"* ]]
  [[ "$(<"$calls")" == *"iptables-save "* ]]
  [[ "$(<"$calls")" == *"nft list ruleset"* ]]
  [[ "$(<"$calls")" != *" add "* ]]
  [[ "$(<"$calls")" != *" delete "* ]]
  [[ "$(<"$calls")" != *" flush "* ]]
  [[ "$(<"$calls")" != *" enable "* ]]
  [[ "$(<"$calls")" != *" disable "* ]]
}

test_preflight_blocks_when_firewall_state_cannot_be_read() {
  setup_test_root
  trap teardown_test_root RETURN

  write_stub id 'printf "0\n"'
  write_stub ufw 'exit 1'

  run_vps_guard preflight

  assert_status 3
  assert_output_contains "[阻断] 无法确认 UFW 状态"
  assert_output_contains "默认阻止防火墙写入"
}

test_preflight_preserves_container_iptables_chains_without_false_conflict() {
  setup_test_root
  trap teardown_test_root RETURN

  write_stub id 'printf "0\n"'
  write_stub docker 'exit 0'
  write_stub ps 'printf "dockerd /usr/bin/dockerd\n"'
  write_stub iptables-save 'printf "%s\n" \
    "*filter" \
    "-A FORWARD -j DOCKER-USER" \
    "-A DOCKER-USER -j RETURN" \
    "COMMIT"'

  run_vps_guard preflight

  assert_status 0
  assert_output_contains "[待确认] iptables 中仅检测到容器相关链"
  assert_output_contains "不会修改 FORWARD、NAT 或容器链"
  assert_output_not_contains "iptables 中存在活动规则"

  write_stub iptables-save 'printf "%s\n" \
    "*filter" \
    "-A FORWARD -j DOCKER-USER" \
    "-A DOCKER-USER -j RETURN" \
    "-A INPUT -m comment --comment DOCKER -p tcp --dport 9000 -j ACCEPT" \
    "COMMIT"'
  run_vps_guard preflight
  assert_status 3
  assert_output_contains "[阻断] iptables 中存在活动规则"

  write_stub iptables-save 'printf "%s\n" \
    "*filter" \
    "-A INPUT -j DOCKER-USER" \
    "-A DOCKER-USER -p tcp --dport 22 -j DROP" \
    "COMMIT"'
  run_vps_guard preflight
  assert_status 3
  assert_output_contains "[阻断] iptables 中存在活动规则"
}

test_preflight_detects_when_guest_itself_runs_in_lxc() {
  setup_test_root
  trap teardown_test_root RETURN

  mkdir -p "$TEST_ROOT/fs/proc/1"
  printf '0::/lxc.payload.vps/init.scope\n' >"$TEST_ROOT/fs/proc/1/cgroup"
  write_stub id 'printf "0\n"'

  run_vps_guard preflight

  assert_status 0
  assert_output_contains "[事实] 当前系统自身运行在 LXC 容器内"
  assert_output_contains "[待确认] 无法读取进程列表"
  assert_output_contains "[待确认] 无法读取网络接口"
  assert_output_contains "[待确认] 无法读取监听端口"
}

test_preflight_rejects_extra_arguments() {
  setup_test_root
  trap teardown_test_root RETURN

  write_stub id 'printf "0\n"'
  run_vps_guard preflight extra

  assert_status 2
  assert_output_contains "preflight 不接受额外参数"
}

test_preflight_reports_container_and_vpn_facts_without_writes
test_preflight_blocks_conflicting_firewall_managers
test_preflight_reports_other_runtimes_vpns_panels_and_cloud_agents
test_preflight_invokes_only_read_only_network_commands
test_preflight_blocks_when_firewall_state_cannot_be_read
test_preflight_preserves_container_iptables_chains_without_false_conflict
test_preflight_detects_when_guest_itself_runs_in_lxc
test_preflight_rejects_extra_arguments
