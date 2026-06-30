#!/bin/bash
# install.sh — install the claude-system-awareness hook into Claude Code.
#
#   - copies the hook + Swift helper into ~/.claude/hooks/
#   - compiles the display-count helper (falls back to system_profiler if no swiftc)
#   - idempotently registers UserPromptSubmit + SessionStart hooks in
#     ~/.claude/settings.json (backed up first; never duplicates entries)
#
# Re-running is safe. Honors CLAUDE_CONFIG_DIR (defaults to ~/.claude).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
HOOKS_DIR="$CLAUDE_DIR/hooks"
SYSCTX_DIR="$HOOKS_DIR/system-context"
SETTINGS="$CLAUDE_DIR/settings.json"
HOOK_CMD="$HOOKS_DIR/system-context-nudge.sh"
PY="${NUDGE_PYTHON:-/usr/bin/python3}"; [ -x "$PY" ] || PY="$(command -v python3)"

say()  { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '\033[33m!\033[0m %s\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || { warn "This hook is macOS-only (uses sysctl/pmset/ipconfig). Aborting."; exit 1; }
command -v "$PY" >/dev/null 2>&1 || { warn "python3 not found (needed for JSON output). Install Xcode Command Line Tools: xcode-select --install"; exit 1; }

printf '\nInstalling claude-system-awareness into %s\n\n' "$CLAUDE_DIR"

# 1) copy files
mkdir -p "$SYSCTX_DIR"
cp "$REPO_DIR/hooks/system-context-nudge.sh" "$HOOK_CMD"
chmod +x "$HOOK_CMD"
cp "$REPO_DIR/hooks/system-context/displaycount.swift" "$SYSCTX_DIR/displaycount.swift"
ok "Copied hook to $HOOK_CMD"

# 2) compile the display-count helper (optional — script falls back to system_profiler)
if command -v swiftc >/dev/null 2>&1; then
  swiftc -O "$SYSCTX_DIR/displaycount.swift" -o "$SYSCTX_DIR/displaycount"
  ok "Compiled display-count helper ($("$SYSCTX_DIR/displaycount") displays detected)"
else
  warn "swiftc not found — will use the slower system_profiler fallback for monitor detection."
  warn "For the fast path, install Xcode Command Line Tools: xcode-select --install"
fi

# 3) register hooks in settings.json (idempotent, with backup)
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$CLAUDE_DIR/settings_$(date +%Y-%m-%d_%H%M%S).backup"
  ok "Backed up existing settings.json"
fi

HOOK_CMD="$HOOK_CMD" SETTINGS="$SETTINGS" "$PY" - <<'PY'
import json, os, sys
settings_path = os.environ["SETTINGS"]
cmd = os.environ["HOOK_CMD"]
try:
    with open(settings_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except json.JSONDecodeError as e:
    sys.exit(f"settings.json is not valid JSON ({e}); fix it and re-run.")

hooks = data.setdefault("hooks", {})
added = []
for event in ("UserPromptSubmit", "SessionStart"):
    entries = hooks.setdefault(event, [])
    already = any(
        h.get("command") == cmd
        for entry in entries
        for h in entry.get("hooks", [])
    )
    if not already:
        entries.append({"hooks": [{"type": "command", "command": cmd, "timeout": 10}]})
        added.append(event)

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("registered: " + (", ".join(added) if added else "already present (no change)"))
PY
ok "settings.json updated"

printf '\n'
ok "Installed. It activates on your next Claude Code prompt / session."
printf '\nTry it: close your laptop lid for a minute (or change Wi-Fi / unplug power),\nthen send any message — the next prompt will carry an <environment-change> note.\n\n'
say "Config (set in the \"env\" block of settings.json or your shell):"
say "  NUDGE_TIME_THRESHOLD_SECS   elapsed-time threshold in seconds (default 1800)"
say "  NUDGE_STATE_TTL_DAYS        prune per-session state after N days (default 7)"
printf '\nUninstall: ./uninstall.sh\n\n'
