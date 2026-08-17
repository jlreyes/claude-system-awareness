#!/bin/bash
# Remove the hook from Claude Code and Codex while preserving private config.
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
PROFILE_DEST="${NUDGE_CONFIG:-$HOME/.config/agent-system-context/config.json}"
PY="${NUDGE_PYTHON:-/usr/bin/python3}"
[ -x "$PY" ] || PY="$(command -v python3)"

TARGETS="all"
PURGE_CONFIG=0

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--claude-only | --codex-only] [--purge-config]

The private machine/network profile is preserved unless --purge-config is set.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude-only) TARGETS="claude" ;;
    --codex-only) TARGETS="codex" ;;
    --purge-config) PURGE_CONFIG=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ok() { printf '\033[32m✓\033[0m %s\n' "$1"; }

unregister_hook() {
  local config_file="$1" hook_command="$2" config_dir
  [ -f "$config_file" ] || return 0
  config_dir="$(dirname "$config_file")"
  cp "$config_file" "$config_dir/$(basename "$config_file")_$(date +%Y-%m-%d_%H%M%S).backup"
  TARGET_FILE="$config_file" HOOK_COMMAND="$hook_command" "$PY" - <<'PY'
import json
import os

path = os.environ["TARGET_FILE"]
command = os.environ["HOOK_COMMAND"]
with open(path, encoding="utf-8") as file:
    data = json.load(file)

hooks = data.get("hooks", {})
for event in ("UserPromptSubmit", "SessionStart"):
    entries = hooks.get(event, [])
    kept = []
    for entry in entries:
        remaining = [
            hook
            for hook in entry.get("hooks", [])
            if hook.get("command", "").strip("'\"") != command
        ]
        if remaining:
            updated = dict(entry)
            updated["hooks"] = remaining
            kept.append(updated)
    if kept:
        hooks[event] = kept
    else:
        hooks.pop(event, None)
if not hooks:
    data.pop("hooks", None)

with open(path, "w", encoding="utf-8") as file:
    json.dump(data, file, indent=2, ensure_ascii=False)
    file.write("\n")
PY
}

remove_target() {
  local name="$1" root="$2" config_file="$3"
  local hooks_dir="$root/hooks" hook_command="$root/hooks/system-context-nudge.sh"
  unregister_hook "$config_file" "$hook_command"
  rm -f "$hook_command"
  rm -rf "$hooks_dir/system-context"
  ok "$name hook removed"
}

if [ "$TARGETS" = "all" ] || [ "$TARGETS" = "claude" ]; then
  remove_target "Claude Code" "$CLAUDE_DIR" "$CLAUDE_DIR/settings.json"
fi
if [ "$TARGETS" = "all" ] || [ "$TARGETS" = "codex" ]; then
  remove_target "Codex" "$CODEX_DIR" "$CODEX_DIR/hooks.json"
fi

if [ "$PURGE_CONFIG" = "1" ]; then
  rm -f "$PROFILE_DEST"
  ok "Private context profile removed"
elif [ -f "$PROFILE_DEST" ]; then
  ok "Private context profile preserved at $PROFILE_DEST"
fi

printf '\nUninstalled. Restart active sessions to fully clear the hook.\n'
