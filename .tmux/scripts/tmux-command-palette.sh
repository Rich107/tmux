#!/usr/bin/env bash
#
# tmux command palette — triggered from tmux via `prefix + ?`.
#
# An fzf "what can I do, and what key runs it" palette. It lists tmux key
# bindings (the things you actually trigger: the prefix table + the useful root
# bindings) showing the KEY to press alongside a human description — the binding
# note where tmux has one (e.g. "Move the current window"), otherwise a
# condensed view of the bound command. Fuzzy-search e.g. "split" to find the key.
#
# Selecting an entry runs that binding's command, faithfully, in the context of
# the pane that was active when the palette opened:
#   * The command is replayed via `tmux source-file`, so tmux's own parser
#     handles it (no shell `eval`, which would execute the $(...)/backticks that
#     live inside complex binds). It behaves exactly like pressing the key.
#   * Execution is DEFERRED until this popup has closed. A popup cannot open
#     another popup, so binds that are themselves display-popups (claude-jump,
#     session-manager, just-picker, …) would silently fail if run from inside
#     here; and binds like `new-window \; send-keys` need the real pane/client
#     context, not the popup overlay. So we background a tiny delayed runner
#     that fires once this script exits and tmux tears the popup down.
#
# Portable to macOS' system bash 3.2 (no associative arrays — the note/command
# join is done in awk). Requires: tmux, fzf, awk.
#
# Invoked from tmux.conf as:
#   bind ? display-popup -E -w 80% -h 80% -d "#{pane_current_path}" \
#     -T ' tmux-command-palette ' -S 'fg=#cdd6f4,bg=#1e1e2e' -s 'fg=#89b4fa' -b rounded \
#     "bash ~/.tmux/scripts/tmux-command-palette.sh"

set -uo pipefail

# Key tables to include, in display order. The prefix table is the main event;
# root holds no-prefix shortcuts (vim-navigator C-h/j/k/l, floax C-M-*, …).
# Mouse/Wheel/Click root bindings are filtered out (not palette material).
TABLES="prefix root"

PREFIX_KEY="$(tmux show-options -gv prefix 2>/dev/null)"   # e.g. C-b
PREFIX_KEY="${PREFIX_KEY:-C-b}"

# Catppuccin mocha palette, matching the other pickers in this config.
FZF_COLORS='bg:#1e1e2e,bg+:#313244,fg:#cdd6f4,fg+:#f5e0dc,hl:#89b4fa,hl+:#89dceb,info:#f9e2af,prompt:#89b4fa,pointer:#f5c2e7,marker:#a6e3a1,spinner:#f5c2e7,header:#f38ba8,border:#89b4fa'

# Build palette rows. Each row is TAB-separated:
#   <display>\t<table>\t<command>
# <display> = "  <key-combo>  │ <description>" is the only column fzf shows and
# fuzzy-matches; <table> and <command> are hidden, used for preview + execution.
build_rows() {
  local table
  for table in $TABLES; do
    # Two inputs to awk: the notes for this table, then the bindings.
    #   notes: `<key>   <human note>`     (keys here are UNescaped: ! # $ ')
    #   binds: `bind-key [-r] -T <table> <key> <command...>`
    awk -v table="$table" -v prefixkey="$PREFIX_KEY" '
      function condense(s) { gsub(/[ \t]+/, " ", s); gsub(/^ | $/, "", s); return s }
      function unesc(k)    { gsub(/\\/, "", k); return k }

      # First file: notes. key = first token, note = the rest.
      NR == FNR {
        key = $1
        sub(/^[^ \t]+[ \t]+/, "", $0)
        note[key] = $0
        next
      }

      # Second file: bindings. Strip the "bind-key [-r] -T <table> " prefix,
      # then split the leading key off, preserving the command spacing.
      {
        line = $0
        sub(/^bind-key[ \t]+/, "", line)
        sub(/^-r[ \t]+/, "", line)
        sub(/^-T[ \t]+[^ \t]+[ \t]+/, "", line)
        key = line; sub(/[ \t].*/, "", key)
        cmd = line; sub(/^[^ \t]+[ \t]+/, "", cmd)
        if (key == "") next

        kk = unesc(key)

        # Drop mouse-driven root bindings.
        if (table == "root" && kk ~ /Mouse|Wheel|Click/) next

        combo = (table == "prefix") ? (prefixkey " " kk) : kk
        desc  = (kk in note) ? note[kk] : condense(cmd)
        # Hardcoded friendly labels for custom binds that have no note and an
        # unwieldy inline command. Add more lines here as needed.
        if (cmd ~ /tmux-session-manager/) desc = "Session manager"
        # Keep the list tidy: long un-noted commands are truncated for display
        # (the full command still shows in the preview pane and is what runs).
        if (length(desc) > 90) desc = substr(desc, 1, 89) "…"

        printf "  %-13s │ %s\t%s\t%s\n", combo, desc, table, cmd
      }
    ' <(echo "__sentinel__ ignored"; tmux list-keys -N -T "$table" 2>/dev/null) \
      <(tmux list-keys    -T "$table" 2>/dev/null) \
      | LC_ALL=C sort -f
  done
}

SELECTION="$(
  build_rows \
    | fzf \
        --reverse \
        --delimiter='\t' \
        --with-nth=1 \
        --prompt='action> ' \
        --header="═══ tmux command palette ═══ | prefix = ${PREFIX_KEY} | Enter: run in current pane" \
        --header-first \
        --border=rounded \
        --preview='printf "Runs (%s table):\n\n%s\n" {2} {3}' \
        --preview-window='down:6:wrap' \
        --color="$FZF_COLORS" \
        --info=inline
)"

[[ -z "$SELECTION" ]] && exit 0

# Hidden columns: 2 = key table, 3 = the exact bound command.
TABLE="$(printf '%s\n' "$SELECTION" | awk -F'\t' '{print $2}')"
CMD="$(printf '%s\n' "$SELECTION" | awk -F'\t' '{print $3}')"
[[ -z "$CMD" ]] && exit 0

# Write the command to a temp file for tmux's own parser to source.
TMPCMD="$(mktemp -t tmux-palette.XXXXXX)"
printf '%s\n' "$CMD" > "$TMPCMD"

# Defer: background a runner that waits a beat for THIS popup to close, then
# replays the command in the real client/pane context — exactly like pressing
# the key. This is what lets display-popup binds and new-window/send-keys work
# (see the header comment). nohup + redirect keeps it alive past popup teardown.
nohup bash -c "sleep 0.15; tmux source-file '$TMPCMD'; rm -f '$TMPCMD'" \
  >/dev/null 2>&1 &

exit 0
