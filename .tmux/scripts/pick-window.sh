#!/usr/bin/env bash
#
# fzf picker for windows in the CURRENT tmux session.
# Selecting a window switches to it. Esc / Ctrl-c cancels.
#
set -euo pipefail

# Only windows belonging to the session this popup was launched from.
session="$(tmux display-message -p '#{session_name}')"

# Field 1 = window_id (hidden, used for the action/preview), the rest is shown.
target="$(
  tmux list-windows -t "$session" \
    -F '#{window_id}	#{window_index}: #{window_name}#{?window_active, *,}#{?window_zoomed_flag, [Z],} (#{window_panes}p)' \
  | fzf \
      --delimiter='\t' \
      --with-nth=2.. \
      --no-sort \
      --layout=reverse \
      --border=rounded \
      --prompt='window > ' \
      --header='enter: switch   esc: cancel' \
      --preview='tmux capture-pane -ep -t {1}' \
      --preview-window='right,55%' \
  | cut -f1
)"

if [[ -n "${target:-}" ]]; then
  tmux select-window -t "$target"
fi
