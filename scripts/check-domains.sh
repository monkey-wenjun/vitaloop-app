#!/usr/bin/env bash
# 公共仓库域名守卫：禁止出现 awen.me 及其子域名。
#
# 用法:
#   scripts/check-domains.sh --all           # 扫描当前工作区已跟踪文件（CI）
#   scripts/check-domains.sh --staged        # 只扫描暂存区（pre-commit）
#   scripts/check-domains.sh --commit <sha>  # 扫描指定提交（pre-push）
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

# 只匹配实际域名地址：带子域名的地址或带协议的裸域名。
# 这样不会把脚本/文档里说明用的 “私有域名” 字样误判为泄漏。
PATTERN='([a-z0-9-]+\.)+awen\.me|https?://(www\.)?awen\.me([/:]|$)'
MODE=${1:---all}

case "$MODE" in
  --staged)
    matches=$(git grep --cached -n -I -i -E "$PATTERN" -- . || true)
    ;;
  --all)
    matches=$(git grep -n -I -i -E "$PATTERN" -- . || true)
    ;;
  --commit)
    sha=${2:?usage: $0 --commit <sha>}
    matches=$(git grep -n -I -i -E "$PATTERN" "$sha" -- . || true)
    ;;
  *)
    echo "usage: $0 [--staged|--all|--commit <sha>]" >&2
    exit 2
    ;;
esac

if [ -n "$matches" ]; then
  echo "ERROR: 公共版本禁止包含 awen.me 相关域名。" >&2
  echo "请改用空默认值、--dart-define 或用户自填配置。" >&2
  echo >&2
  echo "$matches" >&2
  exit 1
fi

echo "domain guard: no awen.me address found ($MODE)"
