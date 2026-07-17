#!/usr/bin/env bash

set -euo pipefail

[[ "$#" -ge 1 ]] || {
  printf '用法：scripts/check-sensitive.sh <文件或目录> [...]\n' >&2
  exit 2
}

scan_root="$(mktemp -d "${TMPDIR:-/tmp}/vps-guard-release-scan.XXXXXX")"
trap 'rm -rf "$scan_root"' EXIT INT TERM
scan_paths=()
index=0

for input in "$@"; do
  [[ -e "$input" ]] || {
    printf '错误：扫描目标不存在：%s\n' "$input" >&2
    exit 1
  }
  if [[ "$input" == *.tar.gz ]]; then
    index=$((index + 1))
    members="$scan_root/members-$index"
    tar -tzf "$input" >"$members"
    if awk '/^\// || /(^|\/)\.\.($|\/)/ { exit 1 }' "$members"; then :; else
      printf '错误：源码包包含越界路径：%s\n' "$input" >&2
      exit 1
    fi
    if tar -tvzf "$input" | awk '$1 ~ /^[lbcps]/ { exit 1 }'; then :; else
      printf '错误：源码包包含链接或特殊文件：%s\n' "$input" >&2
      exit 1
    fi
    extract="$scan_root/archive-$index"
    mkdir -p "$extract"
    tar -xzf "$input" -C "$extract"
    scan_paths+=("$extract")
  else
    scan_paths+=("$input")
  fi
done

if rg -n --hidden --glob '!.git/**' --glob '!dist/**' \
  --glob '!validation/**' \
  'BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY|github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}' \
  "${scan_paths[@]}"; then
  printf '错误：发布内容包含私钥或凭据模式。\n' >&2
  exit 1
fi

if find "${scan_paths[@]}" -type f \( -name '*.log' -o -name 'id_rsa' -o -name 'id_ed25519' -o -name 'authorized_keys' \) -print | grep -q .; then
  printf '错误：发布内容包含日志、私钥或运行期认证文件。\n' >&2
  exit 1
fi

ip_list="$scan_root/ipv4.txt"
rg --no-filename --only-matching '([0-9]{1,3}\.){3}[0-9]{1,3}' "${scan_paths[@]}" | LC_ALL=C sort -u >"$ip_list" || true
while IFS= read -r address; do
  IFS=. read -r a b c d <<<"$address"
  # 无效地址是输入校验测试，不可能是真实服务器地址。
  if [[ ("$a" == 0* && "$a" != 0) || ("$b" == 0* && "$b" != 0) ||
    ("$c" == 0* && "$c" != 0) || ("$d" == 0* && "$d" != 0) ]]; then
    continue
  fi
  if [[ "$a" -gt 255 || "$b" -gt 255 || "$c" -gt 255 || "$d" -gt 255 ]]; then
    continue
  fi
  case "$address" in
    0.0.0.0 | 127.* | 192.0.2.* | 198.51.100.* | 203.0.113.* | 255.255.255.255) ;;
    *)
      printf '错误：发布内容包含非文档保留 IPv4 地址：%s\n' "$address" >&2
      exit 1
      ;;
  esac
done <"$ip_list"

ipv6_list="$scan_root/ipv6.txt"
# 三合一 IPv6 正则：完整 8 组、:: 在中间、:: 在开头；避免匹配时间戳等
rg --no-filename --only-matching \
  --glob '!tests/**' \
  '([0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}|([0-9A-Fa-f]{1,4}:){1,6}:[0-9A-Fa-f]{1,4}|::([0-9A-Fa-f]{1,4}:){0,6}[0-9A-Fa-f]{1,4}' \
  "${scan_paths[@]}" | LC_ALL=C sort -u >"$ipv6_list" || true
while IFS= read -r address; do
  normalized="$(printf '%s' "$address" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    :: | ::1 | 2001:db8:* | 2001:0db8:*) ;;
    *)
      printf '错误：发布内容包含非文档保留 IPv6 地址：%s\n' "$address" >&2
      exit 1
      ;;
  esac
done <"$ipv6_list"

printf '敏感信息与归档路径检查通过。\n'
