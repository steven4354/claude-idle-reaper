# cr — restart the Claude Code session that was reaped in THIS tab, no retyping.
# The reaper writes "<session-id>\t<cwd>" to reaped-<tty> as it kills a session
# (see reap-idle-claude.sh); the tab's shell survives the reap, so typing `cr`
# is all a dead tab needs. Falls back to the machine's most recent reap when
# this tty has none (tab closed, picking the session up elsewhere); `cr <id>`
# resumes an explicit session id.
# Install: source this file from ~/.zshrc.
cr() {
  local reg_dir="${CR_REG_DIR:-$HOME/.claude/scripts}" reg id cwd
  if [[ -n "$1" ]]; then claude --resume "$1"; return $?; fi
  reg="$reg_dir/reaped-${TTY##*/}"
  if [[ ! -f "$reg" ]]; then
    reg=$(command ls -t "$reg_dir"/reaped-ttys* 2>/dev/null | head -1)
    [[ -n "$reg" ]] || { print -ru2 -- "cr: no reaped session recorded"; return 1; }
    print -ru2 -- "cr: nothing reaped in this tab — resuming the most recent reap (${reg:t})"
  fi
  IFS=$'\t' read -r id cwd < "$reg"
  [[ -n "$id" ]] || { print -ru2 -- "cr: $reg is empty"; return 1; }
  # `claude --resume` resolves ids per project dir, so run from the session's
  # own cwd; the subshell keeps this tab's cwd untouched after claude exits
  ( builtin cd "${cwd:-$HOME}" 2>/dev/null || builtin cd "$HOME"; claude --resume "$id" )
}
