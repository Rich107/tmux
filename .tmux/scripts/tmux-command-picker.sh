#!/usr/bin/env bash
#
# tmux command picker — triggered from tmux via `prefix + ?`.
#
# fzf fuzzy-finder over every tmux command (`tmux list-commands`). On selection
# the chosen command is dropped into an editable prompt (prefilled with the
# command name, its full usage shown above) so arguments can be completed, then
# run in the context of the pane / window / session that was active when the
# picker was opened — with that pane's cwd as the working directory for any new
# windows or panes.
#
# Why this honours "the pane and cwd I was in":
#   * Context: `display-popup` is an overlay; it does NOT change the active pane,
#     so an un-targeted tmux command resolves to the pane the picker was opened
#     from (the same client/session/window/pane).
#   * cwd: `new-window` / `split-window` / `new-session` with no `-c` inherit the
#     calling process's cwd. We `cd` into the original pane's path below, so new
#     windows/panes open "where I was".
#
# Invoked from tmux.conf as:
#   bind ? display-popup -E -w 80% -h 70% -d "#{pane_current_path}" \
#     -T ' tmux-command-picker ' -S 'fg=#89b4fa' -b rounded \
#     "bash ~/.tmux/scripts/tmux-command-picker.sh '#{pane_id}' '#{pane_current_path}'"

set -uo pipefail

PANE_ID="${1:-}"
PANE_PATH="${2:-$PWD}"

# Anchor the working directory to the original pane's cwd so path-aware commands
# (new-window, split-window, new-session …) open there when no -c is given.
cd "$PANE_PATH" 2>/dev/null || cd "$HOME" || exit 1

# Catppuccin mocha palette, matching the other pickers in this config.
FZF_COLORS='bg:#1e1e2e,bg+:#313244,fg:#cdd6f4,fg+:#f5e0dc,hl:#89b4fa,hl+:#89dceb,info:#f9e2af,prompt:#89b4fa,pointer:#f5c2e7,marker:#a6e3a1,spinner:#f5c2e7,header:#f38ba8,border:#89b4fa'

# `tmux list-commands` prints one line per command:
#   name (alias) [-flags] args...
# Fuzzy-match on the whole line; the preview pane shows the highlighted entry's
# full usage, wrapped, in case the list row is truncated.
SELECTION="$(
  tmux list-commands \
    | fzf \
        --reverse \
        --prompt='tmux> ' \
        --header='═══ tmux command picker ═══ | Enter: edit args & run' \
        --header-first \
        --border=rounded \
        --preview='printf "%s\n" {}' \
        --preview-window='down:5:wrap' \
        --color="$FZF_COLORS" \
        --info=inline
)"

[[ -z "$SELECTION" ]] && exit 0

# The canonical command name is the first whitespace-delimited token.
CMD_NAME="${SELECTION%% *}"

# Show the full usage so the user knows the valid flags/args, then offer an
# editable line prefilled with the command name + a trailing space.
printf '\n  \033[1;34m%s\033[0m\n\n' "$SELECTION"
printf '  Runs against pane \033[1;36m%s\033[0m  (cwd: \033[1;36m%s\033[0m)\n' "$PANE_ID" "$PANE_PATH"
printf '  Edit the command, then Enter to run — Ctrl-C to cancel.\n\n'

# readline editing; -i prefills so arg-less commands are a single Enter away.
read -r -e -p '  tmux ' -i "$CMD_NAME " FULL_CMD || exit 0

# Trim leading/trailing whitespace.
FULL_CMD="${FULL_CMD#"${FULL_CMD%%[![:space:]]*}"}"
FULL_CMD="${FULL_CMD%"${FULL_CMD##*[![:space:]]}"}"
[[ -z "$FULL_CMD" ]] && exit 0

# Run it. `eval` so the user's quoting (e.g. for commands that take a nested
# command/template like bind-key, if-shell, display-popup) is honoured exactly
# as a shell would parse it. The active pane is still the original one and the
# cwd was set above, giving the requested pane + cwd context.
OUTPUT="$(eval "tmux $FULL_CMD" 2>&1)"
STATUS=$?

# Commands that print (list-keys, show-options, display -p, or an error) should
# stay visible; action commands (split-window, new-window …) produce no output,
# so we exit immediately and the popup closes to reveal the result.
if [[ -n "$OUTPUT" ]]; then
  if command -v less >/dev/null 2>&1; then
    printf '%s\n' "$OUTPUT" | less -R
  else
    printf '\n%s\n\n  ── press Enter to close ──' "$OUTPUT"
    read -r _
  fi
fi

exit "$STATUS"
