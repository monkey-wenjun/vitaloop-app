#!/usr/bin/env bash
# 启用仓库内的脱敏守卫钩子（每个 clone 执行一次）。
#
# 私有匹配规则不写进仓库：
#   VITALOOP_PRIVATE_PATTERNS='foo\\.example|203\\.0\\.113\\.7' \
#     ./scripts/install-git-hooks.sh
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

chmod +x .githooks/pre-commit .githooks/pre-push scripts/check-private-endpoints.sh
git config core.hooksPath .githooks

if [ -n "${VITALOOP_PRIVATE_PATTERNS:-}" ]; then
  printf '%s\n' "$VITALOOP_PRIVATE_PATTERNS" > "$ROOT/.git/vitaloop-private-patterns"
  chmod 600 "$ROOT/.git/vitaloop-private-patterns"
  echo "private patterns stored in .git/vitaloop-private-patterns"
fi

echo "git hooks installed: core.hooksPath=.githooks"
