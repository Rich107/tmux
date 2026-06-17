#!/usr/bin/env bash
#
# Rename the current tmux window via an nvim popup.
#
#   :wq  -> writes the buffer; window is renamed to its (trimmed) contents
#   :q   -> no write; window keeps its current name
#   Esc  -> just returns nvim to normal mode (popup stays open)
#
# On save the new name is trimmed of leading/trailing whitespace and any
# remaining spaces are converted to '-'.
#
set -euo pipefail

# The window this popup was launched from is the session's active window.
current="$(tmux display-message -p '#{window_name}')"

tmpdir="$(mktemp -d)"
namefile="$tmpdir/name"
flagfile="$tmpdir/saved"
trap 'rm -rf "$tmpdir"' EXIT

printf '%s' "$current" > "$namefile"

# BufWritePost drops a flag file so we can tell :wq (wrote) from :q (didn't).
# Cursor is placed at end of the line, ready to edit, in normal mode.
nvim \
  -c "autocmd BufWritePost <buffer> call writefile([], '$flagfile')" \
  -c 'normal! $' \
  "$namefile"

# Only rename if the buffer was actually written (i.e. :w / :wq).
if [[ -f "$flagfile" ]]; then
  newname="$(head -n1 "$namefile")"
  # Trim leading/trailing whitespace, then collapse spaces to hyphens.
  newname="$(printf '%s' "$newname" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/-/g')"
  if [[ -n "$newname" ]]; then
    tmux rename-window -- "$newname"
  fi
fi
