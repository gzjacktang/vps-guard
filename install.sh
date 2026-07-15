#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/usr/local/lib/vps-guard"
COMMAND_LINK="/usr/local/sbin/vps-guard"
DRY_RUN=0
ASSUME_YES=0

for argument in "$@"; do
  case "$argument" in
    --dry-run) DRY_RUN=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    --help | -h)
      printf '用法：sudo ./install.sh [--dry-run] [--yes]\n'
      exit 0
      ;;
    *)
      printf '错误：未知参数：%s\n' "$argument" >&2
      exit 2
      ;;
  esac
done

printf 'VPS Guard 安装计划\n'
printf '安装目录：%s\n' "$INSTALL_DIR"
printf '命令入口：%s\n' "$COMMAND_LINK"
printf '文件权限：目录 0755，脚本 0755，模块 0644\n'

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'dry-run：未写入任何文件。\n'
  exit 0
fi

if [[ "${BASH_VERSINFO[0]}" -lt 5 ]]; then
  printf '错误：安装需要 Bash 5.x 或更高版本。\n' >&2
  exit 5
fi

if [[ "$(id -u)" -ne 0 ]]; then
  printf '错误：安装需要 root 权限，请使用 sudo ./install.sh。\n' >&2
  exit 4
fi

if [[ "$ASSUME_YES" -ne 1 ]]; then
  printf '确认安装？[y/N] '
  IFS= read -r answer
  case "$answer" in
    y | Y | yes | YES) ;;
    *)
      printf '已取消安装。\n'
      exit 0
      ;;
  esac
fi

install -d -m 0755 "$INSTALL_DIR/lib" /usr/local/sbin
install -m 0755 "$SOURCE_ROOT/vps-guard.sh" "$INSTALL_DIR/vps-guard.sh"
install -m 0644 "$SOURCE_ROOT"/lib/*.sh "$INSTALL_DIR/lib/"
ln -sfn "$INSTALL_DIR/vps-guard.sh" "$COMMAND_LINK"

printf '安装完成。运行 sudo vps-guard status 进行只读诊断。\n'
