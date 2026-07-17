#!/usr/bin/env bash

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_text() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$PROJECT_ROOT/$file" || {
    printf '文档缺失：%s -> %s\n' "$file" "$text" >&2
    return 1
  }
}

require_text README.md 'docs/INSTALLATION.md'
require_text README.md 'docs/COMPATIBILITY.md'
require_text README.md 'docs/RELEASE.md'
require_text docs/CLI.md 'vps-guard update check'
require_text docs/CLI.md 'vps-guard [--dry-run] uninstall'
require_text docs/CLI.md 'vps-guard [--dry-run] uninstall [--yes] [--purge-data]'
require_text docs/CLI.md '--password-auth keep|yes|no'
require_text docs/CLI.md '--findtime 60-86400'
require_text docs/CLI.md '## 退出码'
require_text docs/CLI.md '## dry-run 与已知限制'
require_text docs/INSTALLATION.md "不提供 \`curl | bash\`"
require_text docs/INSTALLATION.md 'program-backups'
require_text docs/COMPATIBILITY.md 'container-smoke'
require_text docs/COMPATIBILITY.md '真实 VM 发布门禁'
require_text docs/RELEASE.md 'SHA256SUMS'
require_text docs/RELEASE.md 'NOT_VERIFIED'
require_text validation/vm/README.md 'ControlMaster=yes'
require_text validation/vm/v1.env 'status=NOT_VERIFIED'
require_text LICENSE 'Copyright (c) 2026 jLjT'

printf 'docs_test: ok\n'
