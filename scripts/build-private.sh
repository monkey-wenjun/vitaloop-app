#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/vitaloop"

java21_home=""
for candidate in \
  "$HOME/.local/share/mise/installs/java/temurin-21.0.13+9.0.LTS" \
  /usr/lib/jvm/java-21-openjdk; do
  if [[ -x "$candidate/bin/java" ]]; then
    java21_home="$candidate"
    break
  fi
done

if [[ -z "$java21_home" ]]; then
  echo "Java 21 not found" >&2
  exit 1
fi

export JAVA_HOME="$java21_home"
export GRADLE_OPTS="-Dorg.gradle.java.home=$java21_home${GRADLE_OPTS:+ $GRADLE_OPTS}"
export PATH="$HOME/development/flutter/bin:$PATH"

defines_files=()
for config in "$CONFIG_DIR/blog_defines.json" "$CONFIG_DIR/defines.json"; do
  [[ -f "$config" ]] && defines_files+=("$config")
done

if [[ ${#defines_files[@]} -eq 0 ]]; then
  echo "No private defines found in $CONFIG_DIR" >&2
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/awen-work/vitaloop-build.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

merged_defines="$work_dir/defines.json"
jq -s 'reduce .[] as $item ({}; . * $item)' "${defines_files[@]}" > "$merged_defines"

flutter_args=()
if [[ ${1-} == run ]]; then
  shift
  flutter_args+=(run)
  flutter_args+=("$@")
else
  if [[ ${1-} == build ]]; then
    shift
  fi
  flutter_args+=(build)
  flutter_args+=("$@")
fi
flutter_args+=(--dart-define-from-file="$merged_defines")
flutter "${flutter_args[@]}"
