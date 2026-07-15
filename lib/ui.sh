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
        show_status
        ;;
      6)
        show_backup_menu
        ;;
      1 | 2 | 3 | 4 | 7)
        printf '该功能将在后续实施切片中提供。\n'
        ;;
      *)
        printf '无效选项，请重新输入。\n'
        ;;
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
  printf '用法：vps-guard [--dry-run] [status|backup|rollback|audit|help]\n'
}
