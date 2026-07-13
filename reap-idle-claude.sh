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
MAX_KILLS=${MAX_KILLS:-100}
PROJECTS="$HOME/.claude/projects"
CLAUDE_BIN=${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}
now=$(date +%s)
killed=0

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
session_file() { # pid args -> transcript path (empty if unmappable)
  local uuid start best bestd f b d
  uuid=$(grep -oE '\-\-?r(esume)? [0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' <<<"$2" | awk '{print $2}')
  if [ -n "$uuid" ]; then
    ls "$PROJECTS"/*/"$uuid".jsonl 2>/dev/null | head -1
    return
  fi
  start=$(date -j -f '%a %b %d %T %Y' "$(ps -o lstart= -p "$1" | tr -s ' ')" +%s 2>/dev/null) || return
  # fresh session: its transcript is created shortly after process start;
  # near-simultaneous launches contend for the same file, so claimed ones are out
  bestd=1800
  for f in "$PROJECTS"/*/*.jsonl; do
    case "$claimed" in *" $f "*) continue;; esac
    b=$(stat -f %B "$f" 2>/dev/null) || continue
    d=$((b - start))
    if [ "$d" -ge -120 ] && [ "$d" -le "$bestd" ]; then bestd=$d; best=$f; fi
  done
  echo "$best"
}

summarize() { # transcript -> stdout summary
  tail -c 150000 "$1" | with_timeout 90 "$CLAUDE_BIN" --model haiku -p \
    "These are the trailing JSONL transcript lines of a Claude Code session being closed to free memory. Write a compact plain-text recap for its terminal tab: first line 'Topic: ...'; then 3-5 short '-' bullets of what was done or decided; last line 'Pending: ...' only if something was left unfinished. No markdown, under 120 words." 2>/dev/null
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
  rss_mb=$(( $(ps -o rss= -p "$pid" | tr -d ' ') / 1024 ))
  if [ -n "$DRY_RUN" ]; then
    log "DRY-RUN would reap pid=$pid tty=$tty rss=${rss_mb}MB tty-idle=$(fmt_idle "$idle") session=$sid"
    continue
  fi

  log "reaping pid=$pid tty=$tty rss=${rss_mb}MB tty-idle=$(fmt_idle "$idle") session=$sid"
  kill "$pid" 2>/dev/null || continue
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
  kill -0 "$pid" 2>/dev/null && { log "pid=$pid ignored SIGTERM, leaving it alone"; continue; }
  killed=$((killed + 1))

  summary=$(summarize "$sess")
  [ -n "$summary" ] || summary="(summary unavailable — transcript intact)"
  {
    printf '\n\033[2m────────────────────────────────────────────\033[0m\n'
    printf '\033[1m💤 Idle Claude session closed to free %sMB\033[0m (no input for %s)\n\n' "$rss_mb" "$(fmt_idle "$idle")"
    printf '%s\n\n' "$summary"
    printf '\033[1m▶ Pick up where you left off:\033[0m  claude --resume %s\n' "$sid"
    printf '\033[2m────────────────────────────────────────────\033[0m\n'
    # terminals fall back to showing the cwd as tab title once the TUI dies;
    # rename the tab to the session topic so reaped tabs stay identifiable
    title=$(printf '%s\n' "$summary" | sed -n '1s/^Topic:[[:space:]]*//p' | cut -c1-60)
    printf '\033]0;💤 %s\007' "${title:-claude session (reaped)}"
  } > "/dev/$tty" 2>/dev/null
done < <(ps -axo pid=,%cpu=,tty=,args=)

log "done: reaped $killed session(s)"
