#!/usr/bin/env bash

# 预检模块只读取系统状态。调用者只需要关心报告和最终退出码，
# 不需要了解容器、VPN、面板或防火墙管理器的具体探测方式。
PREFLIGHT_CONFLICT_COUNT=0
PREFLIGHT_PRESERVE_CONFIRM=0

preflight_fs_root() {
  printf '%s\n' "${VPS_GUARD_FS_ROOT:-}"
}

preflight_service_active() {
  local unit="$1"
  command_exists systemctl && systemctl is-active --quiet "$unit" 2>/dev/null
}

preflight_processes() {
  command_exists ps || return 1
  ps -eo comm=,args= 2>/dev/null
}

preflight_interfaces() {
  command_exists ip || return 1
  ip -o link show 2>/dev/null
}

preflight_listeners() {
  command_exists ss || return 1
  ss -lntupH 2>/dev/null
}

report_container_runtimes() {
  local processes="$1"

  if command_exists docker || [[ "$processes" == *dockerd* ]]; then
    if preflight_service_active docker || [[ "$processes" == *dockerd* ]]; then
      printf '[事实] 容器运行时 Docker：运行中\n'
    else
      printf '[事实] 容器运行时 Docker：已安装，未发现运行状态\n'
    fi
  fi

  if command_exists podman || [[ "$processes" == *podman* ]]; then
    if [[ "$processes" == *podman* ]]; then
      printf '[事实] 容器运行时 Podman：运行中\n'
    else
      printf '[事实] 容器运行时 Podman：已安装，未发现运行状态\n'
    fi
  fi

  if command_exists lxc-info || command_exists lxc-ls || [[ "$processes" == *lxc-start* || "$processes" == *lxc-monitord* ]]; then
    if [[ "$processes" == *lxc-start* || "$processes" == *lxc-monitord* ]]; then
      printf '[事实] 容器运行时 LXC：运行中\n'
    else
      printf '[事实] 容器运行时 LXC：已安装，未发现运行状态\n'
    fi
  fi
}

report_vpns() {
  local processes="$1"
  local interfaces="$2"
  local wg_output

  if command_exists wg; then
    if ! wg_output="$(wg show 2>/dev/null)"; then
      printf '[待确认] WireGuard 已安装，但无法读取接口状态\n'
    elif [[ -n "$wg_output" ]]; then
      printf '[事实] VPN WireGuard：已检测'
      if [[ "$wg_output" =~ listening[[:space:]]port:[[:space:]]([0-9]+) ]]; then
        printf '（监听 UDP %s）' "${BASH_REMATCH[1]}"
      fi
      printf '\n'
      PREFLIGHT_PRESERVE_CONFIRM=1
    else
      printf '[事实] VPN WireGuard：已安装，未发现活动接口\n'
    fi
  elif [[ "$interfaces" == *wg[0-9]* ]]; then
    printf '[事实] VPN WireGuard：已检测活动接口\n'
    PREFLIGHT_PRESERVE_CONFIRM=1
  fi

  if command_exists openvpn || [[ "$processes" == *openvpn* ]]; then
    if [[ "$processes" == *openvpn* ]]; then
      printf '[事实] VPN OpenVPN：已检测\n'
      PREFLIGHT_PRESERVE_CONFIRM=1
    else
      printf '[事实] VPN OpenVPN：已安装，未发现运行进程\n'
    fi
  fi

  if command_exists tailscale || command_exists tailscaled || [[ "$processes" == *tailscaled* || "$interfaces" == *tailscale* ]]; then
    if [[ "$processes" == *tailscaled* || "$interfaces" == *tailscale* ]]; then
      printf '[事实] VPN Tailscale：已检测\n'
      PREFLIGHT_PRESERVE_CONFIRM=1
    else
      printf '[事实] VPN Tailscale：已安装，未发现活动状态\n'
    fi
  fi
}

report_control_panels() {
  local processes="$1"
  local fs_root lower
  fs_root="$(preflight_fs_root)"
  lower="$(printf '%s' "$processes" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lower" == *bt-panel* || "$lower" == *'/www/server/panel/'* || -e "$fs_root/www/server/panel/BT-Panel" ]]; then
    printf '[事实] 控制面板 宝塔：已检测\n'
    PREFLIGHT_PRESERVE_CONFIRM=1
  fi
  if command_exists 1pctl || [[ "$lower" == *1panel* || -e "$fs_root/opt/1panel" ]]; then
    printf '[事实] 控制面板 1Panel：已检测\n'
    PREFLIGHT_PRESERVE_CONFIRM=1
  fi
  if [[ "$lower" == *cockpit-ws* ]] || preflight_service_active cockpit.socket; then
    printf '[事实] 控制面板 Cockpit：已检测\n'
    PREFLIGHT_PRESERVE_CONFIRM=1
  fi
  if [[ "$lower" == *cpsrvd* ]]; then
    printf '[事实] 控制面板 cPanel：已检测\n'
    PREFLIGHT_PRESERVE_CONFIRM=1
  fi
  if [[ "$lower" == *sw-cp-server* ]]; then
    printf '[事实] 控制面板 Plesk：已检测\n'
    PREFLIGHT_PRESERVE_CONFIRM=1
  fi
}

report_cloud_agents() {
  local processes="$1"
  local lower
  lower="$(printf '%s' "$processes" | tr '[:upper:]' '[:lower:]')"

  [[ "$lower" == *amazon-ssm-agent* ]] && printf '[事实] 云代理 Amazon SSM Agent：已检测\n'
  [[ "$lower" == *waagent* ]] && printf '[事实] 云代理 Azure Linux Agent：已检测\n'
  [[ "$lower" == *google_guest_agent* ]] && printf '[事实] 云代理 Google Guest Agent：已检测\n'
  [[ "$lower" == *qemu-ga* || "$lower" == *qemu-guest-agent* ]] && printf '[事实] 云代理 QEMU Guest Agent：已检测\n'
  [[ "$lower" == *cloudflared* ]] && printf '[事实] 云代理 Cloudflare Tunnel：已检测\n'
  [[ "$lower" == *warp-svc* ]] && printf '[事实] 云代理 Cloudflare WARP：已检测\n'
  return 0
}

report_container_guest() {
  local fs_root cgroup_file cgroup
  fs_root="$(preflight_fs_root)"
  cgroup_file="$fs_root/proc/1/cgroup"
  [[ -r "$cgroup_file" ]] || return 0
  cgroup="$(<"$cgroup_file")"
  case "$cgroup" in
    *docker*) printf '[事实] 当前系统自身运行在 Docker 容器内。\n' ;;
    *libpod*) printf '[事实] 当前系统自身运行在 Podman 容器内。\n' ;;
    *lxc*) printf '[事实] 当前系统自身运行在 LXC 容器内。\n' ;;
  esac
}

report_relevant_interfaces() {
  local interfaces="$1"
  local line name

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    name="$(awk '{print $2}' <<<"$line")"
    name="${name%%@*}"
    name="${name%:}"
    case "$name" in
      docker* | br-* | podman* | lxcbr* | wg* | tun* | tap* | tailscale*)
        printf '[事实] 相关接口：%s\n' "$name"
        ;;
    esac
  done <<<"$interfaces"
}

report_relevant_listeners() {
  local listeners="$1"
  local line lower

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    lower="$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      *docker* | *podman* | *lxc* | *wireguard* | *'"wg"'* | *openvpn* | *tailscale* | *1panel* | *bt-panel* | *cockpit* | *cpsrvd* | *sw-cp-server* | *cloudflared* | *warp-svc*)
        printf '[事实] 相关监听：%s\n' "$line"
        ;;
    esac
  done <<<"$listeners"
}

iptables_rules_are_container_only() {
  local rules="$1"
  local line chain target index
  local fields=()
  local found=0

  while IFS= read -r line; do
    [[ "$line" == -A\ * ]] || continue
    found=1
    read -r -a fields <<<"$line"
    chain="${fields[1]:-}"
    target=""
    for ((index = 2; index < ${#fields[@]}; index++)); do
      if [[ "${fields[index]}" == "-j" || "${fields[index]}" == "-g" ]]; then
        target="${fields[index + 1]:-}"
        break
      fi
    done

    if container_chain_name "$chain"; then
      if [[ "$chain" != "DOCKER-USER" || "$line" == "-A DOCKER-USER -j RETURN" ]]; then
        continue
      fi
      return 1
    fi

    # 只豁免容器工具通常建立的转发/NAT 拓扑；INPUT 跳转始终视为主机防火墙冲突。
    case "$chain" in
      FORWARD | PREROUTING | POSTROUTING | OUTPUT)
        if container_chain_name "$target"; then
          continue
        fi
        if [[ "$chain" == "FORWARD" ]]; then
          case "$line" in
            *' -i docker'* | *' -o docker'* | *' -i br-'* | *' -o br-'* | *' -i podman'* | *' -o podman'* | *' -i lxcbr'* | *' -o lxcbr'*)
              continue
              ;;
          esac
        fi
        ;;
    esac
    return 1
  done <<<"$rules"

  [[ "$found" -eq 1 ]]
}

container_chain_name() {
  case "$1" in
    DOCKER* | CNI-* | PODMAN* | LXC* | LIBVIRT* | KUBE-*) return 0 ;;
    *) return 1 ;;
  esac
}

report_firewall_managers() {
  local output

  if command_exists ufw; then
    if ! output="$(ufw status 2>/dev/null)"; then
      printf '[阻断] 无法确认 UFW 状态；默认阻止防火墙写入。\n'
      PREFLIGHT_CONFLICT_COUNT=$((PREFLIGHT_CONFLICT_COUNT + 1))
    elif printf '%s\n' "$output" | grep -Eqi 'status:[[:space:]]*active|状态[：:][[:space:]]*(活动|激活)'; then
      printf '[阻断] UFW 正在管理防火墙。\n'
      PREFLIGHT_CONFLICT_COUNT=$((PREFLIGHT_CONFLICT_COUNT + 1))
    else
      printf '[事实] UFW：已安装，未检测到活动状态。\n'
    fi
  fi

  if command_exists firewall-cmd; then
    if ! output="$(firewall-cmd --state 2>/dev/null)"; then
      if [[ "$output" == "not running" ]]; then
        printf '[事实] firewalld：已安装，未检测到运行状态。\n'
      else
        printf '[阻断] 无法确认 firewalld 状态；默认阻止防火墙写入。\n'
        PREFLIGHT_CONFLICT_COUNT=$((PREFLIGHT_CONFLICT_COUNT + 1))
      fi
    elif [[ "$output" == "running" ]]; then
      printf '[阻断] firewalld 正在管理防火墙。\n'
      PREFLIGHT_CONFLICT_COUNT=$((PREFLIGHT_CONFLICT_COUNT + 1))
    else
      printf '[事实] firewalld：已安装，未检测到运行状态。\n'
    fi
  fi

  if command_exists iptables-save; then
    if ! output="$(iptables-save 2>/dev/null)"; then
      printf '[阻断] 无法读取 iptables 规则；默认阻止防火墙写入。\n'
      PREFLIGHT_CONFLICT_COUNT=$((PREFLIGHT_CONFLICT_COUNT + 1))
    elif printf '%s\n' "$output" | grep -q '^-A '; then
      if iptables_rules_are_container_only "$output"; then
        printf '[待确认] iptables 中仅检测到容器相关链；VPS Guard 不会修改 FORWARD、NAT 或容器链。\n'
      else
        printf '[阻断] iptables 中存在活动规则。\n'
        PREFLIGHT_CONFLICT_COUNT=$((PREFLIGHT_CONFLICT_COUNT + 1))
      fi
    else
      printf '[事实] iptables：未检测到活动规则。\n'
    fi
  fi

  if command_exists nft; then
    if ! output="$(nft list ruleset 2>/dev/null)"; then
      printf '[阻断] 无法读取 nftables 规则；默认阻止防火墙写入。\n'
      PREFLIGHT_CONFLICT_COUNT=$((PREFLIGHT_CONFLICT_COUNT + 1))
    elif [[ -n "$output" ]]; then
      printf '[待确认] nftables 中已有规则；VPS Guard 只会管理自己的表，不会改动第三方表。\n'
    else
      printf '[事实] nftables：未检测到现有规则。\n'
    fi
  fi
}

show_preflight_report() {
  local processes interfaces listeners
  local processes_readable=1 interfaces_readable=1 listeners_readable=1

  PREFLIGHT_CONFLICT_COUNT=0
  PREFLIGHT_PRESERVE_CONFIRM=0
  if ! processes="$(preflight_processes)"; then
    processes=""
    processes_readable=0
  fi
  if ! interfaces="$(preflight_interfaces)"; then
    interfaces=""
    interfaces_readable=0
  fi
  if ! listeners="$(preflight_listeners)"; then
    listeners=""
    listeners_readable=0
  fi

  printf 'VPS Guard 网络环境预检（只读）\n'
  [[ "$processes_readable" -eq 1 ]] || printf '[待确认] 无法读取进程列表，进程类检测可能不完整。\n'
  [[ "$interfaces_readable" -eq 1 ]] || printf '[待确认] 无法读取网络接口，接口类检测可能不完整。\n'
  [[ "$listeners_readable" -eq 1 ]] || printf '[待确认] 无法读取监听端口，端口关联可能不完整。\n'
  report_container_guest
  report_container_runtimes "$processes"
  report_vpns "$processes" "$interfaces"
  report_control_panels "$processes"
  report_cloud_agents "$processes"
  report_relevant_interfaces "$interfaces"
  report_relevant_listeners "$listeners"
  report_firewall_managers

  if [[ "$PREFLIGHT_PRESERVE_CONFIRM" -eq 1 ]]; then
    printf '[待确认] 请确认保留控制面板和 VPN 的实际监听端口与接口。\n'
  fi

  if [[ "$PREFLIGHT_CONFLICT_COUNT" -gt 0 ]]; then
    printf '[阻断] 请退出并继续使用现有管理器，或先手动迁移/停用后重试。\n'
    return "$EXIT_CONFLICT"
  fi
  printf '[事实] 未发现会阻止写入 nftables 规则的管理器冲突。\n'
}

preflight_cli() {
  [[ "$#" -eq 0 ]] || {
    error "preflight 不接受额外参数"
    return "$EXIT_USAGE"
  }
  require_firewall_write_preflight
}

# 后续所有防火墙写入都通过这个单一门禁；冲突或状态未知时返回 EXIT_CONFLICT。
require_firewall_write_preflight() {
  show_preflight_report
}
