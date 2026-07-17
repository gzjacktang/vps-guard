#!/usr/bin/env bash

# 高级规则集成层：把用户维度转换为经过校验的原子规则，状态仍由 firewall.sh 事务化写入。

firewall_advanced_valid_records() {
  local record expanded
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    expanded="$(firewall_rules_expand_atomic "$record")" || {
      error "防火墙状态包含无效高级规则"
      return "$EXIT_CONFLICT"
    }
    [[ "$expanded" != *$'\n'* && "$expanded" == "$record" ]] || {
      error "防火墙状态包含未原子化规则"
      return "$EXIT_CONFLICT"
    }
    printf '%s\n' "$record"
  done < <(firewall_advanced_state_records)
}

firewall_advanced_same_selector() {
  local left="$1" right="$2"
  local la ld lp lf _lports ls li ra rd rp rf _rports rs ri
  IFS='|' read -r la ld lp lf _lports ls li <<<"$left"
  IFS='|' read -r ra rd rp rf _rports rs ri <<<"$right"
  [[ "$la|$ld|$lp|$lf|$ls|$li" == "$ra|$rd|$rp|$rf|$rs|$ri" ]]
}

firewall_advanced_target_covers_existing_selector() {
  local existing="$1" target="$2"
  local _ea _ed _ep _ef _eports es ei _ta _td _tp _tf _tports ts ti
  IFS='|' read -r _ea _ed _ep _ef _eports es ei <<<"$existing"
  IFS='|' read -r _ta _td _tp _tf _tports ts ti <<<"$target"
  [[ "$_ea|$_ed|$_ep|$_ef" == "$_ta|$_td|$_tp|$_tf" ]] || return 1
  firewall_rules_source_contains "$ts" "$es" && [[ "$ti" == "*" || "$ti" == "$ei" ]]
}

firewall_advanced_update_records() {
  local operation="$1" targets="$2" record target ports target_ports merged difference existing_text
  local records=("") next=("")
  existing_text="$(firewall_advanced_valid_records)" || return $?
  while IFS= read -r record; do
    [[ -n "$record" ]] || continue
    records+=("$record")
  done <<<"$existing_text"

  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    target_ports="$(printf '%s' "$target" | cut -d'|' -f5)"
    next=("")
    merged="$target_ports"
    for record in "${records[@]}"; do
      [[ -n "$record" ]] || continue
      if firewall_advanced_same_selector "$record" "$target" ||
        { [[ "$operation" == remove ]] && firewall_advanced_target_covers_existing_selector "$record" "$target"; }; then
        ports="$(printf '%s' "$record" | cut -d'|' -f5)"
        if [[ "$operation" == add ]]; then
          merged="$(firewall_rules_normalize_ports "$merged,$ports")" || return $?
        else
          difference="$(firewall_rules_interval_difference "$ports" "$target_ports")" || return $?
          if [[ -n "$difference" ]]; then
            next+=("$(printf '%s' "$record" | awk -F'|' -v p="$difference" 'BEGIN { OFS="|" } { $5=p; print }')")
          fi
        fi
      else
        next+=("$record")
      fi
    done
    if [[ "$operation" == add ]]; then
      next+=("$(printf '%s' "$target" | awk -F'|' -v p="$merged" 'BEGIN { OFS="|" } { $5=p; print }')")
    fi
    records=("${next[@]}")
  done <<<"$targets"

  for record in "${records[@]}"; do
    [[ -n "$record" ]] || continue
    printf '%s\n' "$record"
  done | sort -u
}

firewall_advanced_conflict_summary() {
  local targets="$1" existing target ea ed ep ef eports es ei ta td tp tf tports ts ti
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    IFS='|' read -r ta td tp tf tports ts ti <<<"$target"
    while IFS= read -r existing; do
      [[ -n "$existing" ]] || continue
      IFS='|' read -r ea ed ep ef eports es ei <<<"$existing"
      if [[ "$ed|$ep|$ef" == "$td|$tp|$tf" && "$ea" != "$ta" ]] &&
        firewall_rules_sources_overlap "$es" "$ts" &&
        [[ "$ei" == "*" || "$ti" == "*" || "$ei" == "$ti" ]] &&
        firewall_rules_intervals_overlap "$eports" "$tports"; then
        printf '潜在冲突：现有 %s 规则与目标 %s 规则端口重叠；nftables 按生成顺序裁决。\n' "$ea" "$ta"
      fi
    done < <(firewall_advanced_valid_records)
  done <<<"$targets"
}

firewall_advanced_coverage_summary() {
  local targets="$1" target existing ta td tp tf tports ts ti ea ed ep ef eports es ei basic
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    IFS='|' read -r ta td tp tf tports ts ti <<<"$target"
    if [[ "$td" == input && "$ta" == accept ]]; then
      if [[ "$tp" == tcp ]]; then
        basic="$(merge_basic_ports "$(firewall_state_value ssh_ports)" "$(firewall_state_value tcp_ports)")"
      else
        basic="$(firewall_state_value udp_ports)"
      fi
      if [[ -n "$basic" ]] && firewall_rules_intervals_overlap "$basic" "$tports"; then
        printf '潜在覆盖：基础双栈全来源规则仍允许部分目标端口；更窄来源/接口规则不会收紧它。\n'
      fi
    fi
    while IFS= read -r existing; do
      [[ -n "$existing" ]] || continue
      IFS='|' read -r ea ed ep ef eports es ei <<<"$existing"
      [[ "$ea|$ed|$ep|$ef" == "$ta|$td|$tp|$tf" ]] || continue
      firewall_rules_intervals_overlap "$eports" "$tports" || continue
      if firewall_rules_source_contains "$es" "$ts" &&
        [[ "$ei" == "*" || "$ei" == "$ti" ]] && [[ "$es|$ei" != "$ts|$ti" ]]; then
        printf '潜在覆盖：现有更宽来源或接口规则仍匹配部分目标端口。\n'
      fi
    done < <(firewall_advanced_valid_records)
  done <<<"$targets"
}

firewall_advanced_input_close_blocked() {
  local targets="$1" existing_records target existing _ta td tp tf tports ts ti ea ed ep ef eports es ei basic
  existing_records="$(firewall_advanced_valid_records)" || return $?
  while IFS= read -r target; do
    [[ -n "$target" ]] || continue
    IFS='|' read -r _ta td tp tf tports ts ti <<<"$target"
    [[ "$td" == input ]] || continue
    if [[ "$tp" == tcp ]]; then
      basic="$(merge_basic_ports "$(firewall_state_value ssh_ports)" "$(firewall_state_value tcp_ports)")"
    else
      basic="$(firewall_state_value udp_ports)"
    fi
    if [[ -n "$basic" ]] && firewall_rules_intervals_overlap "$basic" "$tports"; then
      error "更宽的基础双栈全来源规则仍放行目标端口；请先用基础 close 撤销它"
      return "$EXIT_CONFLICT"
    fi
    while IFS= read -r existing; do
      [[ -n "$existing" ]] || continue
      IFS='|' read -r ea ed ep ef eports es ei <<<"$existing"
      [[ "$ea|$ed|$ep|$ef" == "accept|$td|$tp|$tf" ]] || continue
      firewall_advanced_same_selector "$existing" "$target" && continue
      firewall_rules_intervals_overlap "$eports" "$tports" || continue
      if firewall_rules_source_contains "$es" "$ts" && [[ "$ei" == "*" || "$ei" == "$ti" ]]; then
        error "现有更宽来源或接口规则仍放行目标端口；拒绝报告为已关闭"
        return "$EXIT_CONFLICT"
      fi
    done <<<"$existing_records"
  done <<<"$targets"
}

change_advanced_firewall_rule() {
  local mode="$1" ports_input="$2" protocol="$3" direction="$4" family="$5" source="$6" interface="$7"
  local rollback_minutes="$8" confirmed="$9" ports note nft_direction action set_operation target targets before after
  local tcp_ports udp_ports source_family
  require_firewall_enabled || return $?
  ports="$(firewall_rules_normalize_ports "$ports_input")" || {
    error "端口必须是 1-65535 的单值、列表、范围或混合格式"
    return "$EXIT_USAGE"
  }
  if ! firewall_rules_validate_protocol "$protocol" || [[ "$protocol" == all ]]; then
    error "协议只允许 tcp、udp 或 both"
    return "$EXIT_USAGE"
  fi
  case "$direction" in inbound) nft_direction=input ;; outbound) nft_direction=output ;; *)
    error "方向只允许 inbound 或 outbound"
    return "$EXIT_USAGE"
    ;;
  esac
  firewall_rules_validate_family "$family" || {
    error "地址族只允许 ipv4、ipv6 或 dual"
    return "$EXIT_USAGE"
  }
  [[ "$source" != all ]] || source="*"
  firewall_rules_validate_source "$source" || {
    error "来源必须是 all、IPv4/IPv6 地址或 CIDR"
    return "$EXIT_USAGE"
  }
  interface="${interface:-*}"
  firewall_rules_validate_interface "$interface" || {
    error "接口名称无效"
    return "$EXIT_USAGE"
  }
  source_family="$(firewall_rules_source_family "$source")" || return $?
  if [[ "$family" == dual && "$source_family" != dual ]]; then
    error "指定单一家族来源时必须明确选择 ipv4 或 ipv6，不能使用 dual"
    return "$EXIT_USAGE"
  fi
  [[ "$source_family" == dual || "$source_family" == "$family" ]] || {
    error "来源地址与所选地址族不匹配"
    return "$EXIT_USAGE"
  }

  if [[ "$nft_direction" == input ]]; then
    action=accept
    [[ "$mode" == open ]] && set_operation=add || set_operation=remove
  else
    action=drop
    [[ "$mode" == close ]] && set_operation=add || set_operation=remove
  fi
  target="$action|$nft_direction|$protocol|$family|$ports|$source|$interface"
  targets="$(firewall_rules_expand_atomic "$target")" || return $?
  if [[ "$nft_direction" == input && "$mode" == close ]]; then
    firewall_advanced_input_close_blocked "$targets" || return $?
  fi
  before="$(firewall_advanced_valid_records)" || return $?
  after="$(firewall_advanced_update_records "$set_operation" "$targets")" || return $?

  printf '高级端口规则摘要\n'
  printf '操作：%s\n方向：%s\n协议：%s\n地址族：%s\n规范化端口：%s\n来源：%s\n接口：%s\n' \
    "$mode" "$direction" "$protocol" "$family" "$ports" "${source/\*/all}" "${interface/\*/all}"
  note="$(firewall_rules_port_normalization_note "$ports_input")" || return $?
  [[ -z "$note" ]] || printf '%s' "$note"
  firewall_advanced_conflict_summary "$targets"
  firewall_advanced_coverage_summary "$targets"
  if [[ "$nft_direction" == output ]]; then
    printf '高级风险警告：出站限制可能中断 DNS、APT/HTTPS、NTP、邮件、监控和业务回连。\n'
    printf '已建立/相关连接会暂时保留；本规则主要影响新连接。\n'
  fi

  if [[ "$before" == "$after" ]]; then
    if [[ "$mode" == open ]]; then
      printf '匹配规则已经开放，无需重复操作。\n'
    else
      printf '匹配规则已经关闭，无需重复操作。\n'
      warn_if_firewall_ports_listening "$ports" "$protocol"
    fi
    return 0
  fi

  tcp_ports="$(firewall_state_value tcp_ports)"
  udp_ports="$(firewall_state_value udp_ports)"
  enable_firewall "$tcp_ports" "$udp_ports" "$rollback_minutes" "$confirmed" "$mode" "$after" || return $?
  if [[ "$mode" == close && "$(firewall_advanced_valid_records)" == "$after" ]]; then
    warn_if_firewall_ports_listening "$ports" "$protocol"
  fi
}

firewall_listener_lines() {
  command_exists ss || return "$EXIT_FAILURE"
  ss -H -lntup 2>/dev/null
}

firewall_listener_matches() {
  local ports="$1" protocol="$2" family="${3:-dual}" lines line netid _state _recvq _sendq local_address _peer _rest local_port listener_family
  lines="$(firewall_listener_lines)" || return "$EXIT_FAILURE"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r netid _state _recvq _sendq local_address _peer _rest <<<"$line"
    case "$protocol:$netid" in tcp:tcp* | udp:udp* | both:tcp* | both:udp*) ;; *) continue ;; esac
    if [[ "$local_address" == *'['* || "$local_address" == *:*:* ]]; then
      listener_family=ipv6
    else
      listener_family=ipv4
    fi
    [[ "$family" == dual || "$family" == "$listener_family" ]] || continue
    local_port="${local_address##*:}"
    local_port="${local_port//]/}"
    [[ "$local_port" =~ ^[0-9]+$ ]] || continue
    firewall_rules_intervals_overlap "$ports" "$local_port" || continue
    printf '%s\n' "$line"
  done <<<"$lines"
}

warn_if_firewall_ports_listening() {
  local ports="$1" protocol="$2" matches
  if ! command_exists ss; then
    printf '本机监听：未知（缺少 ss）\n'
    return 0
  fi
  if ! matches="$(firewall_listener_matches "$ports" "$protocol" 2>/dev/null)"; then
    printf '本机监听：未知（ss 状态不可读）\n'
    return 0
  fi
  if [[ -n "$matches" ]]; then
    printf '警告：防火墙规则已关闭或未放行，但服务仍在本机监听：\n%s\n' "$matches"
  fi
}

firewall_rule_status_for_query() {
  local ports="$1" protocol="$2" direction="$3" family="$4" source="$5" interface="$6"
  local ssh_ports tcp_ports udp_ports records record action rd rp rf rports rs ri item_protocol item_family
  local allow_coverage drop_coverage remaining basic selector_any selector_full
  local total=0 allow_full=0 drop_full=0 allow_any=0 drop_any=0
  local protocols=("$protocol") families=("$family")
  [[ "$protocol" != both ]] || protocols=(tcp udp)
  [[ "$family" != dual ]] || families=(ipv4 ipv6)
  records="$(firewall_advanced_valid_records)" || return $?
  ssh_ports="$(firewall_state_value ssh_ports)"
  tcp_ports="$(firewall_state_value tcp_ports)"
  udp_ports="$(firewall_state_value udp_ports)"

  for item_protocol in "${protocols[@]}"; do
    for item_family in "${families[@]}"; do
      total=$((total + 1))
      allow_coverage=""
      drop_coverage=""
      if [[ "$direction" == input ]]; then
        if [[ "$item_protocol" == tcp ]]; then
          basic="$(merge_basic_ports "$ssh_ports" "$tcp_ports")"
        else
          basic="$udp_ports"
        fi
        if [[ -n "$basic" ]]; then
          allow_coverage="$basic"
          if firewall_rules_intervals_overlap "$ports" "$basic"; then
            allow_any=1
          fi
        fi
      fi
      while IFS= read -r record; do
        [[ -n "$record" ]] || continue
        IFS='|' read -r action rd rp rf rports rs ri <<<"$record"
        [[ "$rd|$rp|$rf" == "$direction|$item_protocol|$item_family" ]] || continue
        selector_any=0
        selector_full=0
        if firewall_rules_sources_overlap "$rs" "$source" &&
          [[ "$interface" == "*" || "$ri" == "*" || "$ri" == "$interface" ]]; then
          selector_any=1
        fi
        if firewall_rules_source_contains "$rs" "$source" &&
          [[ "$ri" == "*" || "$ri" == "$interface" ]]; then
          selector_full=1
        fi
        [[ "$selector_any" -eq 1 ]] || continue
        firewall_rules_intervals_overlap "$ports" "$rports" || continue
        if [[ "$action" == accept ]]; then
          allow_any=1
          if [[ "$selector_full" -eq 1 ]]; then
            if [[ -n "$allow_coverage" ]]; then
              allow_coverage="$(firewall_rules_normalize_ports "$allow_coverage,$rports")" || return $?
            else
              allow_coverage="$rports"
            fi
          fi
        elif [[ "$action" == drop || "$action" == reject ]]; then
          drop_any=1
          if [[ "$selector_full" -eq 1 ]]; then
            if [[ -n "$drop_coverage" ]]; then
              drop_coverage="$(firewall_rules_normalize_ports "$drop_coverage,$rports")" || return $?
            else
              drop_coverage="$rports"
            fi
          fi
        fi
      done <<<"$records"
      if [[ -n "$allow_coverage" ]]; then
        remaining="$(firewall_rules_interval_difference "$ports" "$allow_coverage")" || return $?
        [[ -n "$remaining" ]] || allow_full=$((allow_full + 1))
      fi
      if [[ -n "$drop_coverage" ]]; then
        remaining="$(firewall_rules_interval_difference "$ports" "$drop_coverage")" || return $?
        [[ -n "$remaining" ]] || drop_full=$((drop_full + 1))
      fi
    done
  done

  if [[ "$allow_any" -eq 1 && "$drop_any" -eq 1 ]]; then
    printf '混合/部分匹配（同时存在允许与拒绝条件）\n'
  elif [[ "$direction" == input && "$allow_full" -eq "$total" ]]; then
    printf '允许（完整覆盖查询；其他防火墙仍可能拒绝）\n'
  elif [[ "$direction" == input && "$allow_any" -eq 1 ]]; then
    printf '部分匹配（查询中仍有端口、协议、地址族或来源未放行）\n'
  elif [[ "$direction" == input ]]; then
    printf '未放行（VPS Guard 入站默认拒绝）\n'
  elif [[ "$drop_full" -eq "$total" ]]; then
    printf '拒绝（VPS Guard 自有规则完整覆盖查询）\n'
  elif [[ "$drop_any" -eq 1 ]]; then
    printf '部分匹配（仅部分端口、协议、地址族或来源被拒绝）\n'
  else
    printf '默认允许（未匹配 VPS Guard 出站拒绝规则）\n'
  fi
}

show_firewall_port_status() {
  local ports_input="$1" protocol="$2" direction="$3" family="$4" source="$5" interface="$6" external="$7"
  local ports matches rule_status
  require_firewall_enabled || return $?
  ports="$(firewall_rules_normalize_ports "$ports_input")" || return "$EXIT_USAGE"
  case "$protocol" in tcp | udp | both) ;; *) return "$EXIT_USAGE" ;; esac
  case "$direction" in inbound) direction=input ;; outbound) direction=output ;; *) return "$EXIT_USAGE" ;; esac
  firewall_rules_validate_family "$family" || return "$EXIT_USAGE"
  [[ "$source" != all ]] || source="*"
  interface="${interface:-*}"
  firewall_rules_validate_source "$source" || return "$EXIT_USAGE"
  firewall_rules_validate_interface "$interface" || return "$EXIT_USAGE"
  case "$external" in unverified | reachable | blocked) ;; *) return "$EXIT_USAGE" ;; esac
  printf '三层端口状态\n查询：%s/%s，%s，%s\n' "$ports" "$protocol" "$direction" "$family"
  rule_status="$(firewall_rule_status_for_query "$ports" "$protocol" "$direction" "$family" "$source" "$interface")" || return $?
  printf 'VPS Guard 规则：%s\n' "$rule_status"
  if ! command_exists ss; then
    printf '本机监听：未知（缺少 ss）\n'
  elif ! matches="$(firewall_listener_matches "$ports" "$protocol" "$family" 2>/dev/null)"; then
    printf '本机监听：未知（ss 状态不可读）\n'
  elif [[ -n "$matches" ]]; then
    printf '本机监听：是\n%s\n' "$matches"
  else
    printf '本机监听：未发现\n'
  fi
  case "$external" in
    reachable) printf '外部可达性：用户本次确认可达（非工具探测）\n' ;;
    blocked) printf '外部可达性：用户本次确认不可达（非工具探测）\n' ;;
    *) printf '外部可达性：未验证（云安全组、NAT 和上游防火墙仍未知）\n' ;;
  esac
}
