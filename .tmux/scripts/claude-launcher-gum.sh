#!/usr/bin/env bash
#
# EXPERIMENTAL: gum-based multi-select launcher for Claude Code (the `C` function).
#
# Parallel to claude-launcher.sh (the `c` function) — does NOT replace it.
# Instead of one fzf single-select between MCP profiles, this presents a
# multi-select checklist where each line is an independent toggle:
#
#   [ ] MCPs                 -> load the stash (~/.claude/mcp-stash.json)
#                               unchecked = clean session ({"mcpServers":{}})
#   [ ] Dangerous perms      -> --dangerously-skip-permissions
#   [ ] Continue last        -> --continue
#   [ ] Fast mode            -> --fast
#
# Both MCP modes use --strict-mcp-config so the picker fully determines which
# servers the session sees (project .mcp.json and ~/.claude.json are ignored),
# matching c()'s behaviour. The stash contains API keys, so it is written to a
# 0600 temp file and never placed on the command line.
#
# Any extra args are forwarded to claude, e.g. `C "fix the failing test"`.

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

# No interactive terminal (piped / scripted) or no gum -> skip the picker.
if [[ ! -t 0 || ! -t 1 ]] || ! command -v gum >/dev/null 2>&1; then
  exec "$CLAUDE_BIN" "$@"
fi

# Label the MCP toggle with whatever is actually stashed.
mcp_label="MCPs"
if [[ -r "$STASH" ]] && command -v node >/dev/null 2>&1; then
  servers="$(node -e 'process.stdout.write(Object.keys(require(process.argv[1])).join(", "))' "$STASH" 2>/dev/null || true)"
  [[ -n "$servers" ]] && mcp_label="MCPs — $servers"
fi

# Multi-select checklist. Space toggles, Enter confirms, Esc/Ctrl-C cancels.
# gum exits non-zero on cancel; trap that to abort cleanly (launch nothing).
selected="$(
  gum choose --no-limit \
    --height=10 \
    --header='Toggle options · Space=select · Enter=launch · Esc=cancel' \
    --selected="$mcp_label" \
    "$mcp_label" \
    "Dangerous perms (skip permission prompts)" \
    "Continue last session" \
    "Fast mode"
)" || exit 0

args=()

# MCP profile: selected = load stash, unselected = clean session. Both strict.
if grep -q "^${mcp_label}$" <<<"$selected"; then
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
  args+=(--strict-mcp-config --mcp-config "$tmp")
else
  args+=(--strict-mcp-config --mcp-config '{"mcpServers":{}}')
fi

grep -q '^Dangerous perms' <<<"$selected" && args+=(--dangerously-skip-permissions)
grep -q '^Continue last'   <<<"$selected" && args+=(--continue)
grep -q '^Fast mode'       <<<"$selected" && args+=(--fast)

# If a temp MCP file was created, run without exec so the EXIT trap can clean
# it up after claude returns. Clean sessions can exec straight through.
if [[ -n "${tmp:-}" ]]; then
  "$CLAUDE_BIN" "${args[@]}" "$@"
else
  exec "$CLAUDE_BIN" "${args[@]}" "$@"
fi
