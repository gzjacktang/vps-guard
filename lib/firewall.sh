#!/usr/bin/env bash

firewall_config_path() {
  printf '%s/etc/nftables.d/vps-guard.nft\n' "${VPS_GUARD_FS_ROOT:-}"
}

firewall_state_path() {
  printf '%s/etc/vps-guard/firewall.conf\n' "${VPS_GUARD_FS_ROOT:-}"
}

normalize_basic_ports() {
  [[ -n "$1" ]] || return 0
  firewall_rules_normalize_ports "$1"
}

effective_sshd_ports() {
  local effective ports
  command_exists sshd || {
    error "无法检测当前 SSH 端口：缺少 sshd"
    return "$EXIT_FAILURE"
  }
  if ! effective="$(sshd -T 2>/dev/null)"; then
    error "无法读取 sshd 实际生效配置"
    return "$EXIT_FAILURE"
  fi
  # sshd -T 表示重启后仍应保留的配置入口；SSH_CONNECTION 表示本次会话已经验证可用的实际入口。
  # 迁移期间两者可能不同，必须取并集，不能用其中一个覆盖另一个。
  ports="$(printf '%s\n' "$effective" | awk '$1 == "port" { print $2 }' | sort -n -u | paste -sd, -)"
  [[ -n "$ports" ]] || {
    error "sshd 实际生效配置中没有端口"
    return "$EXIT_FAILURE"
  }
  ports="$(normalize_basic_ports "$ports")" || return $?
  printf '%s\n' "$ports"
}

current_ssh_ports() {
  local ports connection client_ip client_port server_ip server_port extra
  ports="$(effective_sshd_ports)" || return $?

  connection="${VPS_GUARD_SSH_CONNECTION:-${SSH_CONNECTION:-}}"
  if [[ -n "$connection" ]]; then
    read -r client_ip client_port server_ip server_port extra <<<"$connection"
    if [[ -n "${extra:-}" || -z "${client_ip:-}" || -z "${server_ip:-}" ||
      ! "${client_port:-}" =~ ^[0-9]+$ || ! "${server_port:-}" =~ ^[0-9]+$ ||
      "$server_port" -lt 1 || "$server_port" -gt 65535 ]]; then
      error "无法解析当前 SSH_CONNECTION，拒绝猜测已验证入口"
      return "$EXIT_FAILURE"
    fi
    ports="$(merge_basic_ports "$ports" "$server_port")"
  fi
  printf '%s\n' "$ports"
}

comma_ports_to_nft_set() {
  printf '%s' "$1" | sed 's/,/, /g'
}

merge_basic_ports() {
  local first="$1"
  local second="$2"
  if [[ -n "$first" && -n "$second" ]]; then
    normalize_basic_ports "$first,$second"
  else
    normalize_basic_ports "$first$second"
  fi
}

remove_basic_ports() {
  [[ -n "$1" ]] || return 0
  firewall_rules_interval_difference "$1" "$2"
}

firewall_advanced_state_records() {
  local state_path
  state_path="$(firewall_state_path)"
  [[ -r "$state_path" ]] || return 0
  sed -n 's/^rule=//p' "$state_path"
}

firewall_state_value() {
  local key="$1"
  local state_path
  state_path="$(firewall_state_path)"
  [[ -r "$state_path" ]] || return "$EXIT_FAILURE"
  sed -n "s/^${key}=//p" "$state_path" | tail -1
}

require_firewall_enabled() {
  local state_path
  state_path="$(firewall_state_path)"
  if [[ ! -r "$state_path" || "$(firewall_state_value enabled)" != "1" ]]; then
    error "VPS Guard 防火墙尚未启用"
    return "$EXIT_FAILURE"
  fi
}

render_firewall_ruleset() {
  local destination="$1"
  local ssh_ports="$2"
  local tcp_ports="$3"
  local udp_ports="$4"
  local advanced_rules="${5:-}" all_tcp record expression
  all_tcp="$(merge_basic_ports "$ssh_ports" "$tcp_ports")"

  {
    printf 'table inet vps_guard {\n'
    printf '  chain input {\n'
    printf '    type filter hook input priority 0; policy drop;\n'
    printf '    ct state established,related accept\n'
    printf '    iifname "lo" accept\n'
    printf '    ip protocol icmp accept\n'
    printf '    meta l4proto ipv6-icmp accept\n'
    [[ -z "$all_tcp" ]] || printf '    tcp dport { %s } accept\n' "$(comma_ports_to_nft_set "$all_tcp")"
    [[ -z "$udp_ports" ]] || printf '    udp dport { %s } accept\n' "$(comma_ports_to_nft_set "$udp_ports")"
    while IFS= read -r record; do
      [[ -n "$record" && "$record" == *'|input|'* ]] || continue
      expression="$(firewall_rules_render_nft "$record")" || return "$EXIT_FAILURE"
      printf '    %s\n' "$expression"
    done <<<"$advanced_rules"
    printf '  }\n'
    printf '  chain output {\n'
    printf '    type filter hook output priority 0; policy accept;\n'
    printf '    ct state established,related accept\n'
    while IFS= read -r record; do
      [[ -n "$record" && "$record" == *'|output|'* ]] || continue
      expression="$(firewall_rules_render_nft "$record")" || return "$EXIT_FAILURE"
      printf '    %s\n' "$expression"
    done <<<"$advanced_rules"
    printf '  }\n'
    printf '}\n'
  } >"$destination"
}

show_firewall_summary() {
  local ssh_ports="$1"
  local tcp_ports="$2"
  local udp_ports="$3"
  printf '防火墙规则摘要\n'
  printf '地址族：IPv4 + IPv6（inet 双栈）\n'
  printf '入站策略：默认拒绝\n'
  printf '出站策略：默认允许\n'
  printf '保留 SSH TCP：%s\n' "$ssh_ports"
  printf '开放 TCP：%s\n' "${tcp_ports:-无额外端口}"
  printf '开放 UDP：%s\n' "${udp_ports:-无}"
  printf '已建立/相关连接、回环、ICMP 与 ICMPv6：允许\n'
  printf '受管范围：仅 table inet vps_guard；不创建 FORWARD 或 NAT 链\n'
  printf '最坏后果：SSH 连接中断，VPS 可能暂时失联。\n'
  printf '操作前确认云控制台、串行控制台或救援模式可用。\n'
}

validate_firewall_candidate() {
  local candidate="$1"
  local check_file status=0
  check_file="$(mktemp "${TMPDIR:-/tmp}/vps-guard-firewall-check.XXXXXX")" || return "$EXIT_FAILURE"
  # 已加载自有表时，单独检查新的 table 声明会误报 File exists；检查完整替换事务才能模拟真实应用。
  # `nft -c` 只校验不执行，因此这里的精确 delete 不会改变内核运行时。
  if nft list table inet vps_guard >/dev/null 2>&1; then
    printf 'delete table inet vps_guard\n' >"$check_file"
  else
    : >"$check_file"
  fi
  if ! cat "$candidate" >>"$check_file" || ! nft -c -f "$check_file"; then
    status="$EXIT_FAILURE"
  fi
  rm -f "$check_file" || true
  return "$status"
}

validate_rollback_minutes() {
  case "$1" in
    3 | 5 | 10) return 0 ;;
    *)
      error "回滚时间只允许 3、5 或 10 分钟"
      return "$EXIT_USAGE"
      ;;
  esac
}

firewall_validate_optional_rollback() {
  [[ "$1" == 0 ]] || validate_rollback_minutes "$1"
}

require_nft_command() {
  if ! command_exists nft; then
    error "缺少 nft 命令，请先安装 Debian/Ubuntu 官方 nftables 软件包"
    return "$EXIT_FAILURE"
  fi
}

ensure_firewall_scope_owned_or_free() {
  local state_path config_path nftables_conf include_line
  state_path="$(firewall_state_path)"
  config_path="$(firewall_config_path)"
  nftables_conf="${VPS_GUARD_FS_ROOT:-}/etc/nftables.conf"
  include_line="$(firewall_include_line)"

  # 名称相同不代表归本工具所有；只有 root-only 状态文件才是删除或替换自有范围的凭据。
  # 没有有效凭据时宁可阻断，也不能接管第三方恰好同名的表或配置。
  if [[ -e "$state_path" ]]; then
    if [[ -r "$state_path" && "$(firewall_state_value enabled)" == "1" ]]; then
      return 0
    fi
    error "发现无效的 VPS Guard 防火墙状态文件：$state_path"
    error "拒绝覆盖归属不明的防火墙范围"
    return "$EXIT_CONFLICT"
  fi

  if [[ -e "$config_path" ]]; then
    error "发现没有本工具状态记录的受管配置：$config_path"
    error "拒绝覆盖归属不明的防火墙范围"
    return "$EXIT_CONFLICT"
  fi
  if [[ -r "$nftables_conf" ]] && grep -Fqx "$include_line" "$nftables_conf"; then
    error "发现没有本工具状态记录的 nftables include"
    error "拒绝覆盖归属不明的防火墙范围"
    return "$EXIT_CONFLICT"
  fi
  if nft list table inet vps_guard >/dev/null 2>&1; then
    error "发现不属于本工具状态记录的 table inet vps_guard"
    error "拒绝覆盖同名第三方范围"
    return "$EXIT_CONFLICT"
  fi
}

ensure_no_pending_firewall_rollback() {
  local root state_file hook status token
  root="$(rollback_root)"
  [[ -d "$root" ]] || return 0
  for state_file in "$root"/*/state; do
    [[ -r "$state_file" ]] || continue
    hook="$(read_state_value "$state_file" hook | tail -1)"
    case "$hook" in
      firewall | ssh-firewall | ssh-restore | ssh-hardening | fail2ban | wizard-standard | wizard-firewall | wizard-fail2ban) ;;
      *) continue ;;
    esac
    status="$(read_state_value "$state_file" status | tail -1)"
    case "$status" in
      pending | running)
        token="$(read_state_value "$state_file" token | tail -1)"
        error "仍有等待确认的防火墙自动回滚：$token"
        error "请先验证并确认，或等待其完成后再修改防火墙"
        return "$EXIT_CONFLICT"
        ;;
    esac
  done
}

firewall_include_line() {
  printf 'include "/etc/nftables.d/vps-guard.nft" # vps-guard\n'
}

ensure_firewall_include_line() {
  local nftables_conf include_line
  nftables_conf="${VPS_GUARD_FS_ROOT:-}/etc/nftables.conf"
  include_line="$(firewall_include_line)"
  if [[ ! -e "$nftables_conf" ]]; then
    mkdir -p "$(dirname "$nftables_conf")" || return "$EXIT_FAILURE"
    printf '#!/usr/sbin/nft -f\n' >"$nftables_conf" || return "$EXIT_FAILURE"
  fi
  if ! grep -Fqx "$include_line" "$nftables_conf"; then
    printf '\n%s\n' "$include_line" >>"$nftables_conf" || return "$EXIT_FAILURE"
  fi
}

remove_firewall_include_line() {
  local nftables_conf include_line temp mode
  nftables_conf="${VPS_GUARD_FS_ROOT:-}/etc/nftables.conf"
  include_line="$(firewall_include_line)"
  [[ -e "$nftables_conf" ]] || return 0
  temp="$(dirname "$nftables_conf")/.vps-guard-nftables.$$.tmp"
  mode="$(file_mode "$nftables_conf")" || return "$EXIT_FAILURE"
  if ! awk -v include_line="$include_line" '$0 != include_line { print }' "$nftables_conf" >"$temp" ||
    ! chmod "$mode" "$temp" || ! mv "$temp" "$nftables_conf"; then
    rm -f "$temp" || true
    return "$EXIT_FAILURE"
  fi
}

reconcile_firewall_include_line() {
  if [[ -r "$(firewall_state_path)" && "$(firewall_state_value enabled)" == "1" &&
  -r "$(firewall_config_path)" ]]; then
    ensure_firewall_include_line
  else
    remove_firewall_include_line
  fi
}

install_firewall_configuration() {
  local candidate="$1"
  local ssh_ports="$2"
  local tcp_ports="$3"
  local udp_ports="$4"
  local advanced_rules="${5:-}" record
  local config_path state_path
  config_path="$(firewall_config_path)"
  state_path="$(firewall_state_path)"

  umask 077
  mkdir -p "$(dirname "$config_path")" "$(dirname "$state_path")" || return "$EXIT_FAILURE"
  chmod 0700 "$(dirname "$state_path")" || return "$EXIT_FAILURE"
  cp "$candidate" "$config_path" || return "$EXIT_FAILURE"
  chmod 0600 "$config_path" || return "$EXIT_FAILURE"
  if ! printf 'format=2\nenabled=1\nssh_ports=%s\ntcp_ports=%s\nudp_ports=%s\n' \
    "$ssh_ports" "$tcp_ports" "$udp_ports" >"$state_path"; then
    return "$EXIT_FAILURE"
  fi
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    printf 'rule=%s\n' "$record" >>"$state_path" || return "$EXIT_FAILURE"
  done <<<"$advanced_rules"
  chmod 0600 "$state_path" || return "$EXIT_FAILURE"

  ensure_firewall_include_line
}

apply_managed_firewall_ssh_ports() {
  local ssh_ports="$1"
  local tcp_ports udp_ports advanced_rules candidate
  require_firewall_enabled || return $?
  ssh_ports="$(normalize_basic_ports "$ssh_ports")" || return $?
  [[ -n "$ssh_ports" ]] || return "$EXIT_USAGE"
  tcp_ports="$(firewall_state_value tcp_ports)"
  udp_ports="$(firewall_state_value udp_ports)"
  advanced_rules="$(firewall_advanced_state_records)" || return $?
  candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-firewall-ssh.XXXXXX")" || return "$EXIT_FAILURE"
  if ! render_firewall_ruleset "$candidate" "$ssh_ports" "$tcp_ports" "$udp_ports" "$advanced_rules" ||
    ! validate_firewall_candidate "$candidate" ||
    ! install_firewall_configuration "$candidate" "$ssh_ports" "$tcp_ports" "$udp_ports" "$advanced_rules" ||
    ! reload_firewall_runtime; then
    rm -f "$candidate" || true
    return "$EXIT_FAILURE"
  fi
  rm -f "$candidate" || true
}

reload_firewall_runtime() {
  local config_path
  config_path="$(firewall_config_path)"
  # Debian 12 不支持较新的 destroy 语法；所有权检查完成后，只删除并重载这一张自有表。
  if nft list table inet vps_guard >/dev/null 2>&1; then
    nft delete table inet vps_guard || return "$EXIT_FAILURE"
  fi
  if [[ -r "$config_path" ]]; then
    nft -f "$config_path"
    return $?
  fi
  return 0
}

restore_firewall_snapshot() {
  local snapshot_id="$1"
  restore_snapshot "$snapshot_id" 1 && reload_firewall_runtime
}

recover_failed_firewall_change() {
  local snapshot_id="$1" rollback_token="${2:-}"
  if restore_firewall_snapshot "$snapshot_id"; then
    if [[ -n "$rollback_token" ]]; then
      confirm_rollback "$rollback_token" 1 >/dev/null 2>&1 || {
        error "防火墙已恢复，但无法取消自动回滚；任务仍保留"
        return "$EXIT_FAILURE"
      }
    fi
    return 0
  fi
  if [[ -n "$rollback_token" ]]; then
    error "防火墙立即恢复失败；自动回滚任务仍保留，请勿确认"
  else
    error "防火墙立即恢复失败，请从控制台恢复快照：$snapshot_id"
  fi
  return "$EXIT_FAILURE"
}

remove_firewall_configuration() {
  remove_firewall_include_line || return $?
  rm -f "$(firewall_config_path)" "$(firewall_state_path)"
}

disable_firewall() {
  with_config_transaction_lock disable_firewall_unlocked "$@"
}

disable_firewall_unlocked() {
  local rollback_minutes="$1"
  local confirmed="$2"
  local cleanup snapshot_output snapshot_id rollback_output="" rollback_token="" runtime_table_present=0

  firewall_validate_optional_rollback "$rollback_minutes" || return $?
  if ! require_firewall_enabled 2>/dev/null; then
    printf 'VPS Guard 防火墙已经停用，无需重复操作。\n'
    return 0
  fi
  require_nft_command || return $?
  ensure_firewall_scope_owned_or_free || return $?
  ensure_no_pending_firewall_rollback || return $?
  ensure_no_pending_ssh_enrollment || return $?
  require_firewall_write_preflight || return $?

  cleanup="$(mktemp "${TMPDIR:-/tmp}/vps-guard-firewall-disable.XXXXXX")" || return "$EXIT_FAILURE"
  if nft list table inet vps_guard >/dev/null 2>&1; then
    printf 'delete table inet vps_guard\n' >"$cleanup"
    runtime_table_present=1
  else
    : >"$cleanup"
  fi
  printf '防火墙停用摘要\n'
  if [[ "$runtime_table_present" -eq 1 ]]; then
    printf '将删除：table inet vps_guard、受管配置和精确 include 行\n'
  else
    printf '运行时 table inet vps_guard 已不存在；将删除受管配置和精确 include 行\n'
  fi
  printf '保留：所有第三方 nftables 表、FORWARD、NAT、容器链和 VPN 配置\n'
  printf '警告：所有端口将由其他防火墙和上游网络策略决定。\n'
  printf '最坏后果：原本受拦截的服务可能暴露到公网。\n'
  printf '操作前确认云控制台、串行控制台或救援模式可用。\n'
  if ! nft -c -f "$cleanup"; then
    rm -f "$cleanup" || true
    error "nftables 停用语法检查失败，未写入任何配置"
    return "$EXIT_FAILURE"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$cleanup" || true
    printf 'dry-run：不会删除规则或启动自动回滚。\n'
    return 0
  fi
  if [[ "$confirmed" -ne 1 ]]; then
    printf '确认停用防火墙？[y/N] '
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        rm -f "$cleanup" || true
        printf '已取消，未停用防火墙。\n'
        return 0
        ;;
    esac
  fi

  if ! snapshot_output="$(create_snapshot firewall-before-disable)"; then
    rm -f "$cleanup" || true
    error "创建防火墙快照失败，未停用规则"
    return "$EXIT_FAILURE"
  fi
  printf '%s\n' "$snapshot_output"
  snapshot_id="${snapshot_output#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"
  if ! remove_firewall_configuration; then
    rm -f "$cleanup" || true
    recover_failed_firewall_change "$snapshot_id" || true
    audit_event firewall.disable failure "snapshot=$snapshot_id reason=apply"
    error "防火墙停用失败，已尝试恢复快照"
    return "$EXIT_FAILURE"
  fi
  if [[ "$rollback_minutes" != 0 ]]; then
    if ! rollback_output="$(start_rollback "$snapshot_id" "$rollback_minutes" firewall)"; then
      rm -f "$cleanup" || true
      recover_failed_firewall_change "$snapshot_id" || true
      audit_event firewall.disable failure "snapshot=$snapshot_id reason=rollback-schedule"
      error "无法安排自动回滚，已尝试恢复原防火墙"
      return "$EXIT_FAILURE"
    fi
    printf '%s\n' "$rollback_output"
    rollback_token="${rollback_output#*自动回滚已启动：}"
    rollback_token="${rollback_token%%$'\n'*}"
  fi
  if ! nft -f "$cleanup"; then
    rm -f "$cleanup" || true
    recover_failed_firewall_change "$snapshot_id" "$rollback_token" || true
    audit_event firewall.disable failure "snapshot=$snapshot_id reason=runtime-apply"
    error "防火墙停用失败，已尝试恢复快照"
    return "$EXIT_FAILURE"
  fi
  rm -f "$cleanup" || true
  audit_event firewall.disable success "snapshot=$snapshot_id minutes=$rollback_minutes"
  printf 'VPS Guard 防火墙已停用。所有端口将由其他防火墙和上游网络策略决定。\n'
}

enable_firewall() {
  with_config_transaction_lock enable_firewall_unlocked "$@"
}

enable_firewall_unlocked() {
  local tcp_input="$1"
  local udp_input="$2"
  local rollback_minutes="$3"
  local confirmed="$4"
  local operation="${5:-enable}"
  local advanced_rules="${6:-}"
  local tcp_ports udp_ports ssh_ports candidate snapshot_output snapshot_id rollback_output="" rollback_token="" note

  firewall_validate_optional_rollback "$rollback_minutes" || return $?
  if ! tcp_ports="$(normalize_basic_ports "$tcp_input")"; then
    error "TCP 端口支持 1-65535 的单端口、列表、范围或混合格式"
    return "$EXIT_USAGE"
  fi
  if ! udp_ports="$(normalize_basic_ports "$udp_input")"; then
    error "UDP 端口支持 1-65535 的单端口、列表、范围或混合格式"
    return "$EXIT_USAGE"
  fi
  require_nft_command || return $?
  ensure_firewall_scope_owned_or_free || return $?
  ensure_no_pending_firewall_rollback || return $?
  ensure_no_pending_ssh_enrollment || return $?
  require_firewall_write_preflight || return $?
  ssh_ports="$(current_ssh_ports)" || return $?
  candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-firewall.XXXXXX")" || return "$EXIT_FAILURE"
  if ! render_firewall_ruleset "$candidate" "$ssh_ports" "$tcp_ports" "$udp_ports" "$advanced_rules"; then
    rm -f "$candidate" || true
    error "无法生成 nftables 候选配置"
    return "$EXIT_FAILURE"
  fi

  show_firewall_summary "$ssh_ports" "$tcp_ports" "$udp_ports"
  if [[ -n "$tcp_input" ]]; then
    note="$(firewall_rules_port_normalization_note "$tcp_input")" || return $?
    [[ -z "$note" ]] || printf 'TCP %s' "$note"
  fi
  if [[ -n "$udp_input" ]]; then
    note="$(firewall_rules_port_normalization_note "$udp_input")" || return $?
    [[ -z "$note" ]] || printf 'UDP %s' "$note"
  fi
  if ! validate_firewall_candidate "$candidate"; then
    rm -f "$candidate" || true
    error "nftables 语法检查失败，未写入任何配置"
    return "$EXIT_FAILURE"
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$candidate" || true
    printf 'dry-run：不会写入配置或启动自动回滚。\n'
    return 0
  fi

  if [[ "$confirmed" -ne 1 ]]; then
    printf '警告：本操作会重载入站规则。确认按上述摘要写入？[y/N] '
    IFS= read -r answer
    case "$answer" in
      y | Y | yes | YES) ;;
      *)
        rm -f "$candidate" || true
        printf '已取消，未写入防火墙。\n'
        return 0
        ;;
    esac
  fi

  if ! snapshot_output="$(create_snapshot "firewall-before-$operation")"; then
    rm -f "$candidate" || true
    error "创建防火墙快照失败，未写入规则"
    return "$EXIT_FAILURE"
  fi
  printf '%s\n' "$snapshot_output"
  snapshot_id="${snapshot_output#*快照已创建：}"
  snapshot_id="${snapshot_id%%$'\n'*}"

  if ! install_firewall_configuration "$candidate" "$ssh_ports" "$tcp_ports" "$udp_ports" "$advanced_rules"; then
    rm -f "$candidate" || true
    recover_failed_firewall_change "$snapshot_id" || true
    audit_event "firewall.$operation" failure "snapshot=$snapshot_id reason=apply"
    error "防火墙应用失败，已尝试恢复快照"
    return "$EXIT_FAILURE"
  fi
  rm -f "$candidate" || true

  if [[ "$rollback_minutes" != 0 ]]; then
    if ! rollback_output="$(start_rollback "$snapshot_id" "$rollback_minutes" firewall)"; then
      recover_failed_firewall_change "$snapshot_id" || true
      audit_event "firewall.$operation" failure "snapshot=$snapshot_id reason=rollback-schedule"
      error "无法安排自动回滚，已尝试恢复原防火墙"
      return "$EXIT_FAILURE"
    fi
    printf '%s\n' "$rollback_output"
    rollback_token="${rollback_output#*自动回滚已启动：}"
    rollback_token="${rollback_token%%$'\n'*}"
  fi
  if ! reload_firewall_runtime; then
    recover_failed_firewall_change "$snapshot_id" "$rollback_token" || true
    audit_event "firewall.$operation" failure "snapshot=$snapshot_id reason=runtime-apply"
    error "防火墙应用失败，已尝试恢复快照"
    return "$EXIT_FAILURE"
  fi
  audit_event "firewall.$operation" success "snapshot=$snapshot_id minutes=$rollback_minutes"
  case "$operation" in
    enable) printf '防火墙已启用。' ;;
    open) printf '端口放行规则已更新。' ;;
    close) printf '端口放行规则已关闭。' ;;
  esac
  if [[ "$rollback_minutes" != 0 ]]; then
    printf '请从新 SSH 会话验证端口 %s 和业务服务，确认正常后执行 rollback confirm。\n' "$ssh_ports"
  else
    printf '请从新 SSH 会话验证端口 %s 和业务服务。\n' "$ssh_ports"
  fi
}

change_firewall_ports() {
  local mode="$1"
  local ports_input="$2"
  local protocol="$3"
  local rollback_minutes="$4"
  local confirmed="$5"
  local ports tcp_ports udp_ports new_tcp new_udp advanced_rules note

  require_firewall_enabled || return $?
  if ! ports="$(normalize_basic_ports "$ports_input")" || [[ -z "$ports" ]]; then
    error "端口支持 1-65535 的单端口、列表、范围或混合格式"
    return "$EXIT_USAGE"
  fi
  case "$protocol" in
    tcp | udp | both) ;;
    *)
      error "协议只允许 tcp、udp 或 both"
      return "$EXIT_USAGE"
      ;;
  esac
  tcp_ports="$(firewall_state_value tcp_ports)"
  udp_ports="$(firewall_state_value udp_ports)"
  advanced_rules="$(firewall_advanced_state_records)" || return $?
  note="$(firewall_rules_port_normalization_note "$ports_input")" || return $?
  [[ -z "$note" ]] || printf '%s' "$note"
  new_tcp="$tcp_ports"
  new_udp="$udp_ports"

  if [[ "$mode" == "open" ]]; then
    if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
      new_tcp="$(merge_basic_ports "$tcp_ports" "$ports")"
    fi
    if [[ "$protocol" == "udp" || "$protocol" == "both" ]]; then
      new_udp="$(merge_basic_ports "$udp_ports" "$ports")"
    fi
    if [[ "$new_tcp" == "$tcp_ports" && "$new_udp" == "$udp_ports" ]]; then
      printf '指定端口已经开放，无需重复操作。\n'
      return 0
    fi
  else
    if [[ "$protocol" == "tcp" || "$protocol" == "both" ]]; then
      new_tcp="$(remove_basic_ports "$tcp_ports" "$ports")"
    fi
    if [[ "$protocol" == "udp" || "$protocol" == "both" ]]; then
      new_udp="$(remove_basic_ports "$udp_ports" "$ports")"
    fi
    if [[ "$new_tcp" == "$tcp_ports" && "$new_udp" == "$udp_ports" ]]; then
      printf '指定端口已经关闭，无需重复操作。\n'
      warn_if_firewall_ports_listening "$ports" "$protocol"
      return 0
    fi
  fi

  enable_firewall "$new_tcp" "$new_udp" "$rollback_minutes" "$confirmed" "$mode" "$advanced_rules" || return $?
  if [[ "$mode" == close && "$(firewall_state_value tcp_ports)" == "$new_tcp" &&
  "$(firewall_state_value udp_ports)" == "$new_udp" ]]; then
    warn_if_firewall_ports_listening "$ports" "$protocol"
  fi
}

show_firewall_status() {
  local state_path ssh_ports tcp_ports udp_ports advanced_rules listeners
  state_path="$(firewall_state_path)"
  require_nft_command || return $?
  printf 'VPS Guard 防火墙状态\n'
  if [[ ! -r "$state_path" || "$(firewall_state_value enabled)" != "1" ]]; then
    printf '磁盘配置：未启用\n'
    if nft list table inet vps_guard >/dev/null 2>&1; then
      printf '内核运行时：发现孤立的 table inet vps_guard，请先检查再处理。\n'
      return "$EXIT_FAILURE"
    fi
    printf '内核运行时：未加载\n'
    if command_exists ss && listeners="$(firewall_listener_lines 2>/dev/null)"; then
      [[ -n "$listeners" ]] && printf '本机监听进程：\n%s\n' "$listeners" || printf '本机监听进程：未发现\n'
    else
      printf '本机监听进程：未知（ss 状态不可读）\n'
    fi
    printf '外部可达性：未验证（仍受云安全组、NAT 和上游防火墙影响）\n'
    return 0
  fi

  ssh_ports="$(firewall_state_value ssh_ports)"
  tcp_ports="$(firewall_state_value tcp_ports)"
  udp_ports="$(firewall_state_value udp_ports)"
  printf '磁盘配置：已启用\n'
  if nft list table inet vps_guard >/dev/null 2>&1; then
    printf '内核运行时：已加载 table inet vps_guard\n'
  else
    printf '内核运行时：未加载，与磁盘配置不一致\n'
    return "$EXIT_FAILURE"
  fi
  printf '受保护 SSH TCP：%s\n' "$ssh_ports"
  printf '额外 TCP：%s\n' "${tcp_ports:-无}"
  printf '额外 UDP：%s\n' "${udp_ports:-无}"
  advanced_rules="$(firewall_advanced_valid_records)" || return $?
  if [[ -n "$advanced_rules" ]]; then
    printf '高级规则（动作|方向|协议|地址族|端口|来源|接口）：\n%s\n' "$advanced_rules"
  else
    printf '高级规则：无\n'
  fi
  if ! command_exists ss; then
    printf '本机监听进程：未知（缺少 ss）\n'
  elif ! listeners="$(firewall_listener_lines 2>/dev/null)"; then
    printf '本机监听进程：未知（ss 状态不可读）\n'
  elif [[ -n "$listeners" ]]; then
    printf '本机监听进程：\n%s\n' "$listeners"
  else
    printf '本机监听进程：未发现\n'
  fi
  printf '外部可达性：未验证（仍受云安全组、NAT 和上游防火墙影响）\n'
}

firewall_cli() {
  local action="${1:-}"
  local tcp_ports="" udp_ports="" ports="" protocol="" rollback_minutes=0 confirmed=0
  local direction=inbound family=dual source=all interface="" external=unverified advanced=0
  case "$action" in
    enable)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --tcp)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            tcp_ports="$2"
            shift 2
            ;;
          --udp)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            udp_ports="$2"
            shift 2
            ;;
          --rollback-minutes)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            rollback_minutes="$2"
            shift 2
            ;;
          --yes)
            confirmed=1
            shift
            ;;
          *)
            error "firewall enable 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      enable_firewall "$tcp_ports" "$udp_ports" "$rollback_minutes" "$confirmed"
      ;;
    open | close)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --ports)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            ports="$2"
            shift 2
            ;;
          --protocol)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            protocol="$2"
            shift 2
            ;;
          --direction)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            direction="$2"
            advanced=1
            shift 2
            ;;
          --family)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            family="$2"
            advanced=1
            shift 2
            ;;
          --source)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            source="$2"
            advanced=1
            shift 2
            ;;
          --interface)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            interface="$2"
            advanced=1
            shift 2
            ;;
          --rollback-minutes)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            rollback_minutes="$2"
            shift 2
            ;;
          --yes)
            confirmed=1
            shift
            ;;
          *)
            error "firewall $action 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      [[ -n "$ports" && -n "$protocol" ]] || {
        error "用法：vps-guard firewall $action --ports 列表 --protocol tcp|udp|both"
        return "$EXIT_USAGE"
      }
      if [[ "$advanced" -eq 1 || "$direction" == outbound ]]; then
        change_advanced_firewall_rule "$action" "$ports" "$protocol" "$direction" "$family" "$source" "$interface" "$rollback_minutes" "$confirmed"
      else
        change_firewall_ports "$action" "$ports" "$protocol" "$rollback_minutes" "$confirmed"
      fi
      ;;
    disable)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --rollback-minutes)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            rollback_minutes="$2"
            shift 2
            ;;
          --yes)
            confirmed=1
            shift
            ;;
          *)
            error "firewall disable 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      disable_firewall "$rollback_minutes" "$confirmed"
      ;;
    status)
      shift
      if [[ "$#" -eq 0 ]]; then
        show_firewall_status
        return $?
      fi
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --ports)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            ports="$2"
            shift 2
            ;;
          --protocol)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            protocol="$2"
            shift 2
            ;;
          --direction)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            direction="$2"
            shift 2
            ;;
          --family)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            family="$2"
            shift 2
            ;;
          --source)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            source="$2"
            shift 2
            ;;
          --interface)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            interface="$2"
            shift 2
            ;;
          --external-confirm)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            external="$2"
            shift 2
            ;;
          *)
            error "firewall status 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      [[ -n "$ports" && -n "$protocol" ]] || {
        error "过滤状态必须指定 --ports 与 --protocol"
        return "$EXIT_USAGE"
      }
      case "$protocol" in tcp | udp | both) ;; *) return "$EXIT_USAGE" ;; esac
      case "$direction" in inbound | outbound) ;; *) return "$EXIT_USAGE" ;; esac
      case "$family" in ipv4 | ipv6 | dual) ;; *) return "$EXIT_USAGE" ;; esac
      case "$external" in unverified | reachable | blocked) ;; *) return "$EXIT_USAGE" ;; esac
      show_firewall_port_status "$ports" "$protocol" "$direction" "$family" "$source" "$interface" "$external"
      ;;
    *)
      error "用法：vps-guard firewall <enable|disable|open|close|status>"
      return "$EXIT_USAGE"
      ;;
  esac
}
