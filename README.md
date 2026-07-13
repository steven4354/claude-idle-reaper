# claude-idle-reaper

Free the RAM held by idle Claude Code sessions — without losing them.

## Install (macOS)

```bash
curl -fsSL https://raw.githubusercontent.com/steven4354/claude-idle-reaper/main/install.sh | bash
```

That installs the script to `~/.claude/scripts/`, loads a launchd agent that
runs every 5 minutes, and finishes with a dry-run so you immediately see what
it would reap. Nothing is killed until the first scheduled run.

Uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/steven4354/claude-idle-reaper/main/install.sh | bash -s -- --uninstall
```

## The problem

Every interactive Claude Code session holds **200–600+ MB of RAM forever**, even
when it's been sitting idle in a terminal tab for days. If you work with many
tabs (Warp, iTerm, tmux), this quietly eats 10–15 GB and fills your swap. There
is no built-in idle-timeout, session-suspend, or memory-limit setting, and the
`NODE_OPTIONS --max-old-space-size` workaround doesn't apply to the native
binary install. (See anthropics/claude-code issues
[#25545](https://github.com/anthropics/claude-code/issues/25545),
[#18859](https://github.com/anthropics/claude-code/issues/18859),
[#4953](https://github.com/anthropics/claude-code/issues/4953).)

The key insight — borrowed from how OpenAI's Codex CLI stays lean — is that
**an idle session has no reason to exist as a process**. Claude Code persists
every transcript to disk continuously, and `claude --resume <id>` restores a
session losslessly. So: kill idle sessions, keep the resume path warm.

## What it does

A ~130-line bash script, run every 5 minutes by launchd, that:

1. Finds `claude` TUI processes that are safely idle — **all** of:
   - no keystroke in their tab for `IDLE_MINS` (default 240; `IDLE_HOURS` still
     honored, e.g. `IDLE_HOURS=2`), measured via tty atime
   - CPU at 0
   - no new transcript message for `QUIET_MINS` (default 2h) — this protects
     autonomous agents/loops that work without keyboard input
   - confidently mapped to their session transcript (unmappable → never killed)
2. SIGTERMs them (graceful; Claude Code exits cleanly)
3. Summarizes the session transcript with `claude --model haiku -p`
4. Prints the summary **into the dead session's own tab**, so instead of a
   blank screen you see:

```
────────────────────────────────────────────
💤 Idle Claude session closed to free 334MB (no input for 21h)

Topic: Diagnosing task system failures via telemetry
- Queried settlement telemetry and prod DB; found 22 tasks across 5 failure classes
- Judge-starvation P0 still live; no fix PR on main yet
- Applied debugging frameworks to map cascading mitigations as root causes

Pending: Write P0 fix PR, merge circuit breaker, add staleness alert.

▶ Pick up where you left off:  claude --resume 10da943d-4991-4ec7-a4a1-46287e89d3a1
   no retype needed — Ctrl-R ⏎, or type: cr
────────────────────────────────────────────
```

(Without this, the tab goes blank on exit — Claude Code renders on the
terminal's alternate screen, so the conversation vanishes with the process.)

## Restarting without the mouse

Selecting and copy-pasting the resume command gets old fast, so each reap also
arms two keyboard-only paths:

- **`cr`** — the reaper records `<session-id> <cwd>` per tty in
  `~/.claude/scripts/reaped-<tty>`. Add `source ~/.claude/scripts/cr.zsh` to
  your `~/.zshrc` and typing `cr` in a reaped tab restarts exactly that tab's
  session (it cd's to the session's own project dir first, since
  `claude --resume` resolves ids per directory). With the tab closed, `cr`
  in any shell falls back to the machine's most recent reap, and
  `cr <session-id>` resumes an explicit id.
- **atuin** — if [atuin](https://github.com/atuinsh/atuin) is installed, the
  resume command is registered in its history as the reap happens, so `Ctrl-R`
  `Enter` restarts the session from any tab (it sits at the top of the search
  until you run something else). No configuration; skipped when atuin is
  absent.

Records older than 30 days are pruned automatically.

## Usage beyond the scheduled timer

Dry run (list victims, touch nothing):

```bash
DRY_RUN=1 bash ~/.claude/scripts/reap-idle-claude.sh
```

Reap one specific tab on demand, overriding the idle guards:

```bash
ONLY_PID=12345 IDLE_HOURS=0 QUIET_MINS=0 bash ~/.claude/scripts/reap-idle-claude.sh
```

Reap more aggressively — sub-hour idle, checked often — by adding an
`EnvironmentVariables` dict (`IDLE_MINS`, `QUIET_MINS`) and lowering
`StartInterval` in the plist. Be careful: a short `QUIET_MINS` will reap
autonomous loops between wakeups (see Caveats).

Log: `~/.claude/scripts/idle-reaper.log`

## Manual install

If you'd rather not pipe curl to bash: clone the repo, then

```bash
./install.sh                      # same effect, uses the local files
```

or copy `reap-idle-claude.sh` to `~/.claude/scripts/`, `sed` your `$HOME` into
`com.user.claude-idle-reaper.plist`, drop it in `~/Library/LaunchAgents/`, and
`launchctl bootstrap gui/$(id -u) <plist>`.

## Implementation notes (the non-obvious parts)

- **PID → session mapping.** Claude Code doesn't keep its transcript file
  open. Resumed sessions carry the session UUID in their command line
  (`claude --resume <uuid>`); fresh sessions are matched by transcript file
  *birth time* (`stat -f %B`) falling just after process start, scanning only
  the project directory derived from the process's cwd (`lsof -d cwd`) — a
  global scan let transcripts of unrelated `claude -p` runs, including this
  script's own summarizer, win the birth-time race. Near-simultaneous launches
  are disambiguated by claiming each transcript at most once; anything
  ambiguous is skipped, not killed.
- **Transcript mtime lies.** Claude Code bulk-touches transcript mtimes
  (dozens of files at the same second, e.g. during startup grooming), so
  "recently modified" ≠ "recently active". The script reads the last embedded
  `"timestamp":` from the file tail instead.
- **Idle = tty atime.** Last keyboard input in the tab is `stat -f %a
  /dev/ttysNNN` — the same signal `w` uses.
- The summary is printed *after* the process dies, so it lands on the normal
  screen buffer (the alternate screen is gone by then) and persists in the tab.

## Caveats

- macOS only (BSD `stat`/`date`/launchd). A Linux port needs `stat -c`,
  GNU `date -d`, and a systemd user timer — PRs welcome.
- A session that's mid-turn but blocked on a very long API call shows 0% CPU;
  the 4h keyboard-idle + 2h transcript-quiet thresholds are what protect it.
  Don't crank both to near zero.
- The Haiku summary costs one small API call per reaped session.

## License

MIT
