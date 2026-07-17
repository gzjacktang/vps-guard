#!/usr/bin/env bash

# 防火墙规则的纯解析、校验与渲染层。
# 本文件不读写系统状态，也不调用 nft；调用方应在通过这里的严格校验后，
# 再把渲染结果放入自己的受管 table/chain。

# 最近一次端口解析的内部结果。使用普通数组而不是 nameref，兼容 Bash 3.2。
FW_RULES_INTERVAL_STARTS=()
FW_RULES_INTERVAL_ENDS=()
FW_RULES_INTERVAL_HAD_OVERLAP=0

_firewall_rules_parse_ports() {
  local expression="$1"
  local compact item start end numeric_start numeric_end
  local sorted previous_start previous_end
  local raw_intervals=()

  FW_RULES_INTERVAL_STARTS=()
  FW_RULES_INTERVAL_ENDS=()
  FW_RULES_INTERVAL_HAD_OVERLAP=0

  [[ "$expression" != *$'\n'* && "$expression" != *$'\r'* ]] || return 2
  [[ ! "$expression" =~ [0-9][[:space:]]+[0-9] ]] || return 2
  compact="$(printf '%s' "$expression" | tr -d ' \t')"
  [[ -n "$compact" && "$compact" != ,* && "$compact" != *, && "$compact" != *,,* ]] || return 2

  local old_ifs="$IFS"
  IFS=,
  for item in $compact; do
    if [[ "$item" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
      start="${BASH_REMATCH[1]}"
      end="${BASH_REMATCH[2]}"
    elif [[ "$item" =~ ^[0-9]{1,5}$ ]]; then
      start="$item"
      end="$item"
    else
      IFS="$old_ifs"
      return 2
    fi
    numeric_start=$((10#$start))
    numeric_end=$((10#$end))
    if [[ "$numeric_start" -lt 1 || "$numeric_start" -gt 65535 ||
      "$numeric_end" -lt 1 || "$numeric_end" -gt 65535 ||
      "$numeric_start" -gt "$numeric_end" ]]; then
      IFS="$old_ifs"
      return 2
    fi
    raw_intervals+=("$numeric_start $numeric_end")
  done
  IFS="$old_ifs"

  sorted="$(printf '%s\n' "${raw_intervals[@]}" | sort -n -k1,1 -k2,2)"
  previous_start=""
  previous_end=""
  while IFS=' ' read -r start end; do
    [[ -n "$start" ]] || continue
    if [[ -z "$previous_start" ]]; then
      previous_start="$start"
      previous_end="$end"
      continue
    fi
    if [[ "$start" -le $((previous_end + 1)) ]]; then
      [[ "$start" -gt "$previous_end" ]] || FW_RULES_INTERVAL_HAD_OVERLAP=1
      [[ "$end" -le "$previous_end" ]] || previous_end="$end"
    else
      FW_RULES_INTERVAL_STARTS+=("$previous_start")
      FW_RULES_INTERVAL_ENDS+=("$previous_end")
      previous_start="$start"
      previous_end="$end"
    fi
  done <<<"$sorted"
  if [[ -n "$previous_start" ]]; then
    FW_RULES_INTERVAL_STARTS+=("$previous_start")
    FW_RULES_INTERVAL_ENDS+=("$previous_end")
  fi
}

_firewall_rules_print_intervals() {
  local index start end separator=""
  for ((index = 0; index < ${#FW_RULES_INTERVAL_STARTS[@]}; index++)); do
    start="${FW_RULES_INTERVAL_STARTS[$index]}"
    end="${FW_RULES_INTERVAL_ENDS[$index]}"
    printf '%s' "$separator"
    if [[ "$start" == "$end" ]]; then
      printf '%s' "$start"
    else
      printf '%s-%s' "$start" "$end"
    fi
    separator=,
  done
  printf '\n'
}

# 规范化单端口、列表、范围或混合表达式；相邻区间也会合并。
# 示例：443,80-82,81,83 -> 80-83,443
firewall_rules_normalize_ports() {
  _firewall_rules_parse_ports "$1" || return $?
  _firewall_rules_print_intervals
}

# 当原表达式存在重复端口或重叠区间时输出中文提示；无重叠时保持安静。
firewall_rules_port_normalization_note() {
  local normalized
  _firewall_rules_parse_ports "$1" || return $?
  normalized="$(_firewall_rules_print_intervals)"
  if [[ "$FW_RULES_INTERVAL_HAD_OVERLAP" -eq 1 ]]; then
    printf '检测到重复端口或重叠区间，已合并为：%s\n' "$normalized"
  fi
}

# 判断两个端口表达式是否至少有一个共同端口。
firewall_rules_intervals_overlap() {
  local left="$1" right="$2" left_lines right_lines
  local left_start left_end right_start right_end
  _firewall_rules_parse_ports "$left" || return $?
  left_lines="$(paste -d' ' <(printf '%s\n' "${FW_RULES_INTERVAL_STARTS[@]}") <(printf '%s\n' "${FW_RULES_INTERVAL_ENDS[@]}"))"
  _firewall_rules_parse_ports "$right" || return $?
  right_lines="$(paste -d' ' <(printf '%s\n' "${FW_RULES_INTERVAL_STARTS[@]}") <(printf '%s\n' "${FW_RULES_INTERVAL_ENDS[@]}"))"

  while read -r left_start left_end; do
    [[ -n "$left_start" ]] || continue
    while read -r right_start right_end; do
      [[ -n "$right_start" ]] || continue
      if [[ "$left_start" -le "$right_end" && "$right_start" -le "$left_end" ]]; then
        return 0
      fi
    done <<<"$right_lines"
  done <<<"$left_lines"
  return 1
}

# 从第一个端口集合中减去第二个集合；结果为空时只输出换行并成功返回。
firewall_rules_interval_difference() {
  local base="$1" removing="$2" base_lines remove_lines
  local base_start base_end remove_start remove_end cursor piece_start piece_end
  local pieces=()
  _firewall_rules_parse_ports "$base" || return $?
  base_lines="$(paste -d' ' <(printf '%s\n' "${FW_RULES_INTERVAL_STARTS[@]}") <(printf '%s\n' "${FW_RULES_INTERVAL_ENDS[@]}"))"
  _firewall_rules_parse_ports "$removing" || return $?
  remove_lines="$(paste -d' ' <(printf '%s\n' "${FW_RULES_INTERVAL_STARTS[@]}") <(printf '%s\n' "${FW_RULES_INTERVAL_ENDS[@]}"))"

  while read -r base_start base_end; do
    [[ -n "$base_start" ]] || continue
    cursor="$base_start"
    while read -r remove_start remove_end; do
      [[ -n "$remove_start" ]] || continue
      [[ "$remove_end" -ge "$cursor" ]] || continue
      [[ "$remove_start" -le "$base_end" ]] || break
      if [[ "$remove_start" -gt "$cursor" ]]; then
        piece_start="$cursor"
        piece_end=$((remove_start - 1))
        [[ "$piece_end" -gt "$base_end" ]] && piece_end="$base_end"
        pieces+=("$piece_start-$piece_end")
      fi
      cursor=$((remove_end + 1))
      [[ "$cursor" -le "$base_end" ]] || break
    done <<<"$remove_lines"
    if [[ "$cursor" -le "$base_end" ]]; then
      pieces+=("$cursor-$base_end")
    fi
  done <<<"$base_lines"

  if [[ "${#pieces[@]}" -eq 0 ]]; then
    printf '\n'
    return 0
  fi
  firewall_rules_normalize_ports "$(
    IFS=,
    printf '%s' "${pieces[*]}"
  )"
}

firewall_rules_validate_action() {
  [[ "$1" == "accept" || "$1" == "drop" || "$1" == "reject" ]]
}

firewall_rules_validate_direction() {
  [[ "$1" == "input" || "$1" == "output" || "$1" == "both" ]]
}

firewall_rules_validate_protocol() {
  [[ "$1" == "tcp" || "$1" == "udp" || "$1" == "both" || "$1" == "all" ]]
}

firewall_rules_validate_family() {
  [[ "$1" == "ipv4" || "$1" == "ipv6" || "$1" == "dual" ]]
}

firewall_rules_validate_interface() {
  [[ "$1" == "*" ]] || [[ ${#1} -le 15 && "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.:-]*$ ]]
}

_firewall_rules_validate_ipv4() {
  local address="$1" octet numeric count=0
  local old_ifs="$IFS"
  [[ "$address" != .* && "$address" != *. && "$address" != *..* ]] || return 1
  IFS=.
  for octet in $address; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || {
      IFS="$old_ifs"
      return 1
    }
    [[ "$octet" == "0" || "$octet" != 0* ]] || {
      IFS="$old_ifs"
      return 1
    }
    numeric=$((10#$octet))
    [[ "$numeric" -le 255 ]] || {
      IFS="$old_ifs"
      return 1
    }
    count=$((count + 1))
  done
  IFS="$old_ifs"
  [[ "$count" -eq 4 ]]
}

_firewall_rules_validate_ipv6() {
  local address="$1" left right group count=0 compressed=0
  local old_ifs="$IFS"
  [[ -n "$address" && "$address" == *:* && "$address" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  if [[ "$address" == *::* ]]; then
    compressed=1
    left="${address%%::*}"
    right="${address#*::}"
    [[ "$right" != *::* ]] || return 1
  else
    left="$address"
    right=""
  fi

  for address in "$left" "$right"; do
    [[ -n "$address" ]] || continue
    [[ "$address" != :* && "$address" != *: && "$address" != *::* ]] || return 1
    IFS=:
    for group in $address; do
      [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || {
        IFS="$old_ifs"
        return 1
      }
      count=$((count + 1))
    done
    IFS="$old_ifs"
  done
  if [[ "$compressed" -eq 1 ]]; then
    [[ "$count" -lt 8 ]]
  else
    [[ "$count" -eq 8 ]]
  fi
}

# 校验来源地址。允许 *、单个 IPv4/IPv6 地址及相应 CIDR。
firewall_rules_validate_source() {
  local source="$1" address prefix
  [[ "$source" == "*" ]] && return 0
  address="${source%%/*}"
  if [[ "$source" == */* ]]; then
    prefix="${source#*/}"
    [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
    [[ "$prefix" == "0" || "$prefix" != 0* ]] || return 1
  else
    prefix=""
  fi
  if [[ "$address" == *:* ]]; then
    _firewall_rules_validate_ipv6 "$address" || return 1
    [[ -z "$prefix" || $((10#$prefix)) -le 128 ]]
  else
    _firewall_rules_validate_ipv4 "$address" || return 1
    [[ -z "$prefix" || $((10#$prefix)) -le 32 ]]
  fi
}

firewall_rules_source_family() {
  firewall_rules_validate_source "$1" || return 2
  if [[ "$1" == "*" ]]; then
    printf 'dual\n'
  elif [[ "$1" == *:* ]]; then
    printf 'ipv6\n'
  else
    printf 'ipv4\n'
  fi
}

_firewall_rules_ipv4_number() {
  local address="$1" a b c d
  IFS=. read -r a b c d <<<"$address"
  printf '%u\n' "$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))"
}

_firewall_rules_ipv6_hex() {
  local address="$1" left right part missing item result=""
  local left_parts=() right_parts=() all_parts=()
  if [[ "$address" == *::* ]]; then
    left="${address%%::*}"
    right="${address#*::}"
  else
    left="$address"
    right=""
  fi
  [[ -z "$left" ]] || IFS=: read -r -a left_parts <<<"$left"
  [[ -z "$right" ]] || IFS=: read -r -a right_parts <<<"$right"
  missing=$((8 - ${#left_parts[@]} - ${#right_parts[@]}))
  all_parts=()
  [[ "${#left_parts[@]}" -eq 0 ]] || all_parts+=("${left_parts[@]}")
  if [[ "$address" == *::* ]]; then
    for ((part = 0; part < missing; part++)); do all_parts+=(0); done
  fi
  [[ "${#right_parts[@]}" -eq 0 ]] || all_parts+=("${right_parts[@]}")
  [[ "${#all_parts[@]}" -eq 8 ]] || return 2
  for item in "${all_parts[@]}"; do
    printf -v item '%04x' "$((16#$item))"
    result+="$item"
  done
  printf '%s\n' "$result"
}

# 判断第一个来源集合是否完整包含第二个来源集合。两个参数均须已通过来源校验。
firewall_rules_source_contains() {
  local container="$1" contained="$2" container_address contained_address
  local container_prefix contained_prefix family container_value contained_value mask
  local container_hex contained_hex full_nibbles remainder left_digit right_digit digit_mask
  [[ "$container" == "*" ]] && return 0
  [[ "$contained" != "*" ]] || return 1
  firewall_rules_validate_source "$container" && firewall_rules_validate_source "$contained" || return 2
  family="$(firewall_rules_source_family "$container")"
  [[ "$(firewall_rules_source_family "$contained")" == "$family" ]] || return 1
  container_address="${container%%/*}"
  contained_address="${contained%%/*}"
  if [[ "$family" == ipv4 ]]; then
    container_prefix="${container#*/}"
    [[ "$container" == */* ]] || container_prefix=32
    contained_prefix="${contained#*/}"
    [[ "$contained" == */* ]] || contained_prefix=32
    [[ "$contained_prefix" -ge "$container_prefix" ]] || return 1
    container_value="$(_firewall_rules_ipv4_number "$container_address")"
    contained_value="$(_firewall_rules_ipv4_number "$contained_address")"
    [[ "$container_prefix" -ne 0 ]] || return 0
    mask=$(((0xffffffff << (32 - container_prefix)) & 0xffffffff))
    [[ $((container_value & mask)) -eq $((contained_value & mask)) ]]
    return
  fi
  container_prefix="${container#*/}"
  [[ "$container" == */* ]] || container_prefix=128
  contained_prefix="${contained#*/}"
  [[ "$contained" == */* ]] || contained_prefix=128
  [[ "$contained_prefix" -ge "$container_prefix" ]] || return 1
  container_hex="$(_firewall_rules_ipv6_hex "$container_address")" || return 2
  contained_hex="$(_firewall_rules_ipv6_hex "$contained_address")" || return 2
  full_nibbles=$((container_prefix / 4))
  remainder=$((container_prefix % 4))
  [[ "${container_hex:0:full_nibbles}" == "${contained_hex:0:full_nibbles}" ]] || return 1
  [[ "$remainder" -ne 0 ]] || return 0
  left_digit=$((16#${container_hex:full_nibbles:1}))
  right_digit=$((16#${contained_hex:full_nibbles:1}))
  digit_mask=$(((0xf << (4 - remainder)) & 0xf))
  [[ $((left_digit & digit_mask)) -eq $((right_digit & digit_mask)) ]]
}

# 当前只允许单一地址族来源，因此两个来源集合重叠等价于其中一个包含另一个。
firewall_rules_sources_overlap() {
  firewall_rules_source_contains "$1" "$2" || firewall_rules_source_contains "$2" "$1"
}

# 把一条可能含 both/dual 的规则展开为方向和地址族都明确的原子记录。
# 输入及输出格式：action|direction|protocol|family|ports|source|interface
firewall_rules_expand_atomic() {
  local record="$1" action direction protocol family ports source interface extra
  local normalized_ports source_family item_direction item_family item_protocol without_pipes pipe_count
  local directions=() families=() protocols=()
  [[ "$record" != *$'\n'* && "$record" != *$'\r'* ]] || return 2
  without_pipes="${record//|/}"
  pipe_count=$((${#record} - ${#without_pipes}))
  [[ "$pipe_count" -eq 6 ]] || return 2
  IFS='|' read -r action direction protocol family ports source interface extra <<<"$record"
  [[ -n "$action" && -n "$direction" && -n "$protocol" && -n "$family" &&
    -n "$ports" && -n "$source" && -n "$interface" && -z "${extra:-}" ]] || return 2
  firewall_rules_validate_action "$action" || return 2
  firewall_rules_validate_direction "$direction" || return 2
  firewall_rules_validate_protocol "$protocol" || return 2
  firewall_rules_validate_family "$family" || return 2
  firewall_rules_validate_source "$source" || return 2
  firewall_rules_validate_interface "$interface" || return 2

  if [[ "$protocol" == "all" ]]; then
    [[ "$ports" == "*" ]] || return 2
    normalized_ports="*"
  else
    normalized_ports="$(firewall_rules_normalize_ports "$ports")" || return $?
  fi
  source_family="$(firewall_rules_source_family "$source")" || return $?
  [[ "$source_family" == "dual" || "$family" == "dual" || "$source_family" == "$family" ]] || return 2

  if [[ "$direction" == "both" ]]; then
    directions=(input output)
  else
    directions=("$direction")
  fi
  if [[ "$family" == "dual" ]]; then
    if [[ "$source_family" == "dual" ]]; then
      families=(ipv4 ipv6)
    else
      families=("$source_family")
    fi
  else
    families=("$family")
  fi
  if [[ "$protocol" == "both" ]]; then
    protocols=(tcp udp)
  else
    protocols=("$protocol")
  fi

  for item_direction in "${directions[@]}"; do
    for item_family in "${families[@]}"; do
      for item_protocol in "${protocols[@]}"; do
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
          "$action" "$item_direction" "$item_protocol" "$item_family" \
          "$normalized_ports" "$source" "$interface"
      done
    done
  done
}

_firewall_rules_nft_ports() {
  printf '%s' "$1" | sed 's/,/, /g'
}

# 把已经原子化的单条记录渲染为 nft chain 内的一条表达式。
firewall_rules_render_nft() {
  local record="$1" action direction protocol family ports source interface extra
  local expression="" normalized_ports source_family
  local expanded
  expanded="$(firewall_rules_expand_atomic "$record")" || return $?
  [[ "$expanded" != *$'\n'* ]] || return 2
  IFS='|' read -r action direction protocol family ports source interface extra <<<"$expanded"
  [[ "$direction" != "both" && "$family" != "dual" && -z "${extra:-}" ]] || return 2

  source_family="$(firewall_rules_source_family "$source")" || return $?
  if [[ "$source" != "*" ]]; then
    if [[ "$family" == "ipv4" ]]; then
      expression="ip saddr $source"
    else
      expression="ip6 saddr $source"
    fi
    [[ "$source_family" == "$family" ]] || return 2
  else
    expression="meta nfproto $family"
  fi
  if [[ "$interface" != "*" ]]; then
    [[ -z "$expression" ]] || expression+=" "
    if [[ "$direction" == "input" ]]; then
      expression+="iifname \"$interface\""
    else
      expression+="oifname \"$interface\""
    fi
  fi
  if [[ "$protocol" != "all" ]]; then
    normalized_ports="$(firewall_rules_normalize_ports "$ports")" || return $?
    [[ -z "$expression" ]] || expression+=" "
    expression+="$protocol dport { $(_firewall_rules_nft_ports "$normalized_ports") }"
  fi
  [[ -z "$expression" ]] || expression+=" "
  expression+="$action"
  printf '%s\n' "$expression"
}
