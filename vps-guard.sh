#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

VPS_GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/core.sh
source "$VPS_GUARD_ROOT/lib/core.sh"
# shellcheck source=lib/system.sh
source "$VPS_GUARD_ROOT/lib/system.sh"
# shellcheck source=lib/preflight.sh
source "$VPS_GUARD_ROOT/lib/preflight.sh"
# shellcheck source=lib/ui.sh
source "$VPS_GUARD_ROOT/lib/ui.sh"
# shellcheck source=lib/backup.sh
source "$VPS_GUARD_ROOT/lib/backup.sh"
# shellcheck source=lib/rollback.sh
source "$VPS_GUARD_ROOT/lib/rollback.sh"
# shellcheck source=lib/firewall_rules.sh
source "$VPS_GUARD_ROOT/lib/firewall_rules.sh"
# shellcheck source=lib/firewall.sh
source "$VPS_GUARD_ROOT/lib/firewall.sh"
# shellcheck source=lib/firewall_advanced.sh
source "$VPS_GUARD_ROOT/lib/firewall_advanced.sh"
# shellcheck source=lib/ssh.sh
source "$VPS_GUARD_ROOT/lib/ssh.sh"
# shellcheck source=lib/ssh_hardening.sh
source "$VPS_GUARD_ROOT/lib/ssh_hardening.sh"
# shellcheck source=lib/fail2ban.sh
source "$VPS_GUARD_ROOT/lib/fail2ban.sh"

DRY_RUN=0

main() {
  local command

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --)
        shift
        break
        ;;
      *)
        break
        ;;
    esac
  done

  command="${1:-menu}"

  case "$command" in
    status)
      if [[ "$#" -gt 1 ]]; then
        error "status 不接受额外参数"
        return "$EXIT_USAGE"
      fi
      require_root
      show_status
      ;;
    menu)
      if [[ "$#" -gt 1 ]]; then
        error "menu 不接受额外参数"
        return "$EXIT_USAGE"
      fi
      require_root
      show_main_menu
      ;;
    backup)
      require_root
      backup_cli "${@:2}"
      ;;
    rollback)
      require_root
      rollback_cli "${@:2}"
      ;;
    preflight)
      require_root
      preflight_cli "${@:2}"
      ;;
    firewall)
      require_root
      firewall_cli "${@:2}"
      ;;
    ssh)
      require_root
      ssh_cli "${@:2}"
      ;;
    fail2ban)
      require_root
      fail2ban_cli "${@:2}"
      ;;
    audit)
      require_root
      if [[ "$#" -eq 2 && "$2" == "list" ]]; then
        show_audit_log
      else
        error "用法：vps-guard audit list"
        return "$EXIT_USAGE"
      fi
      ;;
    --help | -h | help)
      if [[ "$#" -gt 1 ]]; then
        error "help 不接受额外参数"
        return "$EXIT_USAGE"
      fi
      show_help
      ;;
    *)
      error "未知命令：$command"
      show_help >&2
      return "$EXIT_USAGE"
      ;;
  esac
}

main "$@"
