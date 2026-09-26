#!/bin/bash
# reap-idle-claude.sh — free RAM by exiting idle Claude Code TUI sessions (macOS).
#
# Idle Claude Code sessions hold 200-600+ MB each, indefinitely. Sessions are
# losslessly resumable (`claude --resume <id>`), so an idle one has no reason
# to stay resident. Before a session is reaped, its transcript is summarized
# (claude -p) and the summary + exact resume command are printed into the
# session's own terminal tab — so the tab is never left blank.
#
# Guards: only kills a `claude` TUI whose tab has had no keystroke for
# IDLE_HOURS, whose CPU is 0, and whose transcript has had no new message for
# QUIET_MINS (protects autonomous loops that run without keyboard input).
# Sessions that can't be mapped to a transcript are skipped, never killed.
# Also skipped (a reap would orphan live work — bg tasks/watches do NOT come
# back on --resume, per docs):
#   - session's own status file says busy (mid-turn) or waiting (dialog open)
#   - live child processes (backgrounded Bash tasks run as children of the TUI)
#   - recent background-task output in the session's scratchpad tasks/ dir
#     (covers background subagents too — their .output symlinks to the live
#     subagent transcript, hence the find -L)
#   - an artifact watch armed in the last WATCH_HOURS (transcript heuristic:
#     watches are in-process only, nothing on disk records them)
#
# DRY_RUN=1   — list what would be reaped, touch nothing
# ONLY_PID=n  — restrict to one process (testing / reap-on-demand)
# MAX_KILLS=n — cap reaps per run

# Idle threshold: minutes with no keystroke in the tab. IDLE_HOURS is still
# honored (IDLE_HOURS=2 == IDLE_MINS=120) so old configs and the on-demand
# `IDLE_HOURS=0` override keep working; IDLE_MINS wins if both are set.
IDLE_MINS=${IDLE_MINS:-${IDLE_HOURS:+$((IDLE_HOURS * 60))}}
IDLE_MINS=${IDLE_MINS:-240}
QUIET_MINS=${QUIET_MINS:-120}
WATCH_HOURS=${WATCH_HOURS:-24}  # how long an armed artifact watch protects a session
MAX_KILLS=${MAX_KILLS:-100}
PROJECTS="$HOME/.claude/projects"
REG_DIR=${REG_DIR:-$HOME/.claude/scripts}  # where reaped-<tty> resume records go (read by ccr)
CLAUDE_BIN=${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}
# launchd's minimal PATH misses Homebrew/cargo installs, so probe the usual
# homes like CLAUDE_BIN does — a bare `command -v atuin` silently disarmed
# the Ctrl-R resume path on every scheduled run
ATUIN_BIN=${ATUIN_BIN:-$(command -v atuin || ls /opt/homebrew/bin/atuin /usr/local/bin/atuin "$HOME/.atuin/bin/atuin" 2>/dev/null | head -1)}
now=$(date +%s)
killed=0
mkdir -p "$REG_DIR"
find "$REG_DIR" -name 'reaped-ttys*' -mtime +30 -delete 2>/dev/null

log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

fmt_idle() { # seconds -> "13m" (sub-2h) or "4h" — readable at any threshold
  local m=$(( $1 / 60 ))
  if [ "$m" -ge 120 ]; then printf '%dh' $(( m / 60 )); else printf '%dm' "$m"; fi
}

with_timeout() { # seconds cmd...
  local t=$1; shift
  # <&0 is load-bearing: a backgrounded command in a non-interactive shell gets
  # its stdin reassigned to /dev/null, which would silently drop the transcript
  # piped in by summarize(). Explicitly reattach fd 0 (the pipe) to the job.
  "$@" <&0 & local p=$!
  # watchdog must not inherit our stdout: a $(capture) waits for the pipe to
  # close, so an inherited fd would block the caller until the sleep finishes
  ( sleep "$t"; kill -9 "$p" 2>/dev/null ) >/dev/null 2>&1 & local w=$!
  wait "$p" 2>/dev/null; local rc=$?
  kill "$w" 2>/dev/null
  return $rc
}

claimed=" "
config_dir_of() { # pid -> that process's CLAUDE_CONFIG_DIR (default ~/.claude)
  # `claude-as <profile>` runs claude with CLAUDE_CONFIG_DIR=~/.claude-<profile>,
  # whose sessions/ and projects/ live there — scanning ~/.claude for such a
  # pid mapped it to an unrelated (often already-dead) transcript.
  local c
  c=$(ps -E -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | sed -n 's/^CLAUDE_CONFIG_DIR=//p' | head -1)
  printf '%s' "${c:-$HOME/.claude}"
}

sess_cfg=$HOME/.claude  # set per pid in the main loop (session_file runs in a $() subshell)
session_file() { # pid args -> transcript path (empty if unmappable); reads $sess_cfg
  local uuid start best bestd f b d cwd proj projects
  projects="$sess_cfg/projects"
  # Authoritative source first: Claude Code keeps ~/.claude/sessions/<pid>.json
  # with the LIVE sessionId. argv (`--resume <id>`) is frozen at launch — after
  # /branch (or a fork-on-resume) the process writes a different id, and
  # trusting argv recorded the stale parent for ccr, evaluated QUIET_MINS
  # against the wrong (quiet) transcript, and printed the wrong recap.
  uuid=$(sed -n 's/.*"sessionId":"\([0-9a-f-]\{36\}\)".*/\1/p' "$sess_cfg/sessions/$1.json" 2>/dev/null | head -1)
  [ -n "$uuid" ] || uuid=$(grep -oE '\-\-?r(esume)? [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$2" | awk '{print $2}')
  if [ -n "$uuid" ]; then
    ls "$projects"/*/"$uuid".jsonl 2>/dev/null | head -1
    return
  fi
  start=$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p "$1" | tr -s ' ')" +%s 2>/dev/null) || return
  # a session's transcript lives under the project dir derived from its cwd
  # (non-alphanumerics become '-'). Scan only that dir: a global scan let this
  # script's own `claude -p` summarizer transcripts (cwd=/, project '-') win
  # the birth-time race, printing recaps and resume ids for the wrong session
  # and evaluating the QUIET_MINS guard against the wrong transcript.
  cwd=$(lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  [ -n "$cwd" ] || return
  proj=$(printf '%s' "$cwd" | sed 's/[^a-zA-Z0-9]/-/g')
  # fresh session: its transcript is created shortly after process start —
  # never before it, so a negative delta beyond clock granularity is another
  # session's file; near-simultaneous launches contend, so claimed ones are out
  bestd=1800
  for f in "$projects/$proj"/*.jsonl; do
    case "$claimed" in *" $f "*) continue;; esac
    b=$(stat -f %B "$f" 2>/dev/null) || continue
    d=$((b - start))
    if [ "$d" -ge -5 ] && [ "$d" -le "$bestd" ]; then bestd=$d; best=$f; fi
  done
  echo "$best"
}

SUMMARY_MODEL=${SUMMARY_MODEL:-sonnet}
SUMMARY_PROMPT='Below is a cleaned-up transcript of a Claude Code session that is being paused. Write the note that will be printed in that terminal tab for the person who was driving the session — they have been away, have lost the thread, and must understand where things stand in one read. Address them as "you".

Write like a sharp colleague explaining in plain words, not like a log. State outcomes as facts about the world ("PR #2725 now passes CI", "db/stacks.json wording fixed"), never as a narration of steps — do not use words like opened, ran, encountered, extracted, navigated, attempted. Name the concrete things: repo, files, PR numbers, ids, commands, names. If the user asked for something and got it, say so plainly. If something failed or was blocked, say what and why in a few words.

Plain text only — no markdown, no asterisks, no backticks. Under 170 words. Use exactly this shape:

About: <one line: what this session is about and what you were trying to get>

Done so far:
- <2 to 5 bullets; each one a result, most important first>

Still open:
- <what is unfinished, or a question that was waiting for your answer; write "nothing" if the work was wrapped up>

Next: <one imperative sentence: the single most useful thing to do on resume, and who does it (you decide X / tell Claude to do Y)>'

summarize() { # transcript -> stdout summary
  # transcript-digest.py strips tool results/blobs down to user+assistant turns
  # (+ one-line tool markers) so the model sees the conversation, not JSON;
  # falls back to the raw tail if the digest is unavailable.
  { python3 "$REG_DIR/transcript-digest.py" "$1" 60000 2>/dev/null || tail -c 150000 "$1"; } \
    | with_timeout 120 "$CLAUDE_BIN" --model "$SUMMARY_MODEL" -p "$SUMMARY_PROMPT" 2>/dev/null
}

last_activity() { # transcript -> epoch of last real message (mtime is unreliable:
  # Claude Code bulk-touches transcript mtimes, e.g. during startup grooming)
  local iso
  iso=$(tail -c 50000 "$1" | grep -oE '"timestamp":"[0-9T:.-]+' | tail -1 | cut -d'"' -f4)
  if [ -n "$iso" ]; then TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${iso%%.*}" +%s 2>/dev/null && return; fi
  stat -f %m "$1"
}

while read -r pid cpu tty args; do
  [ "$killed" -ge "$MAX_KILLS" ] && break
  cmd=${args%% *}
  [ "${cmd##*/}" = "claude" ] || continue
  [ -n "$ONLY_PID" ] && [ "$pid" != "$ONLY_PID" ] && continue
  case " $args " in *" -p "*|*"--print"*|*" mcp "*) continue;; esac
  [ "$tty" = "??" ] && continue
  [ -e "/dev/$tty" ] || continue
  [ "${cpu%.*}" -eq 0 ] 2>/dev/null || continue

  idle=$(( now - $(stat -f %a "/dev/$tty") ))
  [ "$idle" -ge $(( IDLE_MINS * 60 )) ] || continue

  # a backgrounded Bash task (run_in_background / moved-to-background timeout)
  # runs as a live child of the TUI; killing the TUI orphans it and its
  # completion is never recorded ("marked stopped" on resume). Any child ->
  # skip. Sessions here run no stdio MCP children, so this can't disarm the
  # reaper permanently; the log line names the child so a permanent skip is
  # diagnosable if that ever changes.
  kid=$(pgrep -P "$pid" | head -1)
  if [ -n "$kid" ]; then
    log "skip pid=$pid tty=$tty: live child pid=$kid ($(ps -o command= -p "$kid" 2>/dev/null | cut -c1-100))"
    continue
  fi

  sess_cfg=$(config_dir_of "$pid")

  # the session's own status file: busy = mid-turn (a long tool call writes no
  # transcript message until it returns), waiting = a dialog is open on screen.
  # Trust it only if procStart matches this pid (guards stale files after pid
  # reuse). Missing file or status -> fall through to the other guards.
  sfile="$sess_cfg/sessions/$pid.json"
  if [ -f "$sfile" ]; then
    st=$(sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' "$sfile" | head -1)
    # the file writes procStart in UTC, ps lstart prints local time — compare
    # as epochs, or the guard never fires
    fstart=$(sed -n 's/.*"procStart":"\([^"]*\)".*/\1/p' "$sfile" | tr -s ' ')
    fts=$(TZ=UTC date -j -f '%a %b %d %T %Y' "$fstart" +%s 2>/dev/null)
    pts=$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p "$pid" | tr -s ' ' | sed 's/^ //')" +%s 2>/dev/null)
    if [ -n "$st" ] && [ "$st" != "idle" ] && [ -n "$fts" ] && [ "$fts" = "$pts" ]; then
      log "skip pid=$pid tty=$tty: session status=$st"
      continue
    fi
  fi

  sess=$(session_file "$pid" "$args")
  if [ -z "$sess" ] || [ ! -f "$sess" ]; then
    log "skip pid=$pid tty=$tty: no transcript mapping"
    continue
  fi
  claimed="$claimed$sess "
  quiet=$(( now - $(last_activity "$sess") ))
  if [ "$quiet" -lt $(( QUIET_MINS * 60 )) ]; then
    log "skip pid=$pid tty=$tty: transcript active ${quiet}s ago ($(basename "$sess"))"
    continue
  fi

  sid=$(basename "$sess" .jsonl)

  # background tasks and subagents stream into the session scratchpad:
  # /private/tmp/claude-<uid>/<proj-slug>/<sid>/tasks/<id>.output. A subagent's
  # .output is a symlink to its live transcript, so -L follows it. Recent
  # write -> work is (or just was) running; its completion notification may not
  # be absorbed yet, and neither survives a kill.
  tdir="/private/tmp/claude-$(id -u)/$(basename "$(dirname "$sess")")/$sid/tasks"
  busy_task=$(find -L "$tdir" -name '*.output' -mmin -"$QUIET_MINS" 2>/dev/null | head -1)
  if [ -n "$busy_task" ]; then
    log "skip pid=$pid tty=$tty: background task active ($(basename "$busy_task"))"
    continue
  fi

  # artifact watches live in-process only — nothing on disk records one, so
  # grep the transcript tail for the arming marker the Artifact tool result
  # prints, and honor it for WATCH_HOURS. After that, reaping wins: RAM comes
  # back, and --resume usually re-arms the most recent watch.
  warm=$(tail -c 500000 "$sess" | grep -E 'Live subscription|auto-replies armed|"action": ?"watch"' >/dev/null \
    && tail -c 500000 "$sess" | grep -E 'Live subscription|auto-replies armed|"action": ?"watch"' \
       | grep -oE '"timestamp": ?"[0-9T:.-]+' | tail -1 | grep -oE '[0-9T:.-]+$')
  if [ -n "$warm" ]; then
    wts=$(TZ=UTC date -j -f '%Y-%m-%dT%H:%M:%S' "${warm%%.*}" +%s 2>/dev/null)
    if [ -n "$wts" ] && [ $(( now - wts )) -lt $(( WATCH_HOURS * 3600 )) ]; then
      log "skip pid=$pid tty=$tty: artifact watch armed $(fmt_idle $(( now - wts ))) ago"
      continue
    fi
  fi

  rss_mb=$(( $(ps -o rss= -p "$pid" | tr -d ' ') / 1024 ))
  if [ -n "$DRY_RUN" ]; then
    log "DRY-RUN would reap pid=$pid tty=$tty rss=${rss_mb}MB tty-idle=$(fmt_idle "$idle") session=$sid"
    continue
  fi

  log "reaping pid=$pid tty=$tty rss=${rss_mb}MB tty-idle=$(fmt_idle "$idle") session=$sid"
  # the tab's identity for ccr: the shell that launched this claude, by pid AND
  # start time. tty names are recycled when a tab closes, so a record keyed on
  # the name alone gets served to whatever new tab inherits it.
  tab_pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  tab_key="$tab_pid@$(ps -o lstart= -p "$tab_pid" 2>/dev/null)"
  kill "$pid" 2>/dev/null || continue
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && { log "pid=$pid ignored SIGTERM, leaving it alone"; continue; }
  killed=$((killed + 1))

  # keyboard-only restart: the tab's shell survives the reap, so record
  # "<session-id>\t<cwd>" per tty for the `ccr` executable and register the
  # resume command in atuin (when installed) so Ctrl-R surfaces it in any
  # tab. cwd comes from the transcript's own records — `claude --resume`
  # resolves ids per project dir, so resuming elsewhere must cd there first.
  resume="claude --resume $sid --dangerously-skip-permissions"
  cfg_field=
  if [ "$sess_cfg" != "$HOME/.claude" ]; then
    resume="CLAUDE_CONFIG_DIR=$sess_cfg $resume"; cfg_field=$sess_cfg
  fi
  scwd=$(tail -c 50000 "$sess" | grep -o '"cwd":"[^"]*"' | tail -1 | cut -d'"' -f4)
  # third field: non-default CLAUDE_CONFIG_DIR (empty for ~/.claude); ccr exports it
  # fourth field: tab_key; ccr resumes only from that same shell
  printf '%s\t%s\t%s\t%s\n' "$sid" "${scwd:-$HOME}" "$cfg_field" "$tab_key" > "$REG_DIR/reaped-$tty" 2>/dev/null
  hint="run: ccr"
  if [ -n "$ATUIN_BIN" ] && [ -x "$ATUIN_BIN" ]; then
    ( cd "${scwd:-$HOME}" 2>/dev/null || cd "$HOME"
      export ATUIN_SESSION=${ATUIN_SESSION:-$("$ATUIN_BIN" uuid)}
      hid=$("$ATUIN_BIN" history start -- "$resume") && "$ATUIN_BIN" history end --exit 0 -- "$hid"
    ) >/dev/null 2>&1 && hint="Ctrl-R ⏎, or $hint"
  fi

  summary=$(summarize "$sess")
  [ -n "$summary" ] || summary="(summary unavailable — transcript intact)"
  {
    printf '\n\033[2m────────────────────────────────────────────\033[0m\n'
    printf '\033[1m💤 Idle Claude session closed to free %sMB\033[0m (no input for %s)\n\n' "$rss_mb" "$(fmt_idle "$idle")"
    printf '%s\n\n' "$summary"
    printf '\033[1m▶ Pick up where you left off:\033[0m  %s\n' "$resume"
    printf '\033[2m   no retype needed — %s\033[0m\n' "$hint"
    printf '\033[2m────────────────────────────────────────────\033[0m\n'
    # terminals fall back to showing the cwd as tab title once the TUI dies;
    # rename the tab to the session topic so reaped tabs stay identifiable
    title=$(printf '%s\n' "$summary" | sed -n '1s/^\(About\|Topic\):[[:space:]]*//p' | cut -c1-60)
    printf '\033]0;💤 %s\007' "${title:-claude session (reaped)}"
  } > "/dev/$tty" 2>/dev/null
done < <(ps -axo pid=,%cpu=,tty=,args=)

log "done: reaped $killed session(s)"
