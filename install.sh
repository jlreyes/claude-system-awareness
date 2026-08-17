#!/bin/bash
# Install the system-awareness hook into Claude Code and Codex.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
PROFILE_DEST="${NUDGE_CONFIG:-$HOME/.config/agent-system-context/config.json}"
PY="${NUDGE_PYTHON:-/usr/bin/python3}"
[ -x "$PY" ] || PY="$(command -v python3)"

TARGETS="all"
PROFILE_SOURCE=""

usage() {
  cat <<'EOF'
Usage: ./install.sh [--claude-only | --codex-only] [--config FILE]

By default the hook is installed for both Claude Code and Codex. --config
copies a private machine/network profile to ~/.config/agent-system-context/.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --claude-only) TARGETS="claude" ;;
    --codex-only) TARGETS="codex" ;;
    --config)
      [ "$#" -ge 2 ] || { printf '%s\n' "--config requires a file" >&2; exit 2; }
      PROFILE_SOURCE="$2"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

say()  { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || { warn "This hook is macOS-only. Aborting."; exit 1; }
command -v "$PY" >/dev/null 2>&1 || { warn "python3 is required."; exit 1; }

if [ -n "$PROFILE_SOURCE" ]; then
  [ -f "$PROFILE_SOURCE" ] || { warn "Profile not found: $PROFILE_SOURCE"; exit 1; }
  "$PY" -c 'import json,sys
value=json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(value, dict), "profile root must be an object"' "$PROFILE_SOURCE"
fi

COMPILED_HELPER=""
if command -v swiftc >/dev/null 2>&1; then
  COMPILED_HELPER="$(mktemp "${TMPDIR:-/tmp}/system-context-displaycount.XXXXXX")"
  trap 'rm -f "$COMPILED_HELPER"' EXIT
  swiftc -O "$REPO_DIR/hooks/system-context/displaycount.swift" -o "$COMPILED_HELPER"
fi

register_hook() {
  local config_file="$1" hook_command="$2" config_dir
  config_dir="$(dirname "$config_file")"
  mkdir -p "$config_dir"
  if [ -f "$config_file" ]; then
    cp "$config_file" "$config_dir/$(basename "$config_file")_$(date +%Y-%m-%d_%H%M%S).backup"
  fi

  TARGET_FILE="$config_file" HOOK_COMMAND="$hook_command" "$PY" - <<'PY'
import json
import os
import sys

path = os.environ["TARGET_FILE"]
command = os.environ["HOOK_COMMAND"]
try:
    with open(path, encoding="utf-8") as file:
        data = json.load(file)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as error:
    sys.exit(f"{path} is not valid JSON ({error}); fix it and re-run")

hooks = data.setdefault("hooks", {})
added = []
for event in ("UserPromptSubmit", "SessionStart"):
    entries = hooks.setdefault(event, [])
    exists = False
    for entry in entries:
        for hook in entry.get("hooks", []):
            existing = hook.get("command", "")
            if existing.strip("'\"") == command:
                hook["command"] = command
                hook["timeout"] = 10
                exists = True
    if not exists:
        entries.append(
            {"hooks": [{"type": "command", "command": command, "timeout": 10}]}
        )
        added.append(event)

with open(path, "w", encoding="utf-8") as file:
    json.dump(data, file, indent=2, ensure_ascii=False)
    file.write("\n")
print("registered " + (", ".join(added) if added else "already present"))
PY
}

install_target() {
  local name="$1" root="$2" config_file="$3"
  local hooks_dir="$root/hooks" support_dir="$root/hooks/system-context"
  local hook_command="$hooks_dir/system-context-nudge.sh"

  mkdir -p "$support_dir"
  cp "$REPO_DIR/hooks/system-context-nudge.sh" "$hook_command"
  chmod +x "$hook_command"
  cp "$REPO_DIR/hooks/system-context/profile.py" "$support_dir/profile.py"
  chmod +x "$support_dir/profile.py"
  cp "$REPO_DIR/hooks/system-context/displaycount.swift" "$support_dir/displaycount.swift"
  if [ -n "$COMPILED_HELPER" ]; then
    cp "$COMPILED_HELPER" "$support_dir/displaycount"
    chmod +x "$support_dir/displaycount"
  else
    warn "swiftc not found; $name will use the slower system_profiler display fallback"
  fi

  register_hook "$config_file" "$hook_command"
  ok "$name hook installed at $hook_command"
}

printf '\nInstalling system awareness\n\n'
if [ "$TARGETS" = "all" ] || [ "$TARGETS" = "claude" ]; then
  install_target "Claude Code" "$CLAUDE_DIR" "$CLAUDE_DIR/settings.json"
fi
if [ "$TARGETS" = "all" ] || [ "$TARGETS" = "codex" ]; then
  install_target "Codex" "$CODEX_DIR" "$CODEX_DIR/hooks.json"
fi

if [ -n "$PROFILE_SOURCE" ]; then
  mkdir -p "$(dirname "$PROFILE_DEST")"
  if [ -f "$PROFILE_DEST" ] && ! cmp -s "$PROFILE_SOURCE" "$PROFILE_DEST"; then
    cp "$PROFILE_DEST" "$PROFILE_DEST.$(date +%Y-%m-%d_%H%M%S).backup"
  fi
  cp "$PROFILE_SOURCE" "$PROFILE_DEST"
  chmod 600 "$PROFILE_DEST"
  ok "Private context profile installed at $PROFILE_DEST"
elif [ -f "$PROFILE_DEST" ]; then
  ok "Preserved existing private context profile at $PROFILE_DEST"
else
  say "No private context profile installed. Copy config.example.json to:"
  say "  $PROFILE_DEST"
fi

printf '\n'
ok "Installed. New Claude Code and Codex sessions will receive a baseline."
say "Codex may ask you to trust the new hook command once."
say "Re-run this installer after updating the repository; registration is idempotent."
printf '\n'
