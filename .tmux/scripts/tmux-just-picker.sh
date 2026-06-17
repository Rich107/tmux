#!/usr/bin/env bash
# tmux just-command picker
# Triggered from tmux via `prefix + J`. Finds the nearest justfile (walking up
# from the pane's cwd), lists its recipes (including those from mod/import
# children) in fzf, and on selection opens/reuses a tmux window named after the
# recipe and prepopulates `just <recipe> ` (no Enter) so args can be added.

set -uo pipefail

PANE_PATH="${PWD:-$HOME}"

# Walk upward from PANE_PATH to find the nearest justfile.
find_justfile() {
  local dir="$1"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    for name in justfile Justfile .justfile; do
      if [[ -f "$dir/$name" ]]; then
        printf '%s\n' "$dir/$name"
        return 0
      fi
    done
    dir="$(dirname "$dir")"
  done
  return 1
}

show_error_and_exit() {
  local msg="$1"
  printf '\n  %s\n\n  (closing in 2s...)\n' "$msg" >&2
  sleep 2
  exit 1
}

JUSTFILE="$(find_justfile "$PANE_PATH")" || show_error_and_exit "No justfile found above $PANE_PATH"
JUST_DIR="$(dirname "$JUSTFILE")"

# `just --list --unsorted` prints something like:
#   Available recipes:
#       build       # Build the project
#       test arg    # Run tests
# We strip the header and any blank lines, then format as
#   recipe<TAB>description
RECIPES="$(
  just --justfile "$JUSTFILE" --list --unsorted 2>/dev/null \
    | sed '1d' \
    | awk '
        /^[[:space:]]*$/ { next }
        {
          # Strip leading whitespace
          sub(/^[[:space:]]+/, "", $0)
          # Split on first " # " to separate recipe signature from description
          idx = index($0, " # ")
          if (idx > 0) {
            sig = substr($0, 1, idx - 1)
            desc = substr($0, idx + 3)
          } else {
            sig = $0
            desc = ""
          }
          # Recipe name is the first whitespace-delimited token of the signature
          n = split(sig, parts, /[[:space:]]+/)
          name = parts[1]
          # Trim trailing whitespace from name
          sub(/[[:space:]]+$/, "", name)
          if (name == "") next
          printf "%s\t%s\n", name, desc
        }
      '
)"

if [[ -z "$RECIPES" ]]; then
  show_error_and_exit "No recipes found in $JUSTFILE"
fi

# fzf display: "recipe  —  description". Fuzzy match runs on the recipe column
# only (--nth=1, --delimiter set to the em-dash). Preview shows the recipe body.
SELECTION="$(
  printf '%s\n' "$RECIPES" \
    | awk -F'\t' '{ printf "%s  —  %s\n", $1, $2 }' \
    | fzf \
        --reverse \
        --prompt='just> ' \
        --header='═══ just picker ═══ | Enter: prepopulate command' \
        --header-first \
        --border=rounded \
        --delimiter=' — ' \
        --nth=1 \
        --with-nth=1,2 \
        --preview="just --justfile '$JUSTFILE' --show {1}" \
        --preview-window='right:50%:wrap' \
        --color='bg:#1e1e2e,bg+:#313244,fg:#cdd6f4,fg+:#f5e0dc,hl:#89b4fa,hl+:#89dceb,info:#f9e2af,prompt:#89b4fa,pointer:#f5c2e7,marker:#a6e3a1,spinner:#f5c2e7,header:#f38ba8,border:#89b4fa' \
        --info=inline
)"

if [[ -z "$SELECTION" ]]; then
  exit 0
fi

# Extract the recipe name (everything before the first em-dash separator).
RECIPE="${SELECTION%%  —  *}"
RECIPE="${RECIPE%"${RECIPE##*[![:space:]]}"}"  # rtrim

if [[ -z "$RECIPE" ]]; then
  exit 0
fi

# Sanitize for tmux window name: replace `::` with `-`, drop spaces.
WINDOW_NAME="${RECIPE//:::/-}"
WINDOW_NAME="${WINDOW_NAME//::/-}"
WINDOW_NAME="${WINDOW_NAME// /-}"

CMD="just ${RECIPE} "

# Find an existing window in the current session with this name.
SESSION="$(tmux display-message -p '#S')"
EXISTING_IDX="$(
  tmux list-windows -t "$SESSION" -F '#{window_index} #{window_name} #{pane_current_command}' \
    | awk -v name="$WINDOW_NAME" '$2 == name { print $1 " " $3; exit }'
)"

if [[ -n "$EXISTING_IDX" ]]; then
  IDX="${EXISTING_IDX%% *}"
  CUR_CMD="${EXISTING_IDX##* }"
  case "$CUR_CMD" in
    zsh|bash|sh|fish)
      tmux select-window -t "${SESSION}:${IDX}"
      tmux send-keys -t "${SESSION}:${IDX}" "$CMD"
      exit 0
      ;;
  esac
fi

# Otherwise create a new window in the justfile's directory.
tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -c "$JUST_DIR"
# Brief pause so the shell is ready before we send-keys.
sleep 0.05
tmux send-keys -t "${SESSION}:" "$CMD"
