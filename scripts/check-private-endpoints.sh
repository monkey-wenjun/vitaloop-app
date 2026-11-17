#!/usr/bin/env bash
# 公共仓库脱敏守卫：禁止私有域名、私有 IP 和内部端点进入公共仓库。
#
# 私有匹配规则不保存在仓库里，按以下顺序读取：
#   1. 环境变量 VITALOOP_PRIVATE_PATTERNS（多行正则）
#   2. 环境变量 VITALOOP_PRIVATE_PATTERNS_FILE 指向的文件
#   3. 默认本地文件 .git/vitaloop-private-patterns（不会提交）
#
# 用法:
#   scripts/check-private-endpoints.sh --all           # 扫描已跟踪文件（CI）
#   scripts/check-private-endpoints.sh --staged        # 扫描暂存区（pre-commit）
#   scripts/check-private-endpoints.sh --commit <sha>  # 扫描指定提交（pre-push）
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel)
cd "$ROOT"

MODE=${1:---all}
patterns=${VITALOOP_PRIVATE_PATTERNS:-}
patterns_file=${VITALOOP_PRIVATE_PATTERNS_FILE:-$ROOT/.git/vitaloop-private-patterns}

if [ -f "$patterns_file" ]; then
  patterns="$patterns"$'\n'"$(cat "$patterns_file")"
fi

patterns=$(printf '%s\n' "$patterns" | sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' -e '/^[[:space:]]*#/d')

rule_file=$(mktemp)
trap 'rm -f "$rule_file"' EXIT
{
  if [ -n "$patterns" ]; then
    printf '%s\n' "$patterns"
  fi
  # 常见私有/保留 IPv4 段。localhost 和 127.0.0.1 属于通用开发地址，放行。
  printf '%s\n' '(^|[^0-9])(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|169\.254\.[0-9]{1,3}\.[0-9]{1,3})([^0-9]|$)'
} > "$rule_file"

case "$MODE" in
  --staged)
    matches=$(git grep --cached -l -I -i -E -f "$rule_file" -- . || true)
    ;;
  --all)
    matches=$(git grep -l -I -i -E -f "$rule_file" -- . || true)
    ;;
  --commit)
    sha=${2:?usage: $0 --commit <sha>}
    matches=$(git grep -l -I -i -E -f "$rule_file" "$sha" -- . || true)
    ;;
  *)
    echo "usage: $0 [--staged|--all|--commit <sha>]" >&2
    exit 2
    ;;
esac

if [ -n "$matches" ]; then
  echo "ERROR: 公共仓库检测到私有域名或私有 IP。" >&2
  echo "私有规则来自仓库外配置；命中文件如下（不打印具体内容）：" >&2
  echo "$matches" >&2
  echo >&2
  echo "请改用空默认值、--dart-define 或用户自填配置。" >&2
  exit 1
fi

echo "private endpoint guard: clean ($MODE)"
