#!/usr/bin/env bash
# claude-jump — scan all tmux panes for Claude Code instances, show their
# state in an fzf picker (live preview of the pane), and on selection jump
# straight to that pane in its window/session.
#
# Each row:   <status> <session>/<window>/<claude-session-name> - <tokens> - <last-active>
# Sorted by:  session name, then window name, then claude-session name.
# Preview sits on the right; it is hidden automatically on narrow terminals.
#
# Usage:
#   claude-jump                 pick a Claude pane and switch to it
#   claude-jump -i              only panes that NEED INPUT (permission/question)
#   claude-jump -s name         order by session/window/name (default)
#   claude-jump -s recent       order by most recently interacted with first
#
# State is inferred from the visible pane text, same as claude-status.

set -uo pipefail

ONLY_INPUT=0
SORT=name
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--input) ONLY_INPUT=1 ;;
    -s|--sort)
      shift
      case "${1:-}" in
        name|recent) SORT="$1" ;;
        *) echo "invalid sort: '${1:-}' (use 'name' or 'recent')" >&2; exit 2 ;;
      esac ;;
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

command -v fzf >/dev/null || { echo "fzf is not installed" >&2; exit 1; }

now=$(date +%s)

# Classify one pane's captured text -> PRIORITY<TAB>STATE<TAB>DETAIL
# PRIORITY: 0 needs-input, 1 working, 2 idle, 9 not-claude
classify() {
  local cap="$1"
  if ! grep -qE 'esc to interrupt|[0-9][0-9,]* tokens|current: [0-9]+\.[0-9]+\.[0-9]+|⏵⏵ (bypass permissions|accept edits)|Esc to cancel · Tab to amend|✻ Welcome to Claude' <<<"$cap"; then
    printf '9\t-\t-'; return
  fi
  if grep -qE 'Esc to cancel · Tab to amend|❯ [0-9]+\. (Yes|No)|Do you want to (proceed|make this edit|create|run)|Would you like to proceed|Ready to code\?' <<<"$cap"; then
    printf '0\tNEEDS-INPUT\t'; return
  fi
  if grep -qE 'esc to interrupt|⎿ +(Running|Waiting|Booting|Computing|Forking)…|[A-Za-z]+… \([0-9]+m? ?[0-9]*s' <<<"$cap"; then
    printf '1\tWORKING\t'; return
  fi
  printf '2\tIDLE\t'
}

# Conversation ("claude session") name from the visible title separator.
claude_name() {
  local cap="$1" title
  title=$(grep -oE '─+ [^─]+ ─+$' <<<"$cap" \
            | grep -vE '\([0-9]+ lines hidden\)|History [0-9]+/[0-9]+' \
            | tail -1 | sed -E 's/─//g; s/^ +//; s/ +$//')
  [ -z "$title" ] && title="(untitled)"
  echo "$title"
}

# Token count from the footer, humanised (392654 -> 392k).
tokens_h() {
  local n; n=$(grep -oE '[0-9][0-9,]* tokens' <<<"$1" | tail -1 | grep -oE '[0-9,]+' | tr -d ,)
  [ -z "$n" ] && { echo "?"; return; }
  if [ "$n" -ge 1000 ]; then echo "$((n/1000))k"; else echo "$n"; fi
}

# Relative age from an epoch timestamp.
reltime() {
  local d=$(( now - ${1:-now} )); (( d<0 )) && d=0
  if   (( d<60 ));    then echo "${d}s"
  elif (( d<3600 ));  then echo "$((d/60))m"
  elif (( d<86400 )); then echo "$((d/3600))h"
  else                     echo "$((d/86400))d"; fi
}

# When Claude was last interacted with, as an epoch = mtime of the newest
# transcript in this pane's project dir (~/.claude/projects/<slug>).
# Slug = cwd with / and . -> -.  Falls back to tmux window_activity.
last_epoch() {
  local cwd="$1" fallback="$2" slug dir m
  slug=$(printf '%s' "$cwd" | sed 's/[/.]/-/g')
  dir="$HOME/.claude/projects/$slug"
  m=$(stat -f '%m' "$dir"/*.jsonl 2>/dev/null | sort -nr | head -1)
  [ -z "$m" ] && m="$fallback"
  printf '%s' "$m"
}

R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; D=$'\033[2m'; X=$'\033[0m'

build_list() {
  local rows=()
  while IFS=$'\t' read -r session window idx pidx cmd activity cwd ; do
    case "$cmd" in
      [0-9]*.[0-9]*|node|claude|claude-code) ;;
      *) continue ;;
    esac
    local target="$session:$idx.$pidx"
    local cap capmeta prio state _ cname toks age icon col
    # Visible screen drives state; a little scrollback recovers title/tokens
    # even when a dialog or spinner currently covers the footer.
    cap=$(tmux capture-pane -p -t "$target" 2>/dev/null) || continue
    capmeta=$(tmux capture-pane -p -S -300 -t "$target" 2>/dev/null) || capmeta="$cap"
    IFS=$'\t' read -r prio state _ <<<"$(classify "$cap")"
    [ "$prio" = 9 ] && continue
    [ "$ONLY_INPUT" = 1 ] && [ "$prio" != 0 ] && continue
    cname=$(claude_name "$capmeta"); toks=$(tokens_h "$capmeta")
    local epoch; epoch=$(last_epoch "$cwd" "$activity"); age=$(reltime "$epoch")
    local cname_lc; cname_lc=$(printf '%s' "$cname" | tr '[:upper:]' '[:lower:]')
    case "$prio" in
      0) icon="🔴"; col="$R" ;;
      1) icon="🟡"; col="$Y" ;;
      2) icon="🟢"; col="$G" ;;
    esac
    # epoch \t session \t window \t cname_lc \t target \t display
    local display
    display=$(printf '%s %s%-11s%s %s/%s/%s %s- %s tok - last %s%s' \
      "$icon" "$col" "$state" "$X" \
      "$session" "$window" "$cname" "$D" "$toks" "$age" "$X")
    rows+=("${epoch}"$'\t'"${session}"$'\t'"${window}"$'\t'"${cname_lc}"$'\t'"${target}"$'\t'"${display}")
  done < <(tmux list-panes -a -F '#{session_name}	#{window_name}	#{window_index}	#{pane_index}	#{pane_current_command}	#{window_activity}	#{pane_current_path}' 2>/dev/null)

  [ "${#rows[@]}" -eq 0 ] && return 1
  if [ "$SORT" = recent ]; then
    # Most-recently interacted with first (descending epoch).
    printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1nr | cut -f5-
  else
    # Order by session, then window, then claude-session name (case-insensitive).
    printf '%s\n' "${rows[@]}" | sort -f -t$'\t' -k2,2 -k3,3 -k4,4 | cut -f5-
  fi
}

list=$(build_list) || { echo "No Claude Code panes found." >&2; exit 0; }

# Width of the terminal fzf will draw into. In a tmux popup that is the popup
# itself (85% of screen), in a normal pane it is the pane — `tput cols` reflects
# whichever real tty we're attached to, so prefer it. Fall back to the tmux pane
# width, then 80, for the no-tty case (pipes / test harness).
cols=$(tput cols 2>/dev/null)
case "$cols" in ''|*[!0-9]*|0) cols=$(tmux display-message -p '#{pane_width}' 2>/dev/null) ;; esac
case "$cols" in ''|*[!0-9]*|0) cols=80 ;; esac
fzf_args=(--ansi --no-sort --delimiter='\t' --with-nth=2..
          --header='Claude panes — type to filter (session/window/name) · enter to jump')
if [ "$cols" -ge 100 ]; then
  fzf_args+=(--preview='tmux capture-pane -p -t {1} | tail -n 60'
             --preview-window='right,55%,wrap'
             --bind='ctrl-/:toggle-preview')
fi

sel=$(printf '%s\n' "$list" | fzf "${fzf_args[@]}")
[ -z "$sel" ] && exit 0

target=$(cut -f1 <<<"$sel")
session=${target%%:*}
tmux select-window -t "$target" 2>/dev/null
tmux select-pane   -t "$target" 2>/dev/null
if [ -n "${TMUX:-}" ]; then
  tmux switch-client -t "$session"
else
  tmux attach-session -t "$session"
fi
