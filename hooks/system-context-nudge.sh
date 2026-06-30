#!/bin/bash
# system-context-nudge.sh
# Claude Code hook (UserPromptSubmit + SessionStart). Injects an
# <environment-change> note when the machine's state has shifted since this
# session was last active, so the model is oriented instead of confused:
#   - sleep / wake  (lid close+reopen — the most disorienting one)
#   - reboot
#   - elapsed wall-clock time since last activity
#   - Wi-Fi SSID change (home / office / travel) and connect/disconnect
#   - online <-> offline (default route present)
#   - AC <-> battery
#   - monitor add / remove (changed workstation)
#
# State is per-session (keyed by session_id, which resume reuses) with a global
# anchor so a brand-new session after time away is still oriented.
#
# Safety: this hook must NEVER block a prompt. Every probe is guarded and the
# script always exits 0. State is stored line-delimited (never sourced/eval'd)
# so a hostile Wi-Fi name cannot inject code.
#
# macOS only. Part of https://github.com/jlreyes/claude-system-awareness (MIT).

# ---- config (override via env) ------------------------------------------
TIME_THRESHOLD_SECS="${NUDGE_TIME_THRESHOLD_SECS:-1800}"  # report a gap >= this (default 30m)
STATE_TTL_DAYS="${NUDGE_STATE_TTL_DAYS:-7}"               # prune per-session state older than this

# Resolve our support dir from the script's own location, so it works whether
# installed at ~/.claude/hooks/ or run straight from a clone. Override NUDGE_HOME.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || printf '%s' "$HOME/.claude/hooks")"
SYSCTX_DIR="${NUDGE_HOME:-$SCRIPT_DIR/system-context}"
STATE_DIR="${NUDGE_STATE_DIR:-$SYSCTX_DIR/state}"
DISPLAYCOUNT_BIN="$SYSCTX_DIR/displaycount"
WIFI_DEV_CACHE="$SYSCTX_DIR/wifi-dev"
PY="${NUDGE_PYTHON:-/usr/bin/python3}"
[ -x "$PY" ] || PY="$(command -v python3 2>/dev/null || printf '%s' /usr/bin/python3)"

# ---- read hook input (JSON on stdin) ------------------------------------
INPUT="$(cat 2>/dev/null)"
field() { printf '%s' "$INPUT" | tr -d '\n' | sed -nE "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" | head -1; }
SESSION_ID="$(field session_id)"
EVENT="$(field hook_event_name)"
SOURCE="$(field source)"            # SessionStart only: startup|resume|clear|compact
[ -z "$EVENT" ] && EVENT="UserPromptSubmit"
[ -z "$SESSION_ID" ] && SESSION_ID="default"

# A compaction restart is the same session with no real time gap — stay silent.
[ "$EVENT" = "SessionStart" ] && [ "$SOURCE" = "compact" ] && exit 0

now="$(date +%s)"

# ---- probe current state ------------------------------------------------
# Power source + battery %
batt_raw="$(pmset -g batt 2>/dev/null)"
if printf '%s' "$batt_raw" | grep -q "AC Power"; then POWER="AC"; else POWER="Battery"; fi
BATT_PCT="$(printf '%s' "$batt_raw" | grep -Eo '[0-9]+%' | head -1)"

# Wi-Fi interface (cached — discovery costs ~50ms)
WIFI_DEV=""
[ -f "$WIFI_DEV_CACHE" ] && WIFI_DEV="$(cat "$WIFI_DEV_CACHE" 2>/dev/null)"
if [ -z "$WIFI_DEV" ]; then
  WIFI_DEV="$(networksetup -listallhardwareports 2>/dev/null | awk '/Wi-Fi/{getline; print $2; exit}')"
  [ -z "$WIFI_DEV" ] && WIFI_DEV="en0"
  printf '%s' "$WIFI_DEV" > "$WIFI_DEV_CACHE" 2>/dev/null
fi
# SSID (networksetup is blocked by Location Services; ipconfig getsummary is not)
SSID="$(ipconfig getsummary "$WIFI_DEV" 2>/dev/null | awk -F' SSID : ' '/ SSID : /{print $2; exit}')"
SSID="$(printf '%s' "$SSID" | tr -d '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"

# Connectivity: is there a default route? (route-only; an offline note can't be
# delivered while offline anyway, so an active probe would add nothing.)
DEF_IF="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
if [ -n "$DEF_IF" ]; then NET="online"; else NET="offline"; fi

# Active display count (compiled helper; fall back to system_profiler)
DISPLAYS=""
[ -x "$DISPLAYCOUNT_BIN" ] && DISPLAYS="$("$DISPLAYCOUNT_BIN" 2>/dev/null)"
if ! printf '%s' "$DISPLAYS" | grep -qE '^[0-9]+$'; then
  DISPLAYS="$(system_profiler SPDisplaysDataType -json 2>/dev/null | "$PY" -c 'import json,sys
try: d=json.load(sys.stdin)
except Exception: print(""); raise SystemExit
print(sum(len(g.get("spdisplays_ndrvs",[])) for g in d.get("SPDisplaysDataType",[])))' 2>/dev/null)"
fi
printf '%s' "$DISPLAYS" | grep -qE '^[0-9]+$' || DISPLAYS="?"

# Sleep/wake + boot times (epoch seconds) — fast and exact.
# Output looks like "{ sec = 1782849152, usec = 744690 } ..." — grab the FIRST
# integer (the sec value); a ".*sec =" regex wrongly matches the "sec" in "usec".
WAKETIME="$(sysctl -n kern.waketime 2>/dev/null | sed -nE 's/[^0-9]*([0-9]+).*/\1/p')"
BOOTTIME="$(sysctl -n kern.boottime 2>/dev/null | sed -nE 's/[^0-9]*([0-9]+).*/\1/p')"
[ -z "$WAKETIME" ] && WAKETIME=0
[ -z "$BOOTTIME" ] && BOOTTIME=0

# ---- load previous state ------------------------------------------------
mkdir -p "$STATE_DIR" 2>/dev/null
SAFE_ID="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')"
SESS_FILE="$STATE_DIR/${SAFE_ID}.env"
GLOB_FILE="$STATE_DIR/_global.env"

# Prune stale per-session files (keep the global anchor)
find "$STATE_DIR" -name '*.env' ! -name '_global.env' -type f -mtime +"$STATE_TTL_DAYS" -delete 2>/dev/null

# A genuinely new session = no per-session state recorded yet. Used to show a
# one-line baseline so a fresh session always knows its starting environment.
if [ -f "$SESS_FILE" ]; then NEW_SESSION=0; else NEW_SESSION=1; fi

# Diff against this session's last state; fall back to the global anchor so a
# fresh session after time away is still oriented.
BASE_FILE=""
if [ -f "$SESS_FILE" ]; then BASE_FILE="$SESS_FILE"
elif [ -f "$GLOB_FILE" ]; then BASE_FILE="$GLOB_FILE"; fi

FIRST_RUN=1
P_SEEN=""; P_SSID=""; P_POWER=""; P_DISPLAYS=""; P_NET=""; P_WAKE="0"; P_BOOT="0"
if [ -n "$BASE_FILE" ]; then
  FIRST_RUN=0
  { IFS= read -r P_SEEN; IFS= read -r P_SSID; IFS= read -r P_POWER; IFS= read -r P_DISPLAYS; IFS= read -r P_NET; IFS= read -r P_WAKE; IFS= read -r P_BOOT; } < "$BASE_FILE" 2>/dev/null
  printf '%s' "$P_WAKE" | grep -qE '^[0-9]+$' || P_WAKE=0
  printf '%s' "$P_BOOT" | grep -qE '^[0-9]+$' || P_BOOT=0
fi

# ---- helpers ------------------------------------------------------------
humandur() {  # seconds -> "1d 2h 3m"
  local s="$1" d h m out=""
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  [ "$d" -gt 0 ] && out="${out}${d}d "
  [ "$h" -gt 0 ] && out="${out}${h}h "
  [ "$m" -gt 0 ] && out="${out}${m}m"
  out="${out% }"            # drop trailing space (e.g. exact "4h ")
  [ -z "$out" ] && out="<1m"
  printf '%s' "$out"
}

changes=""
add() { changes="${changes}- $1"$'\n'; }

# ---- diff ---------------------------------------------------------------
if [ "$FIRST_RUN" = "0" ]; then
  # Reboot resets kern.waketime too, so detect it first and skip the sleep line.
  rebooted=0
  [ "$BOOTTIME" -gt "$P_BOOT" ] 2>/dev/null && rebooted=1
  # Sleep / wake — the big one
  if [ "$rebooted" = "0" ] && [ "$WAKETIME" -gt "$P_WAKE" ] 2>/dev/null; then
    add "💤 The machine SLEPT and woke $(humandur $(( now - WAKETIME ))) ago (woke $(date -r "$WAKETIME" '+%a %H:%M')). Sleep silently interrupts network sockets, timers, watch processes, and dev servers — if something is broken right now, suspect the sleep, not your previous actions."
  fi
  # Reboot
  if [ "$rebooted" = "1" ]; then
    add "🔁 The machine REBOOTED (booted $(date -r "$BOOTTIME" '+%a %Y-%m-%d %H:%M')). Background servers, port-forwards, tmux/shell state, and anything not relaunched on boot are gone."
  fi
  # Elapsed time
  gap=0; [ -n "$P_SEEN" ] && printf '%s' "$P_SEEN" | grep -qE '^[0-9]+$' && gap=$(( now - P_SEEN ))
  if [ "$gap" -ge "$TIME_THRESHOLD_SECS" ]; then
    add "⏱ ~$(humandur "$gap") elapsed since the last activity here (was $(date -r "$P_SEEN" '+%a %H:%M'), now $(date '+%a %Y-%m-%d %H:%M %Z')). Treat time-sensitive context as stale: 'today', auth tokens, caches, running timers, and the state of any open PRs/CI/builds."
  fi
  # Wi-Fi / location
  if [ "$SSID" != "$P_SSID" ]; then
    if [ -z "$SSID" ]; then
      add "📶 Wi-Fi disconnected (was \"$P_SSID\"). Likely on Ethernet, tethered, or offline."
    elif [ -z "$P_SSID" ]; then
      add "📶 Wi-Fi connected to \"$SSID\"."
    else
      add "📶 Wi-Fi changed: \"$P_SSID\" → \"$SSID\". Location/network context likely changed (home/office/travel). Expect different latency, a possible captive portal, and that VPN/LAN/internal hosts reachable before may now be unreachable (or vice-versa)."
    fi
  fi
  # Connectivity
  if [ "$NET" != "$P_NET" ]; then
    if [ "$NET" = "offline" ]; then
      add "🌐 Network connectivity LOST (no default route). Network calls, installs, git fetch/push, and API/MCP requests will fail until it returns — don't read these failures as bugs in your work."
    else
      add "🌐 Network connectivity RESTORED."
    fi
  fi
  # Power
  if [ "$POWER" != "$P_POWER" ]; then
    if [ "$POWER" = "Battery" ]; then
      add "🔋 Unplugged — on battery${BATT_PCT:+ ($BATT_PCT)}. The machine may idle-sleep or throttle; long-running tasks could be interrupted."
    else
      add "🔌 Plugged in — on AC${BATT_PCT:+ ($BATT_PCT)}."
    fi
  fi
  # Displays
  if [ "$DISPLAYS" != "$P_DISPLAYS" ] && printf '%s%s' "$DISPLAYS" "$P_DISPLAYS" | grep -qE '^[0-9]+$'; then
    if [ "$DISPLAYS" -lt "$P_DISPLAYS" ]; then extra=" (monitor disconnected — possibly undocked / moved workstation)"
    else extra=" (monitor connected — possibly docked / changed workstation)"; fi
    add "🖥 Displays: $P_DISPLAYS → $DISPLAYS$extra."
  fi
fi

# ---- emit ---------------------------------------------------------------
emit() {  # $1 = full additionalContext string -> JSON on stdout
  printf '%s' "$1" | "$PY" -c 'import json,sys
print(json.dumps({"hookSpecificOutput":{"hookEventName":sys.argv[1],"additionalContext":sys.stdin.read()}}))' "$EVENT" 2>/dev/null
}

# Show a baseline on a brand-new session, or after /clear wipes the context.
baseline_eligible=0
[ "$NEW_SESSION" = "1" ] && baseline_eligible=1
[ "$EVENT" = "SessionStart" ] && [ "$SOURCE" = "clear" ] && baseline_eligible=1

if [ -n "$changes" ]; then
  header="Environmental changes detected since this session was last active. This is orientation only — your prior work and reasoning are intact and nothing has gone wrong on your end:"
  footer="If a command, tool, or network action fails right after this notice, suspect the environment first (re-check connectivity, working dir, servers, and the current time) before concluding your approach is wrong."
  emit "<environment-change>"$'\n'"${header}"$'\n'"${changes}${footer}"$'\n'"</environment-change>"
elif [ "$baseline_eligible" = "1" ]; then
  wifi_part="Wi-Fi \"$SSID\""; [ -z "$SSID" ] && wifi_part="no Wi-Fi"
  emit "<environment>"$'\n'"Session environment: ${wifi_part} · ${POWER}${BATT_PCT:+ ($BATT_PCT)} · ${DISPLAYS} display(s) · ${NET} · $(date '+%a %Y-%m-%d %H:%M %Z'). (Baseline orientation, not a problem report.)"$'\n'"</environment>"
fi

# ---- persist state (both this session and the global anchor) ------------
write_state() {
  printf '%s\n' "$now" "$SSID" "$POWER" "$DISPLAYS" "$NET" "$WAKETIME" "$BOOTTIME" > "$1.tmp" 2>/dev/null \
    && mv -f "$1.tmp" "$1" 2>/dev/null
}
write_state "$SESS_FILE"
write_state "$GLOB_FILE"
exit 0
