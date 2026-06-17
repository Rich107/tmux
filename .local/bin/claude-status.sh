#!/usr/bin/env bash
# claude-status — scan all tmux sessions/windows/panes, find Claude Code
# instances and report each one's state: NEEDS INPUT (permission/question),
# WORKING (thinking / running a tool), or IDLE (waiting for a prompt).
#
# Usage:
#   claude-status            pretty table, sorted by priority
#   claude-status -w         watch mode (refresh every 2s)
#   claude-status -n SECS    watch with custom interval
#   claude-status -p         plain output (no colour, for piping/status bars)
#   claude-status -j         JSON output (one object per pane)
#
# State is inferred from the *visible* pane text, because Claude Code renders
# its status into the TUI rather than exposing it any other way.

set -uo pipefail

PLAIN=0; JSON=0; WATCH=0; INTERVAL=2
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--plain) PLAIN=1 ;;
    -j|--json)  JSON=1 ;;
    -w|--watch) WATCH=1 ;;
    -n) shift; INTERVAL="${1:-2}"; WATCH=1 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$PLAIN" = 1 ] || [ "$JSON" = 1 ] || [ ! -t 1 ]; then
  C_RESET=""; C_RED=""; C_YEL=""; C_GRN=""; C_DIM=""; C_BOLD=""; C_CYAN=""
else
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_YEL=$'\033[33m'
  C_GRN=$'\033[32m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_CYAN=$'\033[36m'
fi

# Classify one pane's captured text. Echoes:  PRIORITY<TAB>STATE<TAB>DETAIL
# PRIORITY: 0 needs-input, 1 working, 2 idle, 9 not-claude
classify() {
  local cap="$1"

  # Is this even a Claude Code pane?  Footer / chrome signatures.
  if ! grep -qE 'esc to interrupt|[0-9][0-9,]* tokens|current: [0-9]+\.[0-9]+\.[0-9]+|⏵⏵ (bypass permissions|accept edits)|Esc to cancel · Tab to amend|✻ Welcome to Claude' <<<"$cap"; then
    printf '9\t-\t-'
    return
  fi

  # 1) NEEDS INPUT — a permission prompt or a multiple-choice question is open.
  if grep -qE 'Esc to cancel · Tab to amend|❯ [0-9]+\. (Yes|No)|Do you want to (proceed|make this edit|create|run)|Would you like to proceed|Ready to code\?' <<<"$cap"; then
    local q
    q=$(grep -oE 'Do you want to [^?]*\?|Would you like to proceed\?|Ready to code\?' <<<"$cap" | tail -1)
    [ -z "$q" ] && q="permission / choice prompt open"
    printf '0\tNEEDS INPUT\t%s' "$q"
    return
  fi

  # 2) WORKING — actively thinking or a tool is running (live timer present).
  if grep -qE 'esc to interrupt|⎿ +(Running|Waiting|Booting|Computing|Forking)…|[A-Za-z]+… \([0-9]+m? ?[0-9]*s' <<<"$cap"; then
    local d
    d=$(grep -oE '[A-Za-z]+… \([0-9][^)]*\)' <<<"$cap" | tail -1)
    [ -z "$d" ] && d=$(grep -oE '⎿ +(Running|Waiting|Booting|Computing|Forking)…' <<<"$cap" | tail -1 | sed 's/⎿ *//')
    [ -z "$d" ] && d="working…"
    printf '1\tWORKING\t%s' "$d"
    return
  fi

  # 3) IDLE — Claude chrome present, no work and no prompt open.
  printf '2\tIDLE\twaiting for a prompt'
}

# Pull a short human label for the pane: conversation title or token count.
context_label() {
  local cap="$1" title toks
  title=$(grep -oE '─+ [^─]+ ─+$' <<<"$cap" \
            | grep -vE '\([0-9]+ lines hidden\)|History [0-9]+/[0-9]+' \
            | tail -1 | sed -E 's/─//g; s/^ +//; s/ +$//')
  toks=$(grep -oE '[0-9][0-9,]* tokens' <<<"$cap" | tail -1)
  if [ -n "$title" ] && [ -n "$toks" ]; then echo "$title · $toks"
  elif [ -n "$title" ]; then echo "$title"
  else echo "$toks"; fi
}

scan() {
  local rows=() n_input=0 n_work=0 n_idle=0
  # Candidate panes: command looks like a node version (how Claude's runtime
  # reports itself) or is literally node/claude.
  while IFS=$'\t' read -r target cmd ; do
    case "$cmd" in
      [0-9]*.[0-9]*|node|claude|claude-code) ;;
      *) continue ;;
    esac
    local cap state prio detail label
    cap=$(tmux capture-pane -p -t "$target" 2>/dev/null) || continue
    IFS=$'\t' read -r prio state detail <<<"$(classify "$cap")"
    [ "$prio" = 9 ] && continue
    label=$(context_label "$cap")
    rows+=("$prio"$'\t'"$target"$'\t'"$state"$'\t'"$detail"$'\t'"$label")
    case "$prio" in 0) ((n_input++));; 1) ((n_work++));; 2) ((n_idle++));; esac
  done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}	#{pane_current_command}' 2>/dev/null)

  if [ "${#rows[@]}" -eq 0 ]; then
    [ "$JSON" = 1 ] && { echo '[]'; return; }
    echo "No Claude Code panes found in any tmux session."; return
  fi

  # Sort by priority (needs-input first).
  IFS=$'\n' rows=($(printf '%s\n' "${rows[@]}" | sort -t$'\t' -k1,1n -k2,2)); unset IFS

  if [ "$JSON" = 1 ]; then
    local first=1; echo "["
    for r in "${rows[@]}"; do
      IFS=$'\t' read -r prio target state detail label <<<"$r"
      [ "$first" = 1 ] || echo ","; first=0
      printf '  {"pane":"%s","state":"%s","detail":"%s","context":"%s"}' \
        "$target" "$state" "${detail//\"/\\\"}" "${label//\"/\\\"}"
    done
    echo; echo "]"; return
  fi

  printf '%s%-26s %-13s %s%s\n' "$C_BOLD" "PANE" "STATE" "DETAIL" "$C_RESET"
  for r in "${rows[@]}"; do
    IFS=$'\t' read -r prio target state detail label <<<"$r"
    local col dot
    case "$prio" in
      0) col="$C_RED";  dot="🔴" ;;
      1) col="$C_YEL";  dot="🟡" ;;
      2) col="$C_GRN";  dot="🟢" ;;
    esac
    printf '%s %-24s %s%-11s%s %s%s%s\n' \
      "$dot" "$target" "$col" "$state" "$C_RESET" "$detail" \
      "${label:+  $C_DIM[$label]$C_RESET}" ""
  done
  printf '%s%s%d need input · %d working · %d idle%s\n' \
    "$C_DIM" "" "$n_input" "$n_work" "$n_idle" "$C_RESET"
}

if [ "$WATCH" = 1 ]; then
  while :; do
    clear
    printf '%sClaude Code sessions  —  %s%s\n\n' "$C_CYAN" "$(date '+%H:%M:%S')" "$C_RESET"
    scan
    sleep "$INTERVAL"
  done
else
  scan
fi
