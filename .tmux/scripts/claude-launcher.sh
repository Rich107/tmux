#!/usr/bin/env bash
#
# Launch Claude Code after picking an MCP profile via fzf.
#
# Two profiles, both passed with --strict-mcp-config so the picker fully
# determines which MCP servers the session sees (project .mcp.json and any
# servers persisted in ~/.claude.json are ignored):
#
#   No MCPs    -> --mcp-config '{"mcpServers":{}}'   (guaranteed clean session)
#   All MCPs   -> the servers stashed in ~/.claude/mcp-stash.json
#                 (grafana, postgres-prod, datadog, ...) wrapped as
#                 { "mcpServers": { ... } } and written to a 0600 temp file
#                 (it contains API keys, so it never goes on the command line).
#
# Any extra args are forwarded to claude, e.g. `c "fix the failing test"`.
#
# Usable both as the `c` shell function and standalone (e.g. from a tmux popup).

set -euo pipefail

STASH="$HOME/.claude/mcp-stash.json"
CLAUDE_BIN="$(command -v claude || true)"

if [[ -z "$CLAUDE_BIN" ]]; then
  echo "claude not found on PATH" >&2
  exit 127
fi

# Subcommands / flags that should never trigger the picker — just pass through.
case "${1:-}" in
  mcp|config|update|doctor|install|migrate-installer|setup-token|\
  -v|--version|-h|--help|--mcp-config|--settings)
    exec "$CLAUDE_BIN" "$@"
    ;;
esac

# No interactive terminal (piped / scripted) or no fzf -> skip the picker.
if [[ ! -t 0 || ! -t 1 ]] || ! command -v fzf >/dev/null 2>&1; then
  exec "$CLAUDE_BIN" "$@"
fi

# Build the menu. Second entry's label lists whatever is actually stashed.
stash_label="All MCPs"
if [[ -r "$STASH" ]] && command -v node >/dev/null 2>&1; then
  servers="$(node -e 'process.stdout.write(Object.keys(require(process.argv[1])).join(", "))' "$STASH" 2>/dev/null || true)"
  [[ -n "$servers" ]] && stash_label="All MCPs — $servers"
fi

choice="$(
  printf '%s\t%s\n' \
    none  "No MCPs (clean session)" \
    stash "$stash_label" \
  | fzf --with-nth=2 --delimiter='\t' \
        --height='~40%' --reverse --no-multi \
        --prompt='claude ▸ ' \
        --header='Pick an MCP profile · Enter to launch · Esc to cancel' \
  | cut -f1
)" || exit 0   # Esc / no selection -> abort, launch nothing

case "$choice" in
  none)
    exec "$CLAUDE_BIN" --strict-mcp-config --mcp-config '{"mcpServers":{}}' "$@"
    ;;
  stash)
    if [[ ! -r "$STASH" ]]; then
      echo "stash not found: $STASH" >&2
      exit 1
    fi
    # BSD mktemp needs the X's at the end of the template; add .json after.
    tmp="$(mktemp "${TMPDIR:-/tmp}/claude-mcp.XXXXXX")"
    mv "$tmp" "$tmp.json"
    tmp="$tmp.json"
    chmod 600 "$tmp"
    trap 'rm -f "$tmp"' EXIT
    # Wrap the directly-keyed stash in the { mcpServers: ... } shape claude expects.
    node -e 'const fs=require("fs");fs.writeFileSync(process.argv[2],JSON.stringify({mcpServers:require(process.argv[1])}))' \
      "$STASH" "$tmp"
    "$CLAUDE_BIN" --strict-mcp-config --mcp-config "$tmp" "$@"
    ;;
  *)
    exit 0
    ;;
esac
