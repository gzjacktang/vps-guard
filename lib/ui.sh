#!/usr/bin/env bash

show_status() {
  detect_system

  printf 'VPS Guard 系统状态\n'
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '模式：dry-run（只读，不会修改系统）\n'
  fi
  printf '系统：%s\n' "${OS_PRETTY_NAME:-未知}"
  printf '版本：%s\n' "${OS_VERSION:-未知}"
  printf '架构：%s\n' "$SYSTEM_ARCH"
  printf '运行权限：root\n'
  printf '支持状态：%s\n' "$SUPPORT_STATUS"
  check_dependencies
  show_dependency_install_plan
  show_ssh_status
  show_listening_ports

  if [[ "$SUPPORT_STATUS" != "正式支持" ]]; then
    return "$EXIT_UNSUPPORTED"
  fi
}

show_main_menu() {
  local choice

  while true; do
    printf 'VPS Guard\n'
    printf '1. 快速安全配置\n'
    printf '2. SSH 管理\n'
    printf '3. 防火墙管理\n'
    printf '4. Fail2ban 管理\n'
    printf '5. 状态与诊断\n'
    printf '6. 备份与恢复\n'
    printf '7. 设置、更新与卸载\n'
    printf '0. 退出\n'
    printf '请选择：'

    if ! IFS= read -r choice; then
      printf '\n输入已结束。\n'
      return 0
    fi

    case "$choice" in
      0)
        printf '已退出。\n'
        return 0
        ;;
      5)
        show_diagnostics_menu
        ;;
      3)
        show_firewall_menu
        ;;
      2)
        show_ssh_menu
        ;;
      6)
        show_backup_menu
        ;;
      4)
        show_fail2ban_menu
        ;;
      1 | 7)
        printf '该功能将在后续实施切片中提供。\n'
        ;;
      *)
        printf '无效选项，请重新输入。\n'
        ;;
    esac
  done
}

show_ssh_menu() {
  local choice user token minutes
  while true; do
    printf 'SSH 管理\n'
    printf '1. 查看实际配置与风险\n'
    printf '2. SSH 端口管理\n'
    printf '3. SSH 密钥设置\n'
    printf '4. 可选 SSH 加固\n'
    printf '5. SSH 快照恢复\n'
    printf '0. 返回主菜单\n'
    printf '请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1)
        printf '目标用户：'
        IFS= read -r user || return 0
        inspect_ssh_effective_config "$user" || true
        ;;
      2) show_ssh_port_menu ;;
      3) show_ssh_key_menu ;;
      4) show_ssh_hardening_menu ;;
      5)
        printf '目标快照 ID：'
        IFS= read -r token || return 0
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        restore_ssh_from_snapshot "$token" "${minutes:-5}" 0 || true
        ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_ssh_port_menu() {
  local choice port minutes token
  while true; do
    printf 'SSH 端口管理\n1. 迁移端口\n2. 从新端口确认\n3. 查看迁移状态\n4. 重置到 22\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1 | 4)
        if [[ "$choice" == "1" ]]; then
          printf '新 SSH 端口：'
          IFS= read -r port || return 0
        else
          port=22
          printf '警告：重置到 22 会改变当前入口，并可能暴露标准端口。\n'
        fi
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        if [[ "$choice" == "4" ]]; then
          start_ssh_port_migration "$port" "${minutes:-5}" 0 1 1 || true
        else
          start_ssh_port_migration "$port" "${minutes:-5}" 0 || true
        fi
        ;;
      2 | 3)
        printf 'SSH 迁移令牌：'
        IFS= read -r token || return 0
        if [[ "$choice" == "2" ]]; then
          confirm_ssh_port_migration "$token" || true
        else
          show_ssh_migration_status "$token" || true
        fi
        ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_ssh_key_menu() {
  local choice user file token
  while true; do
    printf 'SSH 密钥设置\n'
    printf '1. 客户端 Ed25519 生成引导\n2. 导入并校验公钥\n3. 服务器端生成加密密钥（备用）\n'
    printf '4. 从新密钥会话确认\n5. 查看状态\n6. 放弃待确认密钥\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1 | 2 | 3)
        printf '目标用户：'
        IFS= read -r user || return 0
        case "$choice" in
          1) show_client_key_guide "$user" || true ;;
          2)
            printf '服务器上的公钥文件路径：'
            IFS= read -r file || return 0
            ssh_key_cli import --user "$user" --file "$file" || true
            ;;
          3) ssh_key_cli generate-server --user "$user" || true ;;
        esac
        ;;
      4 | 5 | 6)
        printf 'SSH 密钥令牌：'
        IFS= read -r token || return 0
        case "$choice" in
          4) confirm_ssh_key_enrollment "$token" || true ;;
          5) show_ssh_key_status "$token" || true ;;
          6) discard_ssh_key_enrollment "$token" || true ;;
        esac
        ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_ssh_hardening_menu() {
  local choice user proof password root empty tries grace minutes token
  while true; do
    printf '可选 SSH 加固\n1. 应用或调整加固\n2. 从新密钥会话确认\n3. 查看加固状态\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1)
        printf '目标确认用户：'
        IFS= read -r user || return 0
        printf '已验证密钥 proof（禁用密码时必填）：'
        IFS= read -r proof || return 0
        printf '密码登录 [keep/yes/no，默认keep]：'
        IFS= read -r password || return 0
        printf 'root 登录 [keep/yes/prohibit-password/no，默认keep]：'
        IFS= read -r root || return 0
        printf '空密码 [keep/yes/no，默认keep]：'
        IFS= read -r empty || return 0
        printf '认证重试 [keep/1-10，默认keep]：'
        IFS= read -r tries || return 0
        printf '登录等待秒数 [keep/10-120，默认keep]：'
        IFS= read -r grace || return 0
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        start_ssh_hardening "$user" "$proof" "${password:-keep}" "${root:-keep}" "${empty:-keep}" \
          "${tries:-keep}" "${grace:-keep}" "${minutes:-5}" 0 || true
        ;;
      2 | 3)
        printf 'SSH 加固令牌：'
        IFS= read -r token || return 0
        if [[ "$choice" == "2" ]]; then
          confirm_ssh_hardening "$token" || true
        else
          show_ssh_hardening_status "$token" || true
        fi
        ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_firewall_menu() {
  local choice ports protocol tcp_ports udp_ports minutes
  while true; do
    printf '防火墙管理\n'
    printf '1. 查看状态\n'
    printf '2. 启用安全基线\n'
    printf '3. 开放基础端口\n'
    printf '4. 关闭基础端口\n'
    printf '5. 停用 VPS Guard 防火墙\n'
    printf '6. 高级规则与三层端口状态\n'
    printf '0. 返回主菜单\n'
    printf '请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1) show_firewall_status || true ;;
      2)
        printf '额外 TCP 端口（逗号列表，可留空）：'
        IFS= read -r tcp_ports || return 0
        printf '额外 UDP 端口（逗号列表，可留空）：'
        IFS= read -r udp_ports || return 0
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        enable_firewall "$tcp_ports" "$udp_ports" "${minutes:-5}" 0 || true
        ;;
      3 | 4)
        printf '端口（单个或逗号列表）：'
        IFS= read -r ports || return 0
        printf '协议 [tcp/udp/both]：'
        IFS= read -r protocol || return 0
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        if [[ "$choice" == "3" ]]; then
          change_firewall_ports open "$ports" "$protocol" "${minutes:-5}" 0 || true
        else
          change_firewall_ports close "$ports" "$protocol" "${minutes:-5}" 0 || true
        fi
        ;;
      5)
        printf '警告：停用后 VPS Guard 不再过滤任何端口。\n'
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        disable_firewall "${minutes:-5}" 0 || true
        ;;
      6) show_advanced_firewall_menu ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_advanced_firewall_menu() {
  local choice mode ports protocol direction family source interface minutes external
  while true; do
    printf '高级防火墙\n1. 开放高级规则\n2. 关闭高级规则\n3. 查询三层端口状态\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1 | 2)
        [[ "$choice" == 1 ]] && mode=open || mode=close
        printf '端口（单值/列表/范围/混合）：'
        IFS= read -r ports || return 0
        printf '协议 [tcp/udp/both]：'
        IFS= read -r protocol || return 0
        printf '方向 [inbound/outbound，默认inbound]：'
        IFS= read -r direction || return 0
        printf '地址族 [ipv4/ipv6/dual，默认dual]：'
        IFS= read -r family || return 0
        printf '来源 [all/IP/CIDR，出站时表示本机源地址，默认all]：'
        IFS= read -r source || return 0
        printf '接口（留空表示全部；入站iifname/出站oifname）：'
        IFS= read -r interface || return 0
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        change_advanced_firewall_rule "$mode" "$ports" "$protocol" "${direction:-inbound}" \
          "${family:-dual}" "${source:-all}" "$interface" "${minutes:-5}" 0 || true
        ;;
      3)
        printf '端口（单值/列表/范围/混合）：'
        IFS= read -r ports || return 0
        printf '协议 [tcp/udp/both]：'
        IFS= read -r protocol || return 0
        printf '方向 [inbound/outbound，默认inbound]：'
        IFS= read -r direction || return 0
        printf '地址族 [ipv4/ipv6/dual，默认dual]：'
        IFS= read -r family || return 0
        printf '来源 [all/IP/CIDR，默认all]：'
        IFS= read -r source || return 0
        printf '接口（留空表示全部）：'
        IFS= read -r interface || return 0
        printf '外部验证 [reachable/blocked/unverified，默认unverified]：'
        IFS= read -r external || return 0
        show_firewall_port_status "$ports" "$protocol" "${direction:-inbound}" "${family:-dual}" \
          "${source:-all}" "$interface" "${external:-unverified}" || true
        ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_diagnostics_menu() {
  local choice
  while true; do
    printf '状态与诊断\n'
    printf '1. 系统状态\n'
    printf '2. 网络环境预检\n'
    printf '0. 返回主菜单\n'
    printf '请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1) show_status || true ;;
      2) show_preflight_report || true ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_backup_menu() {
  local choice value minutes
  while true; do
    printf '备份与恢复\n'
    printf '1. 创建快照\n'
    printf '2. 列出快照\n'
    printf '3. 比较快照\n'
    printf '4. 恢复快照\n'
    printf '5. 启动自动回滚\n'
    printf '6. 查询自动回滚\n'
    printf '7. 确认并取消自动回滚\n'
    printf '8. 设置快照保留数量\n'
    printf '0. 返回主菜单\n'
    printf '请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1)
        printf '快照标签：'
        IFS= read -r value || return 0
        create_snapshot "${value:-manual}"
        ;;
      2) list_snapshots ;;
      3)
        printf '快照 ID：'
        IFS= read -r value || return 0
        diff_snapshot "$value"
        ;;
      4)
        printf '警告：恢复会覆盖当前受管配置。\n快照 ID：'
        IFS= read -r value || return 0
        restore_snapshot "$value" 0
        ;;
      5)
        printf '快照 ID：'
        IFS= read -r value || return 0
        printf '回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        start_rollback "$value" "${minutes:-5}"
        ;;
      6)
        printf '回滚令牌：'
        IFS= read -r value || return 0
        show_rollback_status "$value"
        ;;
      7)
        printf '回滚令牌：'
        IFS= read -r value || return 0
        confirm_rollback "$value"
        ;;
      8)
        printf '保留数量 [1-100]：'
        IFS= read -r value || return 0
        backup_cli retention "$value"
        ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}

show_help() {
  printf '用法：vps-guard [--dry-run] [status|preflight|ssh|firewall|fail2ban|backup|rollback|audit|help]\n'
}

show_fail2ban_menu() {
  local choice preset ip minutes snapshot findtime maxretry bantime increment maxtime
  while true; do
    printf 'Fail2ban 管理\n1. 安装 Fail2ban\n2. 应用 SSH 防护策略\n3. 查看状态\n4. 查看封禁列表\n5. 解封 IP\n6. 停用自有配置\n7. 从快照恢复自有配置\n0. 返回\n请选择：'
    IFS= read -r choice || return 0
    case "$choice" in
      0) return 0 ;;
      1) install_fail2ban_package 0 || true ;;
      2)
        printf '策略 [lenient/standard/strict/progressive/custom，默认standard]：'
        IFS= read -r preset || return 0
        preset="${preset:-standard}"
        if [[ "$preset" == custom ]]; then
          printf '统计窗口秒数 findtime [60-86400]：'
          IFS= read -r findtime || return 0
          printf '失败次数 maxretry [1-20]：'
          IFS= read -r maxretry || return 0
          printf '首次封禁秒数 bantime [60-604800]：'
          IFS= read -r bantime || return 0
          printf '渐进封禁 [true/false，默认false]：'
          IFS= read -r increment || return 0
          printf '最长封禁秒数 [不小于bantime，最大2592000]：'
          IFS= read -r maxtime || return 0
          fail2ban_cli apply --preset custom --findtime "$findtime" --maxretry "$maxretry" \
            --bantime "$bantime" --increment "${increment:-false}" --max-bantime "${maxtime:-604800}" || true
        else
          fail2ban_cli apply --preset "$preset" || true
        fi
        ;;
      3) show_fail2ban_status || true ;;
      4) show_fail2ban_banned || true ;;
      5)
        printf '要解封的 IPv4/IPv6：'
        IFS= read -r ip || return 0
        unban_fail2ban_ip "$ip" || true
        ;;
      6)
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        disable_fail2ban "${minutes:-5}" 0 || true
        ;;
      7)
        printf '快照 ID：'
        IFS= read -r snapshot || return 0
        printf '自动回滚分钟数 [3/5/10，默认5]：'
        IFS= read -r minutes || return 0
        restore_fail2ban_from_snapshot "$snapshot" "${minutes:-5}" 0 || true
        ;;
      *) printf '无效选项，请重新输入。\n' ;;
    esac
  done
}
