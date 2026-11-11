#!/usr/bin/env bash
# 启用仓库内的域名守卫钩子（每个 clone 执行一次）。
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

chmod +x .githooks/pre-commit .githooks/pre-push scripts/check-domains.sh
git config core.hooksPath .githooks

echo "git hooks installed: core.hooksPath=.githooks"
