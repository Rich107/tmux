#!/usr/bin/env bash
#
# Open `hunk` in a dedicated tmux window named "hunk", showing the diff of the
# CURRENT commit (HEAD) against the point where this branch last forked from
# main / production — i.e. the merge-base, NOT what those branches look like now.
#
# Behaviour (matches the requested shortcut):
#   * If a "hunk" window already exists in the current session -> just switch to it.
#   * Otherwise -> open a new window called "hunk" in the current pane's cwd
#     running `hunk diff <branch-point>..HEAD`.
#
# Bound from tmux (see ~/.tmux.conf): prefix + H
#
set -euo pipefail

WIN=hunk

session=$(tmux display-message -p '#{session_name}')

# --- Already open? Just switch to it. -------------------------------------
if tmux list-windows -t "$session" -F '#{window_name}' | grep -qx "$WIN"; then
  tmux select-window -t "$session:$WIN"
  exit 0
fi

cwd=$(tmux display-message -p '#{pane_current_path}')

# --- Work out the branch point (merge-base) -------------------------------
# Consider main / master / production / prod, preferring the remote ref.
# The branch point is the merge-base with the NEWEST commit timestamp, i.e.
# the base we most recently forked from.
find_base() {
  cd "$1" 2>/dev/null || return 1
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1

  local best="" best_ts=-1 name ref mb ts
  for name in main master production prod; do
    for ref in "origin/$name" "$name"; do
      git rev-parse --verify --quiet "$ref" >/dev/null 2>&1 || continue
      mb=$(git merge-base HEAD "$ref" 2>/dev/null) || continue
      [ -n "$mb" ] || continue
      ts=$(git show -s --format=%ct "$mb" 2>/dev/null) || continue
      if [ "$ts" -gt "$best_ts" ]; then
        best_ts=$ts
        best=$mb
      fi
      break   # one ref per branch name is enough (remote preferred)
    done
  done

  [ -n "$best" ] && printf '%s\n' "$best"
}

base=$(find_base "$cwd") || true

if [ -z "${base:-}" ]; then
  tmux display-message "hunk: '$cwd' is not a git repo, or no main/production branch found"
  exit 0
fi

# Open hunk in its own window, in the original cwd. `exec` so the window closes
# cleanly when you quit hunk.
tmux new-window -n "$WIN" -c "$cwd" "exec hunk diff '$base'..HEAD"
