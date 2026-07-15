#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

VPS_GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/core.sh
source "$VPS_GUARD_ROOT/lib/core.sh"
# shellcheck source=lib/system.sh
source "$VPS_GUARD_ROOT/lib/system.sh"
# shellcheck source=lib/ui.sh
source "$VPS_GUARD_ROOT/lib/ui.sh"

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
