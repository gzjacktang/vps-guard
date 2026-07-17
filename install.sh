#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

# 安装器只处理本地、已由用户下载并校验的源码目录；它不联网，也不执行远程内容。
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREFIX="${VPS_GUARD_INSTALL_PREFIX:-/usr/local}"
PROGRAM_ROOT="$PREFIX/lib/vps-guard"
RELEASES_ROOT="$PROGRAM_ROOT/releases"
CURRENT_LINK="$PROGRAM_ROOT/current"
COMMAND_LINK="$PREFIX/sbin/vps-guard"
VERSION_FILE="$SOURCE_ROOT/VERSION"
if [[ -n "${VPS_GUARD_INSTALL_DATA_DIR:-}" ]]; then
  DATA_DIR="$VPS_GUARD_INSTALL_DATA_DIR"
elif [[ "$PREFIX" == /usr/local ]]; then
  DATA_DIR=/var/lib/vps-guard
else
  DATA_DIR="$PREFIX/var/lib/vps-guard"
fi
if [[ -n "${VPS_GUARD_LIFECYCLE_LOCK:-}" ]]; then
  LIFECYCLE_LOCK="$VPS_GUARD_LIFECYCLE_LOCK"
elif [[ "$PREFIX" == /usr/local ]]; then
  LIFECYCLE_LOCK=/run/lock/vps-guard-lifecycle.lock
else
  LIFECYCLE_LOCK="$PREFIX/var/lock/vps-guard-lifecycle.lock"
fi
CONFIG_LOCK="$DATA_DIR/config-transaction.lock"
INSTALL_SIGNATURE=vps-guard-managed-install-v1
LAUNCHER_SIGNATURE='# VPS Guard managed launcher v1'
DRY_RUN=0
ASSUME_YES=0
MODE=install

usage() {
  printf '用法：sudo ./install.sh [--update] [--dry-run] [--yes]\n'
  printf '  默认安装本地源码；--update 只从当前本地目录更新，不下载或执行远程脚本。\n'
}

valid_version() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]
}

file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

file_owner() {
  stat -c '%u' "$1" 2>/dev/null || stat -f '%u' "$1"
}

managed_launcher_is_valid() {
  local expected
  [[ -f "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]] || return 1
  [[ "$(sed -n '1p' "$COMMAND_LINK")" == '#!/usr/bin/env bash' ]] || return 1
  [[ "$(sed -n '2p' "$COMMAND_LINK")" == "$LAUNCHER_SIGNATURE" ]] || return 1
  expected="$(printf 'exec %q "$@"' "$CURRENT_LINK/vps-guard.sh")"
  [[ "$(sed -n '3p' "$COMMAND_LINK")" == "$expected" ]] || return 1
  [[ "$(file_mode "$COMMAND_LINK")" == 755 ]] || return 1
  [[ "$PREFIX" != /usr/local || "$(file_owner "$COMMAND_LINK")" == 0 ]]
}

active_release_directory() {
  local target version directory releases_directory manifest
  [[ -d "$PROGRAM_ROOT" && ! -L "$PROGRAM_ROOT" && -L "$CURRENT_LINK" ]] || return 1
  target="$(readlink "$CURRENT_LINK")" || return 1
  case "$target" in releases/*) version="${target#releases/}" ;; *) return 1 ;; esac
  valid_version "$version" || return 1
  [[ "$target" == "releases/$version" ]] || return 1
  directory="$RELEASES_ROOT/$version"
  [[ -d "$directory" && ! -L "$directory" ]] || return 1
  directory="$(cd "$directory" && pwd -P)" || return 1
  releases_directory="$(cd "$RELEASES_ROOT" && pwd -P)" || return 1
  case "$directory" in "$releases_directory"/*) ;; *) return 1 ;; esac
  [[ "${directory##*/}" == "$version" ]] || return 1
  [[ -f "$directory/VERSION" && ! -L "$directory/VERSION" && "$(sed -n '1p' "$directory/VERSION")" == "$version" ]] || return 1
  manifest="$directory/INSTALL-MANIFEST"
  [[ -f "$manifest" && ! -L "$manifest" ]] || return 1
  [[ "$(sed -n 's/^signature=//p' "$manifest")" == "$INSTALL_SIGNATURE" ]] || return 1
  [[ "$(sed -n 's/^version=//p' "$manifest")" == "$version" ]] || return 1
  [[ -x "$directory/vps-guard.sh" && -d "$directory/lib" ]] || return 1
  [[ "$PREFIX" != /usr/local || "$(file_owner "$directory")" == 0 ]] || return 1
  printf '%s\n' "$directory"
}

transaction_state_is_nonterminal() {
  local state="$1" kind="$2" status count
  [[ -f "$state" && ! -L "$state" && -r "$state" ]] || return 0
  count="$(grep -c '^status=' "$state" || true)"
  [[ "$count" -ge 1 ]] || return 0
  status="$(sed -n 's/^status=//p' "$state" | tail -1)"
  if [[ "$kind" == rollback ]]; then
    case "$status" in confirmed | rolled-back) return 1 ;; *) return 0 ;; esac
  else
    case "$status" in verified | discarded) return 1 ;; *) return 0 ;; esac
  fi
}

has_nonterminal_transactions() {
  local directory state
  for directory in "$DATA_DIR"/rollbacks/*; do
    [[ -e "$directory" || -L "$directory" ]] || continue
    [[ -d "$directory" && ! -L "$directory" ]] || return 0
    state="$directory/state"
    transaction_state_is_nonterminal "$state" rollback && return 0
  done
  for directory in "$DATA_DIR"/ssh-enrollments/*; do
    [[ -e "$directory" || -L "$directory" ]] || continue
    [[ -d "$directory" && ! -L "$directory" ]] || return 0
    state="$directory/state"
    transaction_state_is_nonterminal "$state" enrollment && return 0
  done
  return 1
}

acquire_lifecycle_lock() {
  install -d -m 0700 "$DATA_DIR" "$(dirname "$LIFECYCLE_LOCK")"
  if ! mkdir "$LIFECYCLE_LOCK" 2>/dev/null; then
    printf '错误：另一个安装、更新或卸载事务正在运行。\n' >&2
    return 3
  fi
  printf '%s\n' "$$" >"$LIFECYCLE_LOCK/pid"
  if [[ -e "$CONFIG_LOCK" || -L "$CONFIG_LOCK" ]]; then
    printf '错误：安全配置事务正在运行，拒绝切换程序版本。\n' >&2
    rm -rf "$LIFECYCLE_LOCK"
    return 3
  fi
  if has_nonterminal_transactions; then
    printf '错误：存在未完成或状态异常的回滚/密钥清理事务，拒绝切换程序版本。\n' >&2
    rm -rf "$LIFECYCLE_LOCK"
    return 3
  fi
}

release_lifecycle_lock() {
  rm -rf "$LIFECYCLE_LOCK"
}

switch_current() {
  local target="$1" temp="$PROGRAM_ROOT/.current-$$" old_target=""
  [[ ! -L "$CURRENT_LINK" ]] || old_target="$(readlink "$CURRENT_LINK")"
  ln -s "$target" "$temp" || return 1
  if mv --help 2>&1 | grep -q -- ' -T'; then
    mv -Tf "$temp" "$CURRENT_LINK"
  else
    rm -f "$CURRENT_LINK" || return 1
    if ! mv -f "$temp" "$CURRENT_LINK"; then
      [[ -z "$old_target" ]] || ln -s "$old_target" "$CURRENT_LINK"
      return 1
    fi
  fi
}

for argument in "$@"; do
  case "$argument" in
    --update) MODE=update ;;
    --dry-run) DRY_RUN=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      printf '错误：未知参数：%s\n' "$argument" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -r "$VERSION_FILE" ]] || {
  printf '错误：源码目录缺少 VERSION。\n' >&2
  exit 1
}
VERSION="$(sed -n '1p' "$VERSION_FILE")"
valid_version "$VERSION" || {
  printf '错误：VERSION 格式无效：%s\n' "$VERSION" >&2
  exit 1
}
INSTALL_DIR="$RELEASES_ROOT/$VERSION"

dependency_status() {
  local command="$1" purpose="$2"
  if command -v "$command" >/dev/null 2>&1; then
    printf '依赖 %-16s 已安装（%s）\n' "$command" "$purpose"
  else
    printf '依赖 %-16s 缺失（%s）\n' "$command" "$purpose"
  fi
}

active_version="未安装"
active_dir=""
if [[ -e "$PROGRAM_ROOT" || -L "$PROGRAM_ROOT" || -e "$COMMAND_LINK" || -L "$COMMAND_LINK" ]]; then
  if ! active_dir="$(active_release_directory)" || ! managed_launcher_is_valid; then
    printf '错误：现有程序布局或 launcher 归属不可信，拒绝覆盖。\n' >&2
    exit 3
  fi
  active_version="${active_dir##*/}"
fi

printf 'VPS Guard %s计划\n' "$([[ "$MODE" == update ]] && printf 更新 || printf 安装)"
printf '本地源码：%s\n' "$SOURCE_ROOT"
printf '源码版本：%s\n' "$VERSION"
printf '当前版本：%s\n' "$active_version"
printf '版本目录：%s\n' "$INSTALL_DIR"
printf '稳定入口：%s（固定 launcher -> %s/current/vps-guard.sh）\n' "$COMMAND_LINK" "$PROGRAM_ROOT"
printf '文件权限：版本目录 0755，入口脚本 0755，模块/VERSION/LICENSE/manifest 0644\n'
printf '更新边界：不联网、不下载、不执行远程内容；请先核对 Release 的 SHA256SUMS。\n'
printf '运行依赖检查：\n'
dependency_status bash 'Bash 5.x 运行时'
dependency_status install '安全复制与权限设置'
dependency_status ln '稳定命令入口'
dependency_status cp '更新前程序备份'
dependency_status mv '版本切换'
dependency_status readlink '安装布局校验'
dependency_status sed '版本与 manifest 校验'
dependency_status grep '事务状态校验'
dependency_status date '程序备份时间戳'
dependency_status sshd 'SSH 检查与迁移'
dependency_status systemctl '服务重载与自动回滚'
dependency_status nft 'nftables 防火墙'
dependency_status ss '监听端口检测'
dependency_status diff '快照比较'
dependency_status fail2ban-client 'Fail2ban 防护（可选）'

if [[ "$MODE" == update && -z "$active_dir" ]]; then
  printf '错误：未检测到已安装版本；首次安装不要使用 --update。\n' >&2
  exit 1
fi
if [[ "$MODE" == install && -n "$active_dir" ]]; then
  printf '错误：已安装 %s；请使用当前 Release 目录中的 ./install.sh --update。\n' "$active_version" >&2
  exit 3
fi
if [[ "$MODE" == update && "$active_version" == "$VERSION" ]]; then
  printf '当前已经是 %s，无需替换。\n' "$VERSION"
  exit 0
fi
if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
  printf '错误：目标版本目录已存在，拒绝覆盖：%s\n' "$INSTALL_DIR" >&2
  exit 3
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  if [[ "$MODE" == update ]]; then
    printf 'dry-run：更新时会先备份 %s，再以原子 rename 切换 current。\n' "$active_dir"
  fi
  printf 'dry-run：未写入任何文件。\n'
  exit 0
fi

if [[ "${BASH_VERSINFO[0]}" -lt 5 && "$PREFIX" == /usr/local ]]; then
  printf '错误：安装需要 Bash 5.x 或更高版本。\n' >&2
  exit 5
fi
if [[ "$(id -u)" -ne 0 && "$PREFIX" == /usr/local ]]; then
  printf '错误：安装到 /usr/local 需要 root 权限，请使用 sudo ./install.sh。\n' >&2
  exit 4
fi
for command in install ln cp mv readlink sed grep date stat; do
  command -v "$command" >/dev/null 2>&1 || {
    printf '错误：安装依赖缺失：%s\n' "$command" >&2
    exit 5
  }
done

if [[ "$ASSUME_YES" -ne 1 ]]; then
  printf '确认从上述本地源码%s？[y/N] ' "$([[ "$MODE" == update ]] && printf 更新 || printf 安装)"
  IFS= read -r answer
  case "$answer" in y | Y | yes | YES) ;; *)
    printf '已取消%s。\n' "$([[ "$MODE" == update ]] && printf 更新 || printf 安装)"
    exit 0
    ;;
  esac
fi

lock_acquired=0
success=0
new_release_created=0
current_switched=0
staging="$PROGRAM_ROOT/.staging-$VERSION-$$"
launcher_temp="$PREFIX/sbin/.vps-guard-launcher-$$"
cleanup_install() {
  rm -rf "$staging"
  rm -f "$launcher_temp" "$PROGRAM_ROOT/.current-$$"
  if [[ "$success" -ne 1 && "$new_release_created" -eq 1 ]]; then
    if [[ "$MODE" == install && "$current_switched" -eq 1 && -L "$CURRENT_LINK" && "$(readlink "$CURRENT_LINK")" == "releases/$VERSION" ]]; then
      rm -f "$CURRENT_LINK"
    fi
    if [[ "$MODE" == install ]] && managed_launcher_is_valid; then rm -f "$COMMAND_LINK"; fi
    rm -rf "$INSTALL_DIR"
    if [[ "$MODE" == install ]]; then rmdir "$RELEASES_ROOT" "$PROGRAM_ROOT" 2>/dev/null || true; fi
  fi
  [[ "$lock_acquired" -ne 1 ]] || release_lifecycle_lock
}
trap cleanup_install EXIT INT TERM

acquire_lifecycle_lock
lock_acquired=1
# 获得互斥锁后重新验证，关闭计划展示与实际写入之间的竞态窗口。
if [[ "$MODE" == update ]]; then
  if active_dir="$(active_release_directory)" && managed_launcher_is_valid; then
    : # 布局有效，继续
  else
    printf '错误：锁内复检发现安装布局已变化。\n' >&2
    exit 3
  fi
  active_version="${active_dir##*/}"
  valid_version "$active_version" || exit 3
  [[ "$active_version" != "$VERSION" ]] || {
    success=1
    printf '当前已经是 %s，无需替换。\n' "$VERSION"
    exit 0
  }
else
  [[ ! -e "$PROGRAM_ROOT" && ! -L "$PROGRAM_ROOT" && ! -e "$COMMAND_LINK" && ! -L "$COMMAND_LINK" ]] || {
    printf '错误：锁内复检发现目标不再为空。\n' >&2
    exit 3
  }
fi

timestamp="$(date -u '+%Y%m%dT%H%M%SZ')"
if [[ "$MODE" == update ]]; then
  backup_dir="$PROGRAM_ROOT/program-backups/${timestamp}-${active_version}"
  install -d -m 0700 "$PROGRAM_ROOT/program-backups"
  cp -a "$active_dir" "$backup_dir"
  printf '现有程序已备份：%s\n' "$backup_dir"
fi

install -d -m 0755 "$staging/lib" "$PREFIX/sbin" "$RELEASES_ROOT"
install -m 0755 "$SOURCE_ROOT/vps-guard.sh" "$staging/vps-guard.sh"
install -m 0644 "$SOURCE_ROOT"/lib/*.sh "$staging/lib/"
install -m 0644 "$SOURCE_ROOT/VERSION" "$SOURCE_ROOT/LICENSE" "$staging/"
printf 'signature=%s\nversion=%s\n' "$INSTALL_SIGNATURE" "$VERSION" >"$staging/INSTALL-MANIFEST"
chmod 0644 "$staging/INSTALL-MANIFEST"
bash -n "$staging/vps-guard.sh"
[[ "$("$staging/vps-guard.sh" version)" == "VPS Guard $VERSION" ]] || {
  printf '错误：暂存版本健康检查失败，未切换稳定入口。\n' >&2
  exit 1
}
{
  printf '%s\n' '#!/usr/bin/env bash' "$LAUNCHER_SIGNATURE"
  printf 'exec %q "$@"\n' "$CURRENT_LINK/vps-guard.sh"
} >"$launcher_temp"
chmod 0755 "$launcher_temp"

mv "$staging" "$INSTALL_DIR"
new_release_created=1
if [[ "$MODE" == install ]]; then
  switch_current "releases/$VERSION"
  current_switched=1
  if ! mv -f "$launcher_temp" "$COMMAND_LINK"; then
    printf '错误：稳定 launcher 安装失败，正在撤销首次安装。\n' >&2
    exit 1
  fi
else
  # 更新不重写已验证的固定 launcher；current 的原子 rename 是最后一个可变步骤。
  switch_current "releases/$VERSION"
  current_switched=1
fi

success=1
printf '%s完成：%s\n' "$([[ "$MODE" == update ]] && printf 更新 || printf 安装)" "$VERSION" || true
printf '稳定命令：sudo vps-guard status\n' || true
