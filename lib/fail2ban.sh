#!/usr/bin/env bash

fail2ban_config_path() {
  printf '%s/etc/fail2ban/jail.d/vps-guard.local\n' "${VPS_GUARD_FS_ROOT:-}"
}

fail2ban_config_signature() {
  printf '%s\n' '# 由 VPS Guard 管理；请勿在此文件中保存私密信息'
}

path_owner_uid() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"
}

fail2ban_expected_owner_uid() {
  if [[ -n "${VPS_GUARD_FS_ROOT:-}" ]]; then
    path_owner_uid "$VPS_GUARD_FS_ROOT"
  else
    printf '0\n'
  fi
}

fail2ban_parent_is_safe() {
  local directory="$1" mode owner expected
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  mode="$(file_mode "$directory")" || return 1
  owner="$(path_owner_uid "$directory")" || return 1
  expected="$(fail2ban_expected_owner_uid)" || return 1
  [[ "$owner" == "$expected" && "$mode" =~ ^[0-7]*[0-5][0-5]$ ]]
}

fail2ban_config_is_owned() {
  local config="$1" first_line owner expected
  [[ -f "$config" && ! -L "$config" ]] || return 1
  [[ "$(file_mode "$config")" == 600 ]] || return 1
  owner="$(path_owner_uid "$config")" || return 1
  expected="$(fail2ban_expected_owner_uid)" || return 1
  [[ "$owner" == "$expected" ]] || return 1
  fail2ban_parent_is_safe "$(dirname "$config")" || return 1
  IFS= read -r first_line <"$config" || return 1
  [[ "$first_line" == "$(fail2ban_config_signature)" ]]
}

ensure_fail2ban_config_owned_or_absent() {
  local config
  config="$(fail2ban_config_path)"
  [[ ! -e "$config" && ! -L "$config" ]] && return 0
  fail2ban_config_is_owned "$config" || {
    error "同名 Fail2ban 配置并非 VPS Guard 所有，拒绝覆盖或删除：$config"
    return "$EXIT_CONFLICT"
  }
}

fail2ban_is_installed() {
  command_exists fail2ban-client
}

show_fail2ban_install_plan() {
  printf 'Fail2ban 尚未安装。官方 APT 安装计划：\n'
  printf '  apt-get update\n'
  printf '  apt-get install -y fail2ban python3-systemd nftables\n'
  printf '不会添加第三方软件源，也不会执行系统整体升级。\n'
}

install_fail2ban_package() {
  local confirmed="$1" answer
  fail2ban_is_installed && {
    printf 'Fail2ban 已安装。\n'
    return 0
  }
  show_fail2ban_install_plan
  [[ "$DRY_RUN" -ne 1 ]] || {
    printf 'dry-run：不会更新 APT 索引或安装软件。\n'
    return 0
  }
  command_exists apt-get || {
    error "缺少 apt-get，只支持 Debian/Ubuntu 官方 APT 安装"
    return "$EXIT_FAILURE"
  }
  if [[ "$confirmed" -ne 1 ]]; then
    printf '单独确认执行上述安装？[y/N] '
    IFS= read -r answer
    case "$answer" in y | Y | yes | YES) ;; *)
      printf '已取消安装。\n'
      return "$EXIT_CONFLICT"
      ;;
    esac
  fi
  if ! apt-get update || ! env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd nftables; then
    audit_event fail2ban.install failure "source=apt"
    error "Fail2ban 安装失败，未修改任何 Fail2ban 配置"
    return "$EXIT_FAILURE"
  fi
  fail2ban_is_installed || {
    error "APT 返回成功但 fail2ban-client 仍不可用，未修改配置"
    return "$EXIT_FAILURE"
  }
  audit_event fail2ban.install success "source=apt"
  printf 'Fail2ban 安装完成。\n'
}

valid_ipv4() {
  local value="$1" part
  local parts=()
  IFS=. read -r -a parts <<<"$value"
  [[ "${#parts[@]}" -eq 4 ]] || return 1
  for part in "${parts[@]}"; do
    [[ "$part" =~ ^[0-9]{1,3}$ ]] && ((10#$part <= 255)) || return 1
  done
}

valid_ip_address() {
  local value="$1"
  valid_ipv4 "$value" && return 0
  valid_ipv6 "$value"
}

valid_ipv6() {
  local value="$1" left right group compressed=0
  local groups=()
  [[ ${#value} -le 39 && "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:]+$ && "$value" != *:::* ]] || return 1
  if [[ "$value" == *::* ]]; then
    compressed=1
    left="${value%%::*}"
    right="${value#*::}"
    [[ "$right" != *::* ]] || return 1
    value="$left${left:+:}$right"
  fi
  IFS=: read -r -a groups <<<"$value"
  for group in "${groups[@]}"; do
    [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
  done
  if [[ "$compressed" -eq 1 ]]; then
    [[ "${#groups[@]}" -lt 8 ]]
  else
    [[ "${#groups[@]}" -eq 8 ]]
  fi
}

current_management_ip() {
  local connection client_ip client_port server_ip server_port extra
  connection="$(detected_ssh_connection 2>/dev/null || true)"
  [[ -n "$connection" ]] || return 1
  read -r client_ip client_port server_ip server_port extra <<<"$connection"
  [[ -z "${extra:-}" ]] || return 1
  valid_ip_address "$client_ip" && valid_ip_address "$server_ip" || return 1
  [[ "$client_port" =~ ^[0-9]+$ && "$client_port" -ge 1 && "$client_port" -le 65535 ]] || return 1
  [[ "$server_port" =~ ^[0-9]+$ && "$server_port" -ge 1 && "$server_port" -le 65535 ]] || return 1
  printf '%s\n' "$client_ip"
}

normalize_ignore_ips() {
  local input="$1" item normalized="127.0.0.1/8 ::1" address prefix max_prefix
  input="${input//,/ }"
  for item in $input; do
    address="${item%%/*}"
    valid_ip_address "$address" || {
      error "白名单地址无效：$item"
      return "$EXIT_USAGE"
    }
    if [[ "$item" == */* ]]; then
      prefix="${item#*/}"
      [[ "$address" == *:* ]] && max_prefix=128 || max_prefix=32
      [[ "$prefix" =~ ^[0-9]+$ && "$prefix" -le "$max_prefix" && "$item" != */*/* ]] || {
        error "白名单网段前缀无效：$item"
        return "$EXIT_USAGE"
      }
    fi
    [[ " $normalized " == *" $item "* ]] || normalized+=" $item"
  done
  printf '%s\n' "$normalized"
}

fail2ban_preset_values() {
  case "$1" in
    lenient | loose) printf '600\t10\t600\tfalse\t604800\n' ;;
    standard) printf '600\t5\t3600\tfalse\t604800\n' ;;
    strict) printf '600\t3\t43200\tfalse\t604800\n' ;;
    progressive) printf '600\t5\t3600\ttrue\t604800\n' ;;
    *) return 1 ;;
  esac
}

validate_fail2ban_policy() {
  local findtime="$1" maxretry="$2" bantime="$3" increment="$4" maxtime="$5" invalid=0
  [[ "$findtime" =~ ^[0-9]+$ && "$findtime" -ge 60 && "$findtime" -le 86400 ]] || {
    error "findtime 必须是 60-86400 秒"
    invalid=1
  }
  [[ "$maxretry" =~ ^[0-9]+$ && "$maxretry" -ge 1 && "$maxretry" -le 20 ]] || {
    error "maxretry 必须是 1-20"
    invalid=1
  }
  [[ "$bantime" =~ ^[0-9]+$ && "$bantime" -ge 60 && "$bantime" -le 604800 ]] || {
    error "bantime 必须是 60-604800 秒；v1 不允许永久封禁"
    invalid=1
  }
  [[ "$increment" == true || "$increment" == false ]] || {
    error "increment 只允许 true 或 false"
    invalid=1
  }
  [[ "$maxtime" =~ ^[0-9]+$ && "$maxtime" -ge "$bantime" && "$maxtime" -le 2592000 ]] || {
    error "max-bantime 必须不小于 bantime 且不超过 2592000 秒"
    invalid=1
  }
  [[ "$invalid" -eq 0 ]] || return "$EXIT_USAGE"
}

render_fail2ban_config() {
  local destination="$1" ports="$2" findtime="$3" maxretry="$4" bantime="$5" increment="$6" maxtime="$7" ignoreip="$8"
  {
    fail2ban_config_signature
    printf '[sshd]\n'
    printf 'enabled = true\nbackend = systemd\n'
    printf 'filter = sshd\nbanaction = nftables[type=multiport]\nusedns = no\nignoreself = true\n'
    printf 'port = %s\nfindtime = %s\nmaxretry = %s\nbantime = %s\n' "$ports" "$findtime" "$maxretry" "$bantime"
    printf 'bantime.increment = %s\nbantime.factor = 1\nbantime.maxtime = %s\n' "$increment" "$maxtime"
    printf 'ignoreip = %s\n' "$ignoreip"
  } >"$destination"
  chmod 0600 "$destination"
}

reload_fail2ban_runtime() {
  fail2ban-client -t && systemctl restart fail2ban && fail2ban-client ping >/dev/null && fail2ban-client status sshd >/dev/null
}

reload_fail2ban_if_managed() {
  [[ -e "$(fail2ban_config_path)" ]] || return 0
  fail2ban_is_installed || return "$EXIT_FAILURE"
  reload_fail2ban_runtime
}

sync_fail2ban_ssh_ports() {
  local ports="$1" config temp
  config="$(fail2ban_config_path)"
  [[ -e "$config" ]] || return 0
  ensure_fail2ban_config_owned_or_absent || return $?
  temp="$(mktemp "$(dirname "$config")/.vps-guard.local.XXXXXX")" || return "$EXIT_FAILURE"
  awk -v ports="$ports" 'BEGIN { done=0 } /^port[[:space:]]*=/ { print "port = " ports; done=1; next } { print } END { if (!done) print "port = " ports }' "$config" >"$temp" || return "$EXIT_FAILURE"
  chmod 0600 "$temp" || return "$EXIT_FAILURE"
  mv "$temp" "$config" || return "$EXIT_FAILURE"
  reload_fail2ban_runtime
}

stage_fail2ban_candidate() {
  local candidate="$1" directory stage
  directory="$(dirname "$(fail2ban_config_path)")"
  mkdir -p "$directory" || return "$EXIT_FAILURE"
  fail2ban_parent_is_safe "$directory" || {
    error "Fail2ban 配置目录所有者或权限不安全：$directory"
    return "$EXIT_CONFLICT"
  }
  stage="$(mktemp "$directory/.vps-guard.local.XXXXXX")" || return "$EXIT_FAILURE"
  if ! cp "$candidate" "$stage" || ! chmod 0600 "$stage"; then
    rm -f "$stage"
    return "$EXIT_FAILURE"
  fi
  printf '%s\n' "$stage"
}

validate_fail2ban_candidate() {
  local candidate="$1" shadow source
  shadow="$(mktemp -d "${TMPDIR:-/tmp}/vps-guard-fail2ban-shadow.XXXXXX")" || return "$EXIT_FAILURE"
  source="${VPS_GUARD_FS_ROOT:-}/etc/fail2ban"
  if [[ -d "$source" ]]; then
    cp -a "$source/." "$shadow/" || {
      rm -rf "$shadow"
      return "$EXIT_FAILURE"
    }
  fi
  mkdir -p "$shadow/jail.d" || {
    rm -rf "$shadow"
    return "$EXIT_FAILURE"
  }
  cp "$candidate" "$shadow/jail.d/vps-guard.local" || {
    rm -rf "$shadow"
    return "$EXIT_FAILURE"
  }
  if ! fail2ban-client -t -c "$shadow"; then
    rm -rf "$shadow"
    return "$EXIT_FAILURE"
  fi
  rm -rf "$shadow"
}

show_fail2ban_candidate_diff() {
  local candidate="$1" current output status
  current="$(fail2ban_config_path)"
  if [[ -e "$current" ]]; then
    if output="$(diff -u --label 当前-vps-guard.local --label 候选-vps-guard.local "$current" "$candidate")"; then
      printf '配置文件差异：无变化\n'
      return 0
    else
      status=$?
    fi
  else
    if output="$(diff -u --label 当前-未启用 --label 候选-vps-guard.local /dev/null "$candidate")"; then
      printf '配置文件差异：无变化\n'
      return 0
    else
      status=$?
    fi
  fi
  [[ "$status" -eq 1 ]] || {
    error "无法比较当前与候选 Fail2ban 配置"
    return "$EXIT_FAILURE"
  }
  printf '配置文件统一差异：\n%s\n' "$output"
}

restore_fail2ban_snapshot() {
  local snapshot="$1"
  restore_snapshot "$snapshot" 1 && systemctl restart fail2ban >/dev/null 2>&1
}

recover_failed_fail2ban_change() {
  local snapshot="$1" rollback_token="$2"
  if restore_fail2ban_snapshot "$snapshot" >/dev/null 2>&1; then
    if confirm_rollback "$rollback_token" 1 >/dev/null 2>&1; then
      printf '已恢复操作前配置并取消定时回滚。\n' >&2
      return 0
    fi
    error "操作前配置已恢复，但无法取消定时回滚；任务仍保留，请检查其状态"
    return "$EXIT_FAILURE"
  fi
  error "立即恢复未完整成功；独立自动回滚任务仍保留，请勿手工确认"
  return "$EXIT_FAILURE"
}

apply_fail2ban_policy() {
  with_config_transaction_lock apply_fail2ban_policy_unlocked "$@"
}

apply_fail2ban_policy_unlocked() {
  local preset="$1" findtime="$2" maxretry="$3" bantime="$4" increment="$5" maxtime="$6"
  local ignore_input="$7" trust_current="$8" confirmed="$9" rollback_minutes="${10}"
  local values current_ip="" ignoreip ports candidate live_stage="" answer snapshot_output snapshot rollback_output rollback_token failure_status
  if ! fail2ban_is_installed; then
    show_fail2ban_install_plan
    error "请先单独执行 vps-guard fail2ban install，安装成功后再应用配置"
    return "$EXIT_CONFLICT"
  fi
  ensure_fail2ban_config_owned_or_absent || return $?
  if [[ "$preset" != custom ]]; then
    values="$(fail2ban_preset_values "$preset")" || {
      error "未知预设：$preset"
      return "$EXIT_USAGE"
    }
    IFS=$'\t' read -r findtime maxretry bantime increment maxtime <<<"$values"
  fi
  validate_fail2ban_policy "$findtime" "$maxretry" "$bantime" "$increment" "$maxtime" || return $?
  current_ip="$(current_management_ip 2>/dev/null || true)"
  if [[ -n "$current_ip" && "$trust_current" == ask ]]; then
    printf '检测到当前管理 IP：%s。加入 Fail2ban 白名单？[y/N] ' "$current_ip"
    IFS= read -r answer || answer=""
    case "$answer" in y | Y | yes | YES) trust_current=yes ;; *) trust_current=no ;; esac
  fi
  [[ "$trust_current" != yes || -n "$current_ip" ]] || {
    error "当前不是可识别的 SSH 管理会话，不能使用 --whitelist-current-ip"
    return "$EXIT_CONFLICT"
  }
  [[ "$trust_current" != yes ]] || ignore_input="$ignore_input $current_ip"
  ignoreip="$(normalize_ignore_ips "$ignore_input")" || return $?
  ports="$(effective_sshd_ports)" || return $?
  candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-fail2ban.XXXXXX")" || return "$EXIT_FAILURE"
  render_fail2ban_config "$candidate" "$ports" "$findtime" "$maxretry" "$bantime" "$increment" "$maxtime" "$ignoreip" || {
    rm -f "$candidate"
    return "$EXIT_FAILURE"
  }
  validate_fail2ban_candidate "$candidate" || {
    rm -f "$candidate"
    error "Fail2ban 候选配置检查失败，未写入 live 配置"
    return "$EXIT_FAILURE"
  }
  show_fail2ban_candidate_diff "$candidate" || {
    rm -f "$candidate"
    return "$EXIT_FAILURE"
  }
  printf 'Fail2ban sshd 最终差异\n预设：%s\n端口：%s\nfindtime：%s 秒\nmaxretry：%s\nbantime：%s 秒\n渐进封禁：%s（上限 %s 秒）\n白名单：%s\n后端：systemd\n动作：nftables[type=multiport]\n' \
    "$preset" "$ports" "$findtime" "$maxretry" "$bantime" "$increment" "$maxtime" "$ignoreip"
  [[ "$DRY_RUN" -ne 1 ]] || {
    rm -f "$candidate"
    printf 'dry-run：不会写配置、重启服务或启动回滚。\n'
    return 0
  }
  if [[ "$confirmed" -ne 1 ]]; then
    printf '确认应用并启动 %s 分钟自动回滚？[y/N] ' "$rollback_minutes"
    IFS= read -r answer
    case "$answer" in y | Y | yes | YES) ;; *)
      rm -f "$candidate"
      printf '已取消。\n'
      return 0
      ;;
    esac
  fi
  validate_rollback_minutes "$rollback_minutes" || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  ensure_no_pending_firewall_rollback || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  snapshot_output="$(create_snapshot fail2ban-before-apply)" || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  printf '%s\n' "$snapshot_output"
  snapshot="${snapshot_output#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  rollback_output="$(start_rollback "$snapshot" "$rollback_minutes" fail2ban)" || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  printf '%s\n' "$rollback_output"
  rollback_token="${rollback_output#*自动回滚已启动：}"
  rollback_token="${rollback_token%%$'\n'*}"
  if ! live_stage="$(stage_fail2ban_candidate "$candidate")" || ! mv "$live_stage" "$(fail2ban_config_path)" || ! reload_fail2ban_runtime; then
    rm -f "$live_stage"
    rm -f "$candidate"
    recover_failed_fail2ban_change "$snapshot" "$rollback_token" || true
    audit_event fail2ban.apply failure "preset=$preset snapshot=$snapshot"
    error "Fail2ban 配置检查或启动失败，已尝试原子恢复"
    return "$EXIT_FAILURE"
  fi
  rm -f "$candidate"
  audit_event fail2ban.apply success "preset=$preset snapshot=$snapshot"
  printf 'Fail2ban sshd 防护已启用；请验证新 SSH 会话后执行 rollback confirm。\n'
}

show_fail2ban_status() {
  fail2ban_is_installed || {
    error "Fail2ban 未安装"
    return "$EXIT_CONFLICT"
  }
  printf 'Fail2ban 服务状态\n'
  systemctl is-active --quiet fail2ban && printf 'systemd：运行中\n' || printf 'systemd：未运行\n'
  fail2ban-client status
  fail2ban-client status sshd
}

show_fail2ban_banned() {
  local banned ip found=0
  fail2ban_is_installed || {
    error "Fail2ban 未安装"
    return "$EXIT_CONFLICT"
  }
  printf 'sshd 当前封禁列表\n'
  banned="$(fail2ban-client get sshd banip)" || return "$EXIT_FAILURE"
  for ip in $banned; do
    valid_ip_address "$ip" || continue
    printf '%s\n' "$ip"
    found=1
  done
  [[ "$found" -eq 1 ]] || printf '无\n'
}

unban_fail2ban_ip() {
  local ip="$1" banned item found=0
  valid_ip_address "$ip" || {
    error "无效 IPv4/IPv6 地址：$ip"
    return "$EXIT_USAGE"
  }
  banned="$(fail2ban-client get sshd banip)" || return "$EXIT_FAILURE"
  for item in $banned; do [[ "$item" != "$ip" ]] || found=1; done
  [[ "$found" -eq 1 ]] || {
    printf '该地址当前未被 sshd jail 封禁：%s\n' "$ip"
    return 0
  }
  fail2ban-client set sshd unbanip "$ip" || return "$EXIT_FAILURE"
  audit_event fail2ban.unban success "jail=sshd ip=$ip"
  printf '已从 sshd jail 解封：%s\n' "$ip"
}

disable_fail2ban() {
  with_config_transaction_lock disable_fail2ban_unlocked "$@"
}

disable_fail2ban_unlocked() {
  local rollback_minutes="$1" confirmed="$2" answer snapshot_output snapshot rollback_output rollback_token
  [[ -e "$(fail2ban_config_path)" ]] || {
    printf 'VPS Guard Fail2ban 配置已经停用。\n'
    return 0
  }
  ensure_fail2ban_config_owned_or_absent || return $?
  printf '将只删除 %s，不卸载 Fail2ban、不删除第三方 jail。\n' "$(fail2ban_config_path)"
  [[ "$DRY_RUN" -ne 1 ]] || {
    printf 'dry-run：不会删除配置。\n'
    return 0
  }
  if [[ "$confirmed" -ne 1 ]]; then
    printf '确认停用并启动 %s 分钟自动回滚？[y/N] ' "$rollback_minutes"
    IFS= read -r answer
    case "$answer" in y | Y | yes | YES) ;; *)
      printf '已取消。\n'
      return 0
      ;;
    esac
  fi
  validate_rollback_minutes "$rollback_minutes" || return $?
  ensure_no_pending_firewall_rollback || return $?
  snapshot_output="$(create_snapshot fail2ban-before-disable)" || return $?
  printf '%s\n' "$snapshot_output"
  snapshot="${snapshot_output#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  rollback_output="$(start_rollback "$snapshot" "$rollback_minutes" fail2ban)" || return $?
  printf '%s\n' "$rollback_output"
  rollback_token="${rollback_output#*自动回滚已启动：}"
  rollback_token="${rollback_token%%$'\n'*}"
  if ! rm -f "$(fail2ban_config_path)" || ! fail2ban-client -t || ! systemctl restart fail2ban; then
    recover_failed_fail2ban_change "$snapshot" "$rollback_token" || true
    error "停用失败，已尝试恢复"
    return "$EXIT_FAILURE"
  fi
  audit_event fail2ban.disable success "snapshot=$snapshot"
  printf 'VPS Guard 管理的 Fail2ban sshd 配置已停用。\n'
}

restore_fail2ban_from_snapshot() {
  with_config_transaction_lock restore_fail2ban_from_snapshot_unlocked "$@"
}

restore_fail2ban_from_snapshot_unlocked() {
  local target="$1" minutes="$2" confirmed="$3" target_dir saved candidate="" live_stage="" answer current_output current rollback_output rollback_token
  local manifest_entry kind mode expected_checksum extra failure_status
  fail2ban_is_installed || {
    error "Fail2ban 未安装，不能校验或恢复配置"
    return "$EXIT_CONFLICT"
  }
  target_dir="$(snapshot_directory "$target")" || return $?
  [[ -r "$target_dir/manifest.tsv" ]] || return "$EXIT_FAILURE"
  saved="$target_dir/files/etc/fail2ban/jail.d/vps-guard.local"
  manifest_entry="$(awk -F '\t' '$1 == "/etc/fail2ban/jail.d/vps-guard.local" { count++; entry=$2 FS $3 FS $4 } END { if (count != 1) exit 1; print entry }' "$target_dir/manifest.tsv")" || {
    error "快照清单缺少唯一的 VPS Guard Fail2ban 路径记录"
    return "$EXIT_FAILURE"
  }
  IFS=$'\t' read -r kind mode expected_checksum extra <<<"$manifest_entry"
  [[ -z "${extra:-}" ]] || return "$EXIT_FAILURE"
  if [[ "$kind" == file ]]; then
    [[ "$mode" =~ ^[0-7]{3,4}$ && -f "$saved" && ! -L "$saved" ]] || {
      error "快照中的 Fail2ban 文件缺失或元数据无效"
      return "$EXIT_FAILURE"
    }
    [[ "$(file_checksum "$saved")" == "$expected_checksum" ]] || {
      error "快照中的 Fail2ban 文件校验和不匹配"
      return "$EXIT_FAILURE"
    }
    fail2ban_config_is_owned "$saved" || {
      error "快照中的同名 jail 不含 VPS Guard 所有权标记，拒绝恢复"
      return "$EXIT_CONFLICT"
    }
    candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-fail2ban-restore.XXXXXX")" || return "$EXIT_FAILURE"
    cp "$saved" "$candidate" || return "$EXIT_FAILURE"
    validate_fail2ban_candidate "$candidate" || {
      rm -f "$candidate"
      error "快照中的 Fail2ban 配置校验失败"
      return "$EXIT_FAILURE"
    }
  elif [[ "$kind" == missing ]]; then
    [[ ! -e "$saved" && ! -L "$saved" ]] || {
      error "快照清单记录为未启用，但发现异常的 Fail2ban 文件"
      return "$EXIT_FAILURE"
    }
  else
    error "快照中的 Fail2ban 路径类型无效：$kind"
    return "$EXIT_FAILURE"
  fi
  ensure_fail2ban_config_owned_or_absent || return $?
  printf 'Fail2ban 选择性恢复摘要\n目标快照：%s\n结果：%s\n只处理 VPS Guard 自有 jail 文件，不改第三方 jail。\n' \
    "$target" "$([[ -n "$candidate" ]] && printf '恢复配置' || printf '恢复为未启用')"
  [[ "$DRY_RUN" -ne 1 ]] || {
    rm -f "$candidate"
    printf 'dry-run：不会写入或启动回滚。\n'
    return 0
  }
  if [[ "$confirmed" -ne 1 ]]; then
    printf '确认恢复并启动 %s 分钟自动回滚？[y/N] ' "$minutes"
    IFS= read -r answer
    case "$answer" in y | Y | yes | YES) ;; *)
      rm -f "$candidate"
      printf '已取消。\n'
      return 0
      ;;
    esac
  fi
  validate_rollback_minutes "$minutes" || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  ensure_no_pending_firewall_rollback || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  current_output="$(create_snapshot fail2ban-before-restore)" || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  printf '%s\n' "$current_output"
  current="${current_output#*快照已创建：}"
  current="${current%%$'\n'*}"
  rollback_output="$(start_rollback "$current" "$minutes" fail2ban)" || {
    failure_status=$?
    rm -f "$candidate"
    return "$failure_status"
  }
  printf '%s\n' "$rollback_output"
  rollback_token="${rollback_output#*自动回滚已启动：}"
  rollback_token="${rollback_token%%$'\n'*}"
  if { [[ -n "$candidate" ]] && ! live_stage="$(stage_fail2ban_candidate "$candidate")"; } ||
    { [[ -n "$candidate" ]] && ! mv "$live_stage" "$(fail2ban_config_path)"; } ||
    { [[ -z "$candidate" ]] && ! rm -f "$(fail2ban_config_path)"; } ||
    ! fail2ban-client -t || ! systemctl restart fail2ban; then
    rm -f "$candidate" "$live_stage"
    recover_failed_fail2ban_change "$current" "$rollback_token" || true
    audit_event fail2ban.restore failure "snapshot=$target rollback=$rollback_token"
    error "Fail2ban 恢复失败，已尝试恢复操作前状态"
    return "$EXIT_FAILURE"
  fi
  rm -f "$candidate"
  audit_event fail2ban.restore success "snapshot=$target rollback=$rollback_token"
  printf 'Fail2ban 自有配置已恢复；验证后执行 rollback confirm。\n'
}

fail2ban_cli() {
  local action="${1:-}" preset=standard findtime="" maxretry="" bantime="" increment=false maxtime=604800 ignoreip="" trust=ask confirmed=0 minutes=5 ip snapshot
  case "$action" in
    install)
      [[ "$#" -le 2 ]] || return "$EXIT_USAGE"
      [[ "$#" -ne 2 || "${2:-}" == --yes ]] || {
        error "用法：vps-guard fail2ban install [--yes]"
        return "$EXIT_USAGE"
      }
      [[ "${2:-}" == --yes ]] && confirmed=1
      install_fail2ban_package "$confirmed"
      ;;
    apply)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --preset)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            preset="$2"
            shift 2
            ;;
          --findtime)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            findtime="$2"
            shift 2
            ;;
          --maxretry)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            maxretry="$2"
            shift 2
            ;;
          --bantime)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            bantime="$2"
            shift 2
            ;;
          --increment)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            increment="$2"
            shift 2
            ;;
          --max-bantime)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            maxtime="$2"
            shift 2
            ;;
          --ignore-ip)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            ignoreip="$2"
            shift 2
            ;;
          --whitelist-current-ip)
            trust=yes
            shift
            ;;
          --no-whitelist-current-ip)
            trust=no
            shift
            ;;
          --rollback-minutes)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            minutes="$2"
            shift 2
            ;;
          --yes)
            confirmed=1
            shift
            ;;
          *)
            error "fail2ban apply 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      if [[ "$preset" == custom && (-z "$findtime" || -z "$maxretry" || -z "$bantime") ]]; then
        error "custom 必须指定 --findtime、--maxretry 和 --bantime"
        return "$EXIT_USAGE"
      fi
      apply_fail2ban_policy "$preset" "$findtime" "$maxretry" "$bantime" "$increment" "$maxtime" "$ignoreip" "$trust" "$confirmed" "$minutes"
      ;;
    status)
      [[ "$#" -eq 1 ]] || return "$EXIT_USAGE"
      show_fail2ban_status
      ;;
    banned | bans)
      [[ "$#" -eq 1 ]] || return "$EXIT_USAGE"
      show_fail2ban_banned
      ;;
    unban)
      [[ "$#" -eq 2 ]] || {
        error "用法：vps-guard fail2ban unban <IPv4|IPv6>"
        return "$EXIT_USAGE"
      }
      ip="$2"
      unban_fail2ban_ip "$ip"
      ;;
    disable)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in --rollback-minutes)
          [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
          minutes="$2"
          shift 2
          ;;
        --yes)
          confirmed=1
          shift
          ;;
        *) return "$EXIT_USAGE" ;; esac
      done
      disable_fail2ban "$minutes" "$confirmed"
      ;;
    restore)
      [[ "$#" -ge 2 ]] || {
        error "用法：vps-guard fail2ban restore <快照ID> [--rollback-minutes 3|5|10] [--yes]"
        return "$EXIT_USAGE"
      }
      snapshot="$2"
      shift 2
      while [[ "$#" -gt 0 ]]; do
        case "$1" in --rollback-minutes)
          [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
          minutes="$2"
          shift 2
          ;;
        --yes)
          confirmed=1
          shift
          ;;
        *) return "$EXIT_USAGE" ;; esac
      done
      restore_fail2ban_from_snapshot "$snapshot" "$minutes" "$confirmed"
      ;;
    *)
      error "用法：vps-guard fail2ban <install|apply|status|banned|unban|disable|restore>"
      return "$EXIT_USAGE"
      ;;
  esac
}
