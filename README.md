# claude-system-awareness

A [Claude Code](https://claude.com/claude-code) hook that tells the model when your **machine's environment changed** — the laptop slept, the Wi-Fi switched, power was unplugged, a monitor was added, or a chunk of time passed — so it stops mistaking environmental breakage for its own mistakes.

> macOS only. Everything runs locally — no network calls, no telemetry. MIT licensed.

## The problem

You close your laptop and walk away. Three hours later you reopen it and ask Claude Code to keep going. But while it was asleep: the dev server died, the DB socket dropped, your auth token expired, the Wi-Fi is now the coffee-shop captive portal, and "today" is no longer the day it thinks it is.

The model has **no idea any of that happened**. So when the next command fails, it assumes *it* broke something — and starts "fixing" code that was always fine, or re-running things that fail for reasons it can't see.

This hook gives the model a short, factual heads-up at exactly those moments.

## What it looks like

When something changed, it injects an `<environment-change>` note before your prompt:

```
<environment-change>
Environmental changes detected since this session was last active. This is
orientation only — your prior work and reasoning are intact and nothing has
gone wrong on your end:
- 💤 The machine SLEPT and woke 2m ago (woke Tue 15:52). Sleep silently
  interrupts network sockets, timers, watch processes, and dev servers — if
  something is broken right now, suspect the sleep, not your previous actions.
- ⏱ ~3h 11m elapsed since the last activity here (was Tue 12:41, now Tue
  2026-06-30 15:52 EDT). Treat time-sensitive context as stale: 'today', auth
  tokens, caches, running timers, and the state of any open PRs/CI/builds.
- 📶 Wi-Fi changed: "HomeNet" → "SBUX-Guest". Location/network context likely
  changed (home/office/travel). Expect different latency, a possible captive
  portal, and that VPN/LAN/internal hosts reachable before may now be
  unreachable (or vice-versa).
- 🔋 Unplugged — on battery (82%).
- 🖥 Displays: 2 → 1 (monitor disconnected — possibly undocked / moved workstation).
If a command, tool, or network action fails right after this notice, suspect the
environment first ... before concluding your approach is wrong.
</environment-change>
```

When **nothing** changed it stays completely silent. A brand-new session (or one you just `/clear`ed) gets a one-line baseline instead:

```
<environment>
Session environment: Wi-Fi "HomeNet" · AC (100%) · 2 displays · online · Tue 2026-06-30 17:09 EDT.
</environment>
```

## What it detects

| Signal | How | Why the model cares |
|---|---|---|
| 💤 **Sleep / wake** (lid close+reopen) | `sysctl kern.waketime` | Dead sockets, stalled timers, dropped dev servers — the big one. |
| 🔁 Reboot | `sysctl kern.boottime` | Background servers / port-forwards / shell state are gone. |
| ⏱ Elapsed time | stored timestamp vs now | "today", tokens, caches, CI/PR state may be stale. Default threshold 30 min. |
| 📶 Wi-Fi / location | `ipconfig getsummary` | Home vs office vs travel; captive portals; LAN/VPN reachability flips. |
| 🌐 Online / offline | `route -n get default` | Network calls/installs/git will fail — not a bug in the work. |
| 🔌 AC / battery | `pmset -g batt` | May idle-sleep or throttle; long tasks can be interrupted. |
| 🖥 Monitor add / remove | `CGGetActiveDisplayList` (Swift) | Implies docking / changed workstation. |

## How it works

- **Fires on `UserPromptSubmit` and `SessionStart`.** Each run reads current state, diffs it against the last state recorded **for this session**, and emits only the differences. ~0.1–0.2s; silent when nothing changed.
- **Per-session state**, keyed by Claude Code's `session_id` (which `--resume` reuses), so the time-gap is correct across resumes and concurrent sessions each get oriented independently — plus a global anchor so a fresh session after time away is still oriented.
- **No daemon.** Every signal is a *net change between prompts*, which is exactly what orients the model. Nothing to keep running.
- **Safe by construction.** It can never block a prompt (every probe is guarded; it always exits 0), makes no network calls, and stores state line-delimited — never `eval`'d — so a hostile Wi-Fi name can't inject anything.

## Requirements

- macOS
- [Claude Code](https://claude.com/claude-code)
- `python3` (ships with the Xcode Command Line Tools: `xcode-select --install`)
- Optional: `swiftc` for the fast ~10ms display check (without it, falls back to `system_profiler`)

## Install

```sh
git clone https://github.com/jlreyes/claude-system-awareness.git
cd claude-system-awareness
./install.sh
```

The installer copies the hook into `~/.claude/hooks/`, compiles the Swift helper, and **idempotently** adds the two hook entries to `~/.claude/settings.json` (backing it up first, never duplicating). Re-running is safe. It activates on your next prompt/session.

> Prefer to do it by hand? Copy `hooks/` into `~/.claude/hooks/`, run
> `swiftc -O ~/.claude/hooks/system-context/displaycount.swift -o ~/.claude/hooks/system-context/displaycount`,
> and add this to the `"hooks"` object in `~/.claude/settings.json` (both events
> point at the same script; it reads the event from stdin):
>
> ```json
> "UserPromptSubmit": [
>   { "hooks": [ { "type": "command", "command": "~/.claude/hooks/system-context-nudge.sh", "timeout": 10 } ] }
> ],
> "SessionStart": [
>   { "hooks": [ { "type": "command", "command": "~/.claude/hooks/system-context-nudge.sh", "timeout": 10 } ] }
> ]
> ```
> (Use the absolute path to your home dir in the command.)

## Configuration

Set these in the `"env"` block of `settings.json` or your shell:

| Variable | Default | Effect |
|---|---|---|
| `NUDGE_TIME_THRESHOLD_SECS` | `1800` | Elapsed-time nudge threshold (seconds). Sleep/reboot/Wi-Fi/power/display/network changes are always reported regardless. |
| `NUDGE_STATE_TTL_DAYS` | `7` | Prune per-session state files older than this. |
| `NUDGE_HOME` | _(script dir)_`/system-context` | Where the helper + state live. |
| `NUDGE_PYTHON` | `/usr/bin/python3` | python3 to use for JSON. |

## Privacy

100% local. No network requests, no analytics. The current Wi-Fi name, power, display count, and timestamps are written only into **your own** Claude Code context and to state files under `~/.claude/hooks/system-context/state/` (git-ignored). Nothing leaves your machine.

## Uninstall

```sh
./uninstall.sh
```

Removes the settings entries (backing up first) and the installed files.

## Why these specific tools?

A few macOS-specific choices that took some digging — documented so you don't have to rediscover them:

- **`sysctl kern.waketime`** for sleep detection instead of `pmset -g log`, which is correct but takes ~3s. `waketime` is instant and gives the exact last wake.
- **`ipconfig getsummary <iface>`** for the SSID. The usual `networksetup -getairportnetwork` is blocked by Location Services on modern macOS and returns "not associated"; `ipconfig getsummary` isn't.
- **`CGGetActiveDisplayList`** (a tiny compiled Swift helper) for display count — ~10ms and exact, vs ~400ms for `system_profiler`.

## License

MIT © James Reyes
