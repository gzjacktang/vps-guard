#!/usr/bin/env bash

# 三步快速安全配置：规划、统一确认、单快照事务。精细能力继续留在各自子菜单。

wizard_root() {
  printf '%s/wizards\n' "$(backup_data_dir)"
}

validate_wizard_token() {
  [[ -n "$1" && "$1" != "." && "$1" != ".." && "$1" != *[!A-Za-z0-9._-]* ]]
}

wizard_state_directory() {
  validate_wizard_token "$1" || {
    error "向导令牌不合法"
    return "$EXIT_USAGE"
  }
  printf '%s/%s\n' "$(wizard_root)" "$1"
}

wizard_state_value() {
  local token="$1" key="$2" state
  state="$(wizard_state_directory "$token")/state" || return $?
  [[ -r "$state" ]] || return "$EXIT_FAILURE"
  read_state_value "$state" "$key" | tail -1
}

WIZARD_STATE_FILE=""
WIZARD_STATE_STATUS=""
WIZARD_STATE_PLAN=""
WIZARD_STATE_SNAPSHOT=""
WIZARD_STATE_ROLLBACK=""
WIZARD_STATE_OLD_PORTS=""
WIZARD_STATE_NEW_PORT=""
WIZARD_STATE_ROLLBACK_STATUS=""

wizard_load_state() {
  local token="$1" expected_owner mode rollback_file hook linked_snapshot linked_token normalized count key
  local required=(token snapshot rollback plan old_ports new_port)
  WIZARD_STATE_FILE="$(wizard_state_directory "$token")/state" || return $?
  [[ -f "$WIZARD_STATE_FILE" && ! -L "$WIZARD_STATE_FILE" ]] || {
    error "向导状态不是可信普通文件"
    return "$EXIT_CONFLICT"
  }
  mode="$(file_mode "$WIZARD_STATE_FILE")" || return "$EXIT_FAILURE"
  expected_owner="$(fail2ban_expected_owner_uid)" || return "$EXIT_FAILURE"
  [[ "$mode" == 600 && "$(path_owner_uid "$WIZARD_STATE_FILE")" == "$expected_owner" ]] || {
    error "向导状态所有者或权限不安全"
    return "$EXIT_CONFLICT"
  }
  awk -F= '$1 !~ /^(token|snapshot|rollback|plan|old_ports|new_port|status|reason|committed)$/ { exit 1 }' \
    "$WIZARD_STATE_FILE" || {
    error "向导状态包含未知字段"
    return "$EXIT_CONFLICT"
  }
  for key in "${required[@]}"; do
    count="$(grep -c "^${key}=" "$WIZARD_STATE_FILE" || true)"
    [[ "$count" -eq 1 ]] || {
      error "向导状态字段缺失或重复：$key"
      return "$EXIT_CONFLICT"
    }
  done
  [[ "$(read_state_value "$WIZARD_STATE_FILE" token)" == "$token" ]] || return "$EXIT_CONFLICT"
  WIZARD_STATE_STATUS="$(read_state_value "$WIZARD_STATE_FILE" status | tail -1)"
  WIZARD_STATE_PLAN="$(read_state_value "$WIZARD_STATE_FILE" plan)"
  WIZARD_STATE_SNAPSHOT="$(read_state_value "$WIZARD_STATE_FILE" snapshot)"
  WIZARD_STATE_ROLLBACK="$(read_state_value "$WIZARD_STATE_FILE" rollback)"
  WIZARD_STATE_OLD_PORTS="$(read_state_value "$WIZARD_STATE_FILE" old_ports)"
  WIZARD_STATE_NEW_PORT="$(read_state_value "$WIZARD_STATE_FILE" new_port)"
  case "$WIZARD_STATE_STATUS" in applying | pending | committing | recovering | committed | failed) ;; *)
    error "向导状态值无效"
    return "$EXIT_CONFLICT"
    ;;
  esac
  case "$WIZARD_STATE_PLAN" in standard | firewall | fail2ban) ;; *) return "$EXIT_CONFLICT" ;; esac
  normalized="$(normalize_basic_ports "$WIZARD_STATE_OLD_PORTS")" || return "$EXIT_CONFLICT"
  [[ -n "$normalized" && "$normalized" == "$WIZARD_STATE_OLD_PORTS" ]] || return "$EXIT_CONFLICT"
  if [[ "$WIZARD_STATE_NEW_PORT" != "$WIZARD_STATE_OLD_PORTS" ]]; then
    normalized="$(validate_single_ssh_port "$WIZARD_STATE_NEW_PORT")" || return "$EXIT_CONFLICT"
    [[ "$normalized" == "$WIZARD_STATE_NEW_PORT" ]] || return "$EXIT_CONFLICT"
  fi
  validate_rollback_token "$WIZARD_STATE_ROLLBACK" || return "$EXIT_CONFLICT"
  snapshot_directory "$WIZARD_STATE_SNAPSHOT" >/dev/null || return "$EXIT_CONFLICT"
  rollback_file="$(rollback_state_dir "$WIZARD_STATE_ROLLBACK")/state" || return $?
  [[ -f "$rollback_file" && ! -L "$rollback_file" ]] || return "$EXIT_CONFLICT"
  for key in token snapshot hook; do
    count="$(grep -c "^${key}=" "$rollback_file" || true)"
    [[ "$count" -eq 1 ]] || return "$EXIT_CONFLICT"
  done
  linked_token="$(read_state_value "$rollback_file" token)"
  linked_snapshot="$(read_state_value "$rollback_file" snapshot)"
  hook="$(read_state_value "$rollback_file" hook)"
  [[ "$linked_token" == "$WIZARD_STATE_ROLLBACK" && "$linked_snapshot" == "$WIZARD_STATE_SNAPSHOT" &&
    "$hook" == "wizard-$WIZARD_STATE_PLAN" ]] || {
    error "向导与自动回滚关联不一致"
    return "$EXIT_CONFLICT"
  }
  WIZARD_STATE_ROLLBACK_STATUS="$(read_state_value "$rollback_file" status | tail -1)"
}

wizard_write_state() {
  local token="$1" snapshot="$2" rollback="$3" plan="$4" old_ports="$5" new_port="$6"
  local directory
  directory="$(wizard_state_directory "$token")" || return $?
  umask 077
  mkdir -p "$directory" || return "$EXIT_FAILURE"
  chmod 0700 "$(wizard_root)" "$directory" || return "$EXIT_FAILURE"
  printf 'token=%s\nsnapshot=%s\nrollback=%s\nplan=%s\nold_ports=%s\nnew_port=%s\nstatus=applying\n' \
    "$token" "$snapshot" "$rollback" "$plan" "$old_ports" "$new_port" >"$directory/state" || return "$EXIT_FAILURE"
  chmod 0600 "$directory/state" || return "$EXIT_FAILURE"
}

wizard_detect_listening_ports() {
  local protocol="$1" line netid _state _recv _send local_address _peer _rest port ports="" lines ssh_ports
  command_exists ss || return "$EXIT_FAILURE"
  lines="$(ss -H -lntup 2>/dev/null)" || return "$EXIT_FAILURE"
  ssh_ports="$(effective_sshd_ports 2>/dev/null || true)"
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    read -r netid _state _recv _send local_address _peer _rest <<<"$line"
    case "$protocol:$netid" in tcp:tcp* | udp:udp*) ;; *) continue ;; esac
    port="${local_address##*:}"
    port="${port//]/}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    case "$local_address" in 127.* | '[::1]:'* | '::1:'*) continue ;; esac
    [[ "$protocol" != tcp || ",$ssh_ports," != *",$port,"* ]] || continue
    ports="$(merge_basic_ports "$ports" "$port")"
  done <<<"$lines"
  printf '%s\n' "$ports"
}

wizard_show_details() {
  printf '快速安全配置方案\n'
  printf '1. 标准防护：SSH 端口（可保持）、nftables 入站基线、Fail2ban 标准策略\n'
  printf '2. 仅防火墙：保留 SSH 入口并应用 nftables 入站基线\n'
  printf '3. 仅 Fail2ban：为当前 SSH 端口应用标准封禁策略\n'
  printf '密钥、禁用密码、root 策略、来源限制和出站限制位于对应高级子菜单。\n'
  printf '所有方案应用时只创建一个完整快照和一个自动回滚任务。\n'
}

wizard_recover() {
  local snapshot="$1" rollback="$2" hook="$3"
  local restored=0
  if restore_snapshot "$snapshot" 1 && run_rollback_hook "$hook"; then
    restored=1
  fi
  if [[ "$restored" -eq 1 ]] && confirm_rollback "$rollback" 1 >/dev/null 2>&1; then
    printf '已恢复向导开始前的完整配置并取消自动回滚。\n' >&2
    return 0
  fi
  error "向导立即恢复未完整成功；自动回滚仍保留，请勿确认该任务"
  return "$EXIT_FAILURE"
}

# 恢复前必须先持久化 recovering。这样即使恢复完成后的状态收尾失败，
# 后续命令也只会继续幂等恢复，绝不会把已经还原的配置误判为 committed。
wizard_mark_recovering_and_restore() {
  local state_file="$1" snapshot="$2" rollback="$3" hook="$4" reason="$5"
  if ! printf 'status=recovering\nreason=%s\n' "$reason" >>"$state_file"; then
    error "无法持久化恢复中状态；未执行立即恢复，自动回滚仍保留"
    return "$EXIT_FAILURE"
  fi
  if ! wizard_recover "$snapshot" "$rollback" "$hook"; then
    return "$EXIT_FAILURE"
  fi
  if ! printf 'status=failed\nreason=%s\n' "$reason" >>"$state_file"; then
    error "配置已恢复，但向导状态收尾失败；修复存储后重试 wizard confirm"
    return "$EXIT_FAILURE"
  fi
}

wizard_apply() {
  with_config_transaction_lock wizard_apply_unlocked "$@"
}

wizard_apply_unlocked() {
  local plan="$1" requested_port="$2" tcp_input="$3" udp_input="$4" rollback_minutes="$5" confirmed="$6"
  local old_ports new_port transition_ports tcp_ports udp_ports advanced_rules hook snapshot_label
  local firewall_candidate="" fail2ban_candidate="" fail2ban_stage="" values ignoreip current_ip="" session_port
  local findtime maxretry bantime increment maxtime existing_tcp existing_udp
  local snapshot_output snapshot rollback_output rollback token state_file answer result=0 listen_status failure_stage=""
  trap 'rm -f "$firewall_candidate" "$fail2ban_candidate" "$fail2ban_stage"; trap - RETURN' RETURN
  case "$plan" in standard | firewall | fail2ban) ;; *)
    error "方案只允许 standard、firewall 或 fail2ban"
    return "$EXIT_USAGE"
    ;;
  esac
  validate_rollback_minutes "$rollback_minutes" || return $?
  old_ports="$(effective_sshd_ports)" || return $?
  new_port="$old_ports"
  if [[ "$plan" == standard && "$requested_port" != keep ]]; then
    new_port="$(validate_single_ssh_port "$requested_port")" || {
      error "SSH 新端口必须是 keep 或 1-65535 的单端口"
      return "$EXIT_USAGE"
    }
    if [[ ",$old_ports," == *",$new_port,"* ]]; then
      [[ "$old_ports" == "$new_port" ]] || {
        error "新端口已在多端口 SSH 配置中，请先用 SSH 子菜单整理"
        return "$EXIT_CONFLICT"
      }
      new_port="$old_ports"
    fi
  elif [[ "$plan" != standard && "$requested_port" != keep ]]; then
    error "只有标准防护方案可同时迁移 SSH 端口"
    return "$EXIT_USAGE"
  fi
  transition_ports="$old_ports"
  [[ "$new_port" == "$old_ports" ]] || transition_ports="$(merge_basic_ports "$old_ports" "$new_port")"
  if [[ "$new_port" != "$old_ports" ]]; then
    session_port="$(verified_ssh_session_port)" || return $?
    [[ ",$old_ports," == *",$session_port,"* ]] || {
      error "当前 SSH 会话端口 $session_port 不在 sshd 生效端口 $old_ports 中"
      return "$EXIT_CONFLICT"
    }
  fi
  tcp_ports="$(normalize_basic_ports "$tcp_input")" || {
    error "TCP 业务端口格式无效"
    return "$EXIT_USAGE"
  }
  udp_ports="$(normalize_basic_ports "$udp_input")" || {
    error "UDP 业务端口格式无效"
    return "$EXIT_USAGE"
  }
  ensure_no_pending_firewall_rollback || return $?
  ensure_no_pending_ssh_migration || return $?
  ensure_no_pending_ssh_enrollment || return $?

  if [[ "$plan" == standard || "$plan" == firewall ]]; then
    require_nft_command || return $?
    ensure_firewall_scope_owned_or_free || return $?
    require_firewall_write_preflight || return $?
    if [[ -r "$(firewall_state_path)" && "$(firewall_state_value enabled)" == 1 ]]; then
      existing_tcp="$(firewall_state_value tcp_ports)"
      existing_udp="$(firewall_state_value udp_ports)"
      advanced_rules="$(firewall_advanced_state_records)" || return $?
    else
      existing_tcp=""
      existing_udp=""
      advanced_rules=""
    fi
    tcp_ports="$(merge_basic_ports "$existing_tcp" "$tcp_ports")"
    udp_ports="$(merge_basic_ports "$existing_udp" "$udp_ports")"
    firewall_candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-wizard-firewall.XXXXXX")" || return "$EXIT_FAILURE"
    render_firewall_ruleset "$firewall_candidate" "$transition_ports" "$tcp_ports" "$udp_ports" "$advanced_rules" || result=$?
    [[ "$result" -eq 0 ]] && validate_firewall_candidate "$firewall_candidate" || result=$?
    if [[ "$result" -ne 0 ]]; then
      rm -f "$firewall_candidate"
      error "向导防火墙候选配置校验失败"
      return "$result"
    fi
  fi
  if [[ "$plan" == standard || "$plan" == fail2ban ]]; then
    fail2ban_is_installed || {
      rm -f "$firewall_candidate"
      show_fail2ban_install_plan
      error "请先单独安装 Fail2ban，再运行快速向导"
      return "$EXIT_CONFLICT"
    }
    ensure_fail2ban_config_owned_or_absent || return $?
    values="$(fail2ban_preset_values standard)" || return $?
    IFS=$'\t' read -r findtime maxretry bantime increment maxtime <<<"$values"
    current_ip="$(current_management_ip 2>/dev/null || true)"
    ignoreip="$(normalize_ignore_ips "$current_ip")" || return $?
    fail2ban_candidate="$(mktemp "${TMPDIR:-/tmp}/vps-guard-wizard-fail2ban.XXXXXX")" || return "$EXIT_FAILURE"
    render_fail2ban_config "$fail2ban_candidate" "$transition_ports" "$findtime" "$maxretry" "$bantime" "$increment" "$maxtime" "$ignoreip" || result=$?
    [[ "$result" -eq 0 ]] && validate_fail2ban_candidate "$fail2ban_candidate" || result=$?
    if [[ "$result" -ne 0 ]]; then
      rm -f "$firewall_candidate" "$fail2ban_candidate"
      error "向导 Fail2ban 候选配置校验失败"
      return "$result"
    fi
  fi
  if [[ "$new_port" != "$old_ports" ]]; then
    sshd -t || return "$EXIT_FAILURE"
    if ssh_port_is_listening "$new_port"; then
      error "SSH 新端口 $new_port 已被其他服务监听"
      return "$EXIT_CONFLICT"
    else
      listen_status=$?
      [[ "$listen_status" -eq 1 ]] || return "$listen_status"
    fi
  fi

  printf '快速安全配置统一差异与风险摘要\n方案：%s\nSSH：%s -> %s（过渡期：%s）\n' "$plan" "$old_ports" "$new_port" "$transition_ports"
  if [[ "$plan" == fail2ban ]]; then printf '防火墙：保持不变\n'; else printf '防火墙：入站默认拒绝；TCP %s；UDP %s\n' "${tcp_ports:-无}" "${udp_ports:-无}"; fi
  if [[ "$plan" == firewall ]]; then printf 'Fail2ban：保持不变\n'; else printf 'Fail2ban：standard；SSH 端口 %s；白名单 %s\n' "$transition_ports" "$ignoreip"; fi
  printf '最坏后果：SSH 或业务连接中断；请先确认云控制台、串行控制台或救援模式可用。\n'
  printf '事务保护：应用失败、未确认或超时会从同一个完整快照恢复。\n'
  if [[ "$DRY_RUN" -eq 1 ]]; then
    rm -f "$firewall_candidate" "$fail2ban_candidate"
    printf 'dry-run：不会写配置、重载服务或启动自动回滚。\n'
    return 0
  fi
  if [[ "$confirmed" -ne 1 ]]; then
    printf '确认一次性应用并启动 %s 分钟自动回滚？[y/N] ' "$rollback_minutes"
    IFS= read -r answer || answer=""
    case "$answer" in y | Y | yes | YES) ;; *)
      rm -f "$firewall_candidate" "$fail2ban_candidate"
      printf '已取消，未修改任何配置。\n'
      return 0
      ;;
    esac
  fi

  snapshot_label="wizard-before-$plan"
  snapshot_output="$(create_snapshot "$snapshot_label")" || return $?
  printf '%s\n' "$snapshot_output"
  snapshot="${snapshot_output#*快照已创建：}"
  snapshot="${snapshot%%$'\n'*}"
  hook="wizard-$plan"
  rollback_output="$(start_rollback "$snapshot" "$rollback_minutes" "$hook")" || return $?
  printf '%s\n' "$rollback_output"
  rollback="${rollback_output#*自动回滚已启动：}"
  rollback="${rollback%%$'\n'*}"
  token="wizard-$(date -u '+%Y%m%dT%H%M%SZ')-$$-$RANDOM"
  wizard_write_state "$token" "$snapshot" "$rollback" "$plan" "$old_ports" "$new_port" || {
    wizard_recover "$snapshot" "$rollback" "$hook" || true
    return "$EXIT_FAILURE"
  }
  state_file="$(wizard_state_directory "$token")/state"

  if [[ "$new_port" != "$old_ports" ]]; then
    failure_stage=ssh-write
    ensure_standard_ssh_dropin_include && install_ssh_migration_ports "$transition_ports" && sshd -t || result=$?
  fi
  if [[ "$result" -eq 0 && -n "$firewall_candidate" ]]; then
    failure_stage=firewall-write
    install_firewall_configuration "$firewall_candidate" "$transition_ports" "$tcp_ports" "$udp_ports" "$advanced_rules" || result=$?
  fi
  if [[ "$result" -eq 0 && -n "$fail2ban_candidate" ]]; then
    failure_stage=fail2ban-write
    fail2ban_stage="$(stage_fail2ban_candidate "$fail2ban_candidate")" || result=$?
    [[ "$result" -ne 0 ]] || mv "$fail2ban_stage" "$(fail2ban_config_path)" || result=$?
  fi
  rm -f "$firewall_candidate" "$fail2ban_candidate" "$fail2ban_stage"
  if [[ "$result" -eq 0 && "$plan" != fail2ban ]]; then
    failure_stage=firewall-runtime
    reload_firewall_runtime || result=$?
  fi
  if [[ "$result" -eq 0 && "$new_port" != "$old_ports" ]]; then
    failure_stage=ssh-runtime
    reload_sshd_runtime || result=$?
  fi
  if [[ "$result" -eq 0 && "$plan" != firewall ]]; then
    failure_stage=fail2ban-runtime
    reload_fail2ban_runtime || result=$?
  fi
  if [[ "$result" -eq 0 && "$new_port" != "$old_ports" ]]; then
    failure_stage=ssh-listener
    verify_sshd_transition_listeners "$transition_ports" || result=$?
  fi
  if [[ "$result" -ne 0 ]]; then
    wizard_mark_recovering_and_restore "$state_file" "$snapshot" "$rollback" "$hook" "$failure_stage" || true
    audit_event wizard.apply failure "token=$token plan=$plan snapshot=$snapshot"
    error "快速安全配置部分应用失败（阶段：${failure_stage}），已尝试恢复起始状态"
    return "$EXIT_FAILURE"
  fi
  if ! printf 'status=pending\n' >>"$state_file"; then
    wizard_mark_recovering_and_restore "$state_file" "$snapshot" "$rollback" "$hook" state-write || true
    audit_event wizard.apply failure "token=$token plan=$plan snapshot=$snapshot reason=state-write"
    error "快速安全配置状态写入失败，已尝试恢复起始状态"
    return "$EXIT_FAILURE"
  fi
  audit_event wizard.apply success "token=$token plan=$plan snapshot=$snapshot rollback=$rollback"
  printf '快速安全配置等待确认：%s\n' "$token"
  if [[ "$new_port" != "$old_ports" ]]; then
    printf '请保留当前会话，从新终端登录 SSH 端口 %s 后执行：vps-guard wizard confirm %s\n' "$new_port" "$token"
  else
    printf '请验证 SSH、业务端口和防护状态后执行：vps-guard wizard confirm %s\n' "$token"
  fi
}

wizard_confirm() {
  with_config_transaction_lock wizard_confirm_unlocked "$@"
}

wizard_confirm_unlocked() {
  local token="$1" state_file status plan old_ports new_port rollback snapshot session_port result=0 rollback_status
  wizard_load_state "$token" || return $?
  state_file="$WIZARD_STATE_FILE"
  status="$WIZARD_STATE_STATUS"
  plan="$WIZARD_STATE_PLAN"
  old_ports="$WIZARD_STATE_OLD_PORTS"
  new_port="$WIZARD_STATE_NEW_PORT"
  rollback="$WIZARD_STATE_ROLLBACK"
  snapshot="$WIZARD_STATE_SNAPSHOT"
  rollback_status="$WIZARD_STATE_ROLLBACK_STATUS"
  [[ "$status" != committed ]] || {
    printf '该快速安全配置已经提交。\n'
    return 0
  }
  if [[ "$status" == recovering ]]; then
    if wizard_mark_recovering_and_restore "$state_file" "$snapshot" "$rollback" "wizard-$plan" confirm-recovery; then
      error "此前提交失败的恢复已完成；目标配置未提交"
    else
      error "此前提交失败的恢复仍未完整完成"
    fi
    return "$EXIT_FAILURE"
  fi
  if [[ "$status" == committing && "$rollback_status" == confirmed ]]; then
    printf 'status=committed\ncommitted=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file" || return "$EXIT_FAILURE"
    printf '快速安全配置已提交；状态收尾已完成。\n'
    return 0
  fi
  [[ "$status" == pending || "$status" == committing ]] || {
    error "快速安全配置当前状态不能确认：$status"
    return "$EXIT_CONFLICT"
  }
  [[ "$rollback_status" == pending ]] || {
    error "关联自动回滚已不是等待确认状态：${rollback_status:-未知}"
    return "$EXIT_CONFLICT"
  }
  if [[ "$status" == pending && "$new_port" != "$old_ports" ]]; then
    session_port="$(verified_ssh_session_port)" || return $?
    [[ "$session_port" == "$new_port" ]] || {
      error "确认必须来自 SSH 新端口 $new_port；当前端口是 $session_port"
      return "$EXIT_CONFLICT"
    }
    install_ssh_migration_ports "$new_port" && sshd -t || result=$?
    if [[ "$result" -eq 0 && "$plan" != fail2ban ]]; then apply_managed_firewall_ssh_ports "$new_port" || result=$?; fi
    if [[ "$result" -eq 0 && "$plan" != firewall ]]; then sync_fail2ban_ssh_ports "$new_port" || result=$?; fi
    if [[ "$result" -eq 0 ]]; then reload_sshd_runtime || result=$?; fi
    if [[ "$result" -eq 0 ]]; then verify_sshd_committed_listeners "$new_port" "$old_ports" || result=$?; fi
  fi
  if [[ "$result" -eq 0 && "$status" == pending ]]; then
    if ! printf 'status=committing\n' >>"$state_file"; then
      wizard_mark_recovering_and_restore "$state_file" "$snapshot" "$rollback" "wizard-$plan" commit-state-write || true
      error "无法持久化提交中状态，已尝试恢复起始状态"
      return "$EXIT_FAILURE"
    fi
  fi
  if [[ "$result" -eq 0 ]]; then confirm_rollback "$rollback" 1 >/dev/null || result=$?; fi
  if [[ "$result" -ne 0 ]]; then
    wizard_mark_recovering_and_restore "$state_file" "$snapshot" "$rollback" "wizard-$plan" confirm || true
    error "快速安全配置提交失败，已尝试恢复起始状态"
    return "$EXIT_FAILURE"
  fi
  if ! printf 'status=committed\ncommitted=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >>"$state_file"; then
    error "配置与自动回滚已经提交，但向导状态收尾失败；修复存储后重试 wizard confirm $token"
    return "$EXIT_FAILURE"
  fi
  audit_event wizard.confirm success "token=$token plan=$plan"
  printf '快速安全配置已提交；自动回滚已取消。\n'
}

wizard_status() {
  local token="$1" state status rollback rollback_status
  wizard_load_state "$token" || return $?
  state="$WIZARD_STATE_FILE"
  status="$WIZARD_STATE_STATUS"
  rollback="$WIZARD_STATE_ROLLBACK"
  rollback_status="$WIZARD_STATE_ROLLBACK_STATUS"
  [[ "$rollback_status" != rolled-back ]] || status=rolled-back
  printf '快速安全配置：%s\n状态：%s\n方案：%s\nSSH：%s -> %s\n自动回滚：%s (%s)\n' \
    "$token" "$status" "$WIZARD_STATE_PLAN" \
    "$WIZARD_STATE_OLD_PORTS" "$WIZARD_STATE_NEW_PORT" \
    "$rollback" "${rollback_status:-未知}"
}

wizard_wait_for_advanced_transactions() {
  local answer
  while ! ensure_no_pending_firewall_rollback >/dev/null 2>&1 || ! ensure_no_pending_ssh_enrollment >/dev/null 2>&1; do
    printf '高级子菜单产生了独立的待确认事务。请在新会话完成对应确认；完成后按 Enter 重试，输入 cancel 放弃本次向导：'
    IFS= read -r answer || return "$EXIT_CONFLICT"
    [[ "$answer" != cancel ]] || return "$EXIT_CONFLICT"
  done
}

wizard_cli() {
  local action="${1:-}" plan="" standard_port=keep tcp_ports="" udp_ports="" minutes=5 confirmed=0
  case "$action" in
    details)
      [[ "$#" -eq 1 ]] || return "$EXIT_USAGE"
      wizard_show_details
      ;;
    status)
      [[ "$#" -eq 2 ]] || return "$EXIT_USAGE"
      wizard_status "$2"
      ;;
    confirm)
      [[ "$#" -eq 2 ]] || return "$EXIT_USAGE"
      wizard_confirm "$2"
      ;;
    apply)
      shift
      while [[ "$#" -gt 0 ]]; do
        case "$1" in
          --plan)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            plan="$2"
            shift 2
            ;;
          --ssh-port)
            [[ "$#" -ge 2 ]] || return "$EXIT_USAGE"
            standard_port="$2"
            shift 2
            ;;
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
            minutes="$2"
            shift 2
            ;;
          --yes)
            confirmed=1
            shift
            ;;
          *)
            error "wizard apply 未知参数：$1"
            return "$EXIT_USAGE"
            ;;
        esac
      done
      [[ -n "$plan" ]] || {
        error "必须指定 --plan standard|firewall|fail2ban"
        return "$EXIT_USAGE"
      }
      wizard_apply "$plan" "$standard_port" "$tcp_ports" "$udp_ports" "$minutes" "$confirmed"
      ;;
    *)
      error "用法：vps-guard wizard <details|apply|status|confirm>"
      return "$EXIT_USAGE"
      ;;
  esac
}

show_quick_security_menu() {
  local choice plan ssh_port tcp_detected udp_detected tcp_ports udp_ports advanced minutes
  while true; do
    printf '快速安全配置\n1. 标准防护（推荐）\n2. 仅防火墙\n3. 仅 Fail2ban\n4. 查看方案详情\n0. 返回主菜单\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      4)
        wizard_show_details
        continue
        ;;
      1) plan=standard ;;
      2) plan=firewall ;;
      3) plan=fail2ban ;;
      *)
        printf '无效选项，请重新输入。\n'
        continue
        ;;
    esac
    ssh_port=keep
    tcp_ports=""
    udp_ports=""
    if [[ "$plan" == standard ]]; then
      printf 'SSH 新端口（留空保持当前端口）：'
      IFS= read -r ssh_port || return 0
      ssh_port="${ssh_port:-keep}"
    fi
    if [[ "$plan" != fail2ban ]]; then
      if ! tcp_detected="$(wizard_detect_listening_ports tcp)"; then
        tcp_detected=""
        printf '检测到监听 TCP：未知（ss 不可读，请手工填写）\n'
      else
        printf '检测到监听 TCP：%s\n' "${tcp_detected:-无}"
      fi
      if ! udp_detected="$(wizard_detect_listening_ports udp)"; then
        udp_detected=""
        printf '检测到监听 UDP：未知（ss 不可读，请手工填写）\n'
      else
        printf '检测到监听 UDP：%s\n' "${udp_detected:-无}"
      fi
      printf '开放 TCP 业务端口（留空采用检测值）：'
      IFS= read -r tcp_ports || return 0
      printf '开放 UDP 业务端口（留空采用检测值）：'
      IFS= read -r udp_ports || return 0
      tcp_ports="${tcp_ports:-$tcp_detected}"
      udp_ports="${udp_ports:-$udp_detected}"
    fi
    while true; do
      printf '高级设置 [ssh/firewall/fail2ban/continue，默认continue]：'
      IFS= read -r advanced || return 0
      case "${advanced:-continue}" in
        ssh)
          printf '提示：高级子菜单使用独立事务；确认完成后返回，当前向导输入会保留。\n'
          show_ssh_menu
          wizard_wait_for_advanced_transactions || return 0
          ;;
        firewall)
          printf '提示：高级子菜单使用独立事务；确认完成后返回，当前向导输入会保留。\n'
          show_firewall_menu
          wizard_wait_for_advanced_transactions || return 0
          ;;
        fail2ban)
          printf '提示：高级子菜单使用独立事务；确认完成后返回，当前向导输入会保留。\n'
          show_fail2ban_menu
          wizard_wait_for_advanced_transactions || return 0
          ;;
        continue) break ;;
        *) printf '无效选项。\n' ;;
      esac
    done
    minutes=5
    wizard_apply "$plan" "$ssh_port" "$tcp_ports" "$udp_ports" "$minutes" 0 || true
  done
}
