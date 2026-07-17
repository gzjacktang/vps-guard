#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(sed -n '1p' "$ROOT/VERSION")"
DIST="${1:-$ROOT/dist}"
SOURCE_ARCHIVE="$DIST/vps-guard-$VERSION.tar.gz"
SINGLE="$DIST/vps-guard-$VERSION-single.sh"
CHECKSUMS="$DIST/SHA256SUMS"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || exit 1
git -C "$ROOT" rev-parse --verify HEAD >/dev/null
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
  printf '错误：Release 只能从干净且已提交的工作树构建。\n' >&2
  exit 1
fi
install -d -m 0755 "$DIST"
git -C "$ROOT" archive --format=tar.gz --prefix="vps-guard-$VERSION/" --output="$SOURCE_ARCHIVE" HEAD
"$ROOT/scripts/build-single.sh" "$SINGLE"
"$ROOT/scripts/check-sensitive.sh" "$SOURCE_ARCHIVE" "$SINGLE"
(
  cd "$DIST"
  sha256sum "$(basename "$SOURCE_ARCHIVE")" "$(basename "$SINGLE")" >"$(basename "$CHECKSUMS")"
)
printf 'Release 产物：\n%s\n%s\n%s\n' "$SOURCE_ARCHIVE" "$SINGLE" "$CHECKSUMS"
