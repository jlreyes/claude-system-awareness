#!/bin/bash
# uninstall.sh — remove the claude-system-awareness hook from Claude Code.
# Removes the settings.json entries (backed up first) and the installed files.
# Honors CLAUDE_CONFIG_DIR (defaults to ~/.claude).
set -euo pipefail

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_CMD="$HOOKS_DIR/system-context-nudge.sh"
PY="${NUDGE_PYTHON:-/usr/bin/python3}"; [ -x "$PY" ] || PY="$(command -v python3)"

ok() { printf '\033[32m✓\033[0m %s\n' "$1"; }

if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$CLAUDE_DIR/settings_$(date +%Y-%m-%d_%H%M%S).backup"
  HOOK_CMD="$HOOK_CMD" SETTINGS="$SETTINGS" "$PY" - <<'PY'
import json, os
p = os.environ["SETTINGS"]; cmd = os.environ["HOOK_CMD"]
with open(p) as f: data = json.load(f)
hooks = data.get("hooks", {})
for event in ("UserPromptSubmit", "SessionStart"):
    entries = hooks.get(event)
    if not entries: continue
    kept = [e for e in entries
            if not any(h.get("command") == cmd for h in e.get("hooks", []))]
    if kept: hooks[event] = kept
    else: hooks.pop(event, None)
if hooks == {}: data.pop("hooks", None)
with open(p, "w") as f:
    json.dump(data, f, indent=2); f.write("\n")
print("removed hook entries from settings.json")
PY
  ok "Updated settings.json (backup saved)"
fi

rm -f "$HOOK_CMD"
rm -rf "$HOOKS_DIR/system-context"
ok "Removed installed hook files"
printf '\nUninstalled. Restart Claude Code sessions to fully clear the hook.\n'
