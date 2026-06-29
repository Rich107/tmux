#!/usr/bin/env bash
#
# Create a git worktree for a new branch and open it in a dedicated tmux
# session with a predefined layout.
#
# Triggered from tmux via `prefix + W` (runs inside a display-popup).
#
# Flow:
#   1. An nvim popup asks for the branch name (same convention as
#      rename-window.sh):
#        :wq  -> use the buffer contents as the branch name
#        :q   -> abort, do nothing
#   2. `git worktree add` creates the worktree at
#        <repo-parent>/<repo>-worktrees/<branch>
#      with a new branch based on the repo's default branch (origin/main
#      or origin/master).
#   3. Shared files (.env*, node_modules, .venv/venv — or whatever a
#      per-repo `.worktree-share` lists) are symlinked in from the main repo
#      so they aren't duplicated.
#   4. A tmux session named after the branch is built with three windows:
#        nvim   - editor, running nvim
#        claude - running claude
#        test   - two side-by-side shells for a test runner
#      and the client is switched to it.
#
# Port clashes between the main repo and worktrees are intentionally left to
# the app to handle.
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Print a message inside the popup and pause so it's readable before the
# popup (launched with -E) closes on exit.
die() {
  printf '\n  %s\n\n  (closing in 3s...)\n' "$1" >&2
  sleep 3
  exit 1
}

# The repo's default branch: origin/HEAD if known, else origin/main|master,
# else local main|master, else current HEAD.
default_branch() {
  local d
  d="$(git -C "$MAIN_REPO" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -n "$d" ]]; then
    printf '%s' "${d#refs/remotes/origin/}"
    return
  fi
  local b
  for b in main master; do
    if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/remotes/origin/$b"; then
      printf '%s' "$b"; return
    fi
  done
  for b in main master; do
    if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$b"; then
      printf '%s' "$b"; return
    fi
  done
  git -C "$MAIN_REPO" rev-parse --abbrev-ref HEAD
}

# Symlink shared files from the main repo into the worktree without copying.
# Entries come from `.worktree-share` (one glob per line, # comments allowed)
# if present, otherwise a built-in default list.
share_into_worktree() {
  local entries=()
  if [[ -f "$MAIN_REPO/.worktree-share" ]]; then
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%%#*}"                       # strip trailing comment
      line="${line#"${line%%[![:space:]]*}"}"  # ltrim
      line="${line%"${line##*[![:space:]]}"}"  # rtrim
      [[ -n "$line" ]] && entries+=("$line")
    done < "$MAIN_REPO/.worktree-share"
  else
    entries=(".env" ".env.local" ".env.*" "node_modules" ".venv" "venv")
  fi

  shopt -s nullglob dotglob
  local pat src rel dst
  for pat in "${entries[@]}"; do
    for src in "$MAIN_REPO"/$pat; do
      [[ -e "$src" ]] || continue
      rel="${src#"$MAIN_REPO"/}"
      dst="$WT/$rel"
      # Don't clobber anything git already created in the worktree.
      [[ -e "$dst" || -L "$dst" ]] && continue
      mkdir -p "$(dirname "$dst")"
      ln -s "$src" "$dst"
      printf '  linked %s\n' "$rel"
    done
  done
  shopt -u nullglob dotglob
}

# Wait until a pane's shell prompt has rendered before send-keys, so the first
# characters aren't dropped while zsh is still sourcing .zshrc/p10k. We poll the
# pane contents and return as soon as something (the prompt) is drawn, capped by
# a timeout so we never hang.
wait_for_prompt() {
  local target="$1" i out
  for ((i = 0; i < 200; i++)); do  # up to ~10s
    out="$(tmux capture-pane -p -t "$target" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -n1)"
    [[ -n "$out" ]] && return 0
    sleep 0.05
  done
  return 0
}

# ---------------------------------------------------------------------------
# >>> LAYOUT TEMPLATE — edit here to change the windows/panes/commands. <<<
# This is the hand-rolled equivalent of a tmuxp/smug template. If layouts
# ever multiply, this is the single function to port to such a tool.
# ---------------------------------------------------------------------------
build_worktree_session() {
  local s="$SESSION" wt="$WT"

  # Window 1: editor
  tmux new-session -d -s "$s" -c "$wt" -n nvim
  wait_for_prompt "$s:nvim"
  tmux send-keys -t "$s:nvim" 'nvim' Enter

  # Window 2: claude
  tmux new-window -t "$s" -n claude -c "$wt"
  wait_for_prompt "$s:claude"
  tmux send-keys -t "$s:claude" 'claude' Enter

  # Window 3: test runner — two side-by-side shells (no command auto-run,
  # since the test command differs per project).
  tmux new-window -t "$s" -n test -c "$wt"
  tmux split-window -h -t "$s:test" -c "$wt"
  tmux select-layout -t "$s:test" even-horizontal
  tmux select-pane -t "$s:test".1

  # Land on the editor window.
  tmux select-window -t "$s:nvim"
}

# ---------------------------------------------------------------------------
# 1. Locate the main repo we were launched from
# ---------------------------------------------------------------------------
START_DIR="$(tmux display-message -p '#{pane_current_path}' 2>/dev/null || printf '%s' "${PWD:-$HOME}")"

if ! git -C "$START_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "No git repo detected ($START_DIR)"
fi

# The main working tree is always the first entry of `git worktree list`,
# so this works whether we launched from the main repo or an existing worktree.
MAIN_REPO="$(git -C "$START_DIR" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
[[ -n "$MAIN_REPO" ]] || die "Could not determine main worktree."
REPO_NAME="$(basename "$MAIN_REPO")"
WT_ROOT="$(dirname "$MAIN_REPO")/${REPO_NAME}-worktrees"

# ---------------------------------------------------------------------------
# 2. Ask for the branch name via an nvim popup (:wq use / :q abort)
# ---------------------------------------------------------------------------
tmpdir="$(mktemp -d)"
namefile="$tmpdir/branch"
flagfile="$tmpdir/saved"
trap 'rm -rf "$tmpdir"' EXIT
: > "$namefile"

# BufWritePost drops a flag file so we can distinguish :wq (wrote) from :q.
# Start in insert mode since the buffer is empty.
nvim \
  -c "autocmd BufWritePost <buffer> call writefile([], '$flagfile')" \
  -c 'startinsert' \
  "$namefile"

[[ -f "$flagfile" ]] || exit 0  # :q without writing -> abort silently

BRANCH="$(head -n1 "$namefile")"
# Trim whitespace, collapse internal whitespace to hyphens.
BRANCH="$(printf '%s' "$BRANCH" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/-/g')"
[[ -n "$BRANCH" ]] || exit 0  # empty -> abort

# tmux session names can't contain . or : ; also flatten / and spaces.
SESSION="$(printf '%s' "$BRANCH" | tr ' /.:' '----')"
WT="$WT_ROOT/$(printf '%s' "$BRANCH" | tr ' :' '--')"

# ---------------------------------------------------------------------------
# 3. If a session for this branch already exists, just switch to it.
# ---------------------------------------------------------------------------
if tmux has-session -t "=$SESSION" 2>/dev/null; then
  tmux switch-client -t "$SESSION"
  exit 0
fi

# ---------------------------------------------------------------------------
# 4. Create the worktree (reuse if the dir already exists)
# ---------------------------------------------------------------------------
mkdir -p "$WT_ROOT"

if [[ -d "$WT" ]]; then
  printf '  reusing existing worktree dir %s\n' "$WT"
else
  if git -C "$MAIN_REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
    # Branch already exists: attach a worktree to it.
    git -C "$MAIN_REPO" worktree add "$WT" "$BRANCH" \
      || die "git worktree add failed for existing branch '$BRANCH'."
  else
    BASE="$(default_branch)"
    BASE_REF="$BASE"
    git -C "$MAIN_REPO" show-ref --verify --quiet "refs/remotes/origin/$BASE" \
      && BASE_REF="origin/$BASE"
    git -C "$MAIN_REPO" worktree add -b "$BRANCH" "$WT" "$BASE_REF" \
      || die "git worktree add failed (branch '$BRANCH' off '$BASE_REF')."
  fi
fi

# ---------------------------------------------------------------------------
# 5. Symlink shared files, then build and switch to the session.
# ---------------------------------------------------------------------------
share_into_worktree
build_worktree_session
tmux switch-client -t "$SESSION"
