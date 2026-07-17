#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n '1p' "$ROOT/VERSION")"
OUTPUT="${1:-$ROOT/dist/vps-guard-$VERSION-single.sh}"
MODULES=(
  core system lifecycle preflight ui backup rollback firewall_rules firewall firewall_advanced
  ssh ssh_hardening fail2ban wizard
)

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  printf '错误：VERSION 格式无效。\n' >&2
  exit 1
}
install -d -m 0755 "$(dirname "$OUTPUT")"
temp="${OUTPUT}.tmp.$$"
trap 'rm -f "$temp"' EXIT INT TERM

{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' '# VPS Guard 合并单文件发布物；由 scripts/build-single.sh 生成，请勿手工编辑。'
  printf '%s\n' 'set -o errexit' 'set -o nounset' 'set -o pipefail'
  printf 'VPS_GUARD_VERSION=%q\nreadonly VPS_GUARD_VERSION\n' "$VERSION"
  # shellcheck disable=SC2016
  printf '%s\n' 'VPS_GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"'
  # shellcheck disable=SC2016
  printf '%s\n' 'VPS_GUARD_COMMAND="${VPS_GUARD_COMMAND:-$VPS_GUARD_ROOT/$(basename "${BASH_SOURCE[0]}")}"'
  for module in "${MODULES[@]}"; do
    [[ -r "$ROOT/lib/$module.sh" ]] || {
      printf '错误：缺少模块：%s\n' "$module" >&2
      exit 1
    }
    printf '\n# --- BEGIN lib/%s.sh ---\n' "$module"
    sed '1{/^#!\/usr\/bin\/env bash$/d;}' "$ROOT/lib/$module.sh"
    printf '# --- END lib/%s.sh ---\n' "$module"
  done
  printf '\n# --- BEGIN command entry ---\n'
  awk 'found || /^DRY_RUN=0$/ { found=1; print }' "$ROOT/vps-guard.sh"
} >"$temp"

bash -n "$temp"
chmod 0755 "$temp"
mv "$temp" "$OUTPUT"
trap - EXIT INT TERM
printf '已生成单文件：%s\n' "$OUTPUT"
