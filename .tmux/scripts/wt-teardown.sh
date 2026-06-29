#!/usr/bin/env bash
#
# Tear down the CURRENT git worktree + its tmux session, safely.
#
# Counterpart to new-worktree.sh. Triggered from tmux via `prefix + X`
# (runs inside a display-popup whose cwd is the worktree).
#
# Guarantees / behaviour:
#   * Refuses to run on the MAIN worktree.
#   * Refuses (does nothing) if there are genuine uncommitted changes —
#     the shared symlinks created by new-worktree.sh (node_modules, .env*,
#     .venv, …) are NOT counted as changes.
#   * Warns + asks for confirmation if the branch has unpushed/unmerged
#     commits, or if live processes still hold files in the worktree.
#   * HARD-BLOCKS a detached HEAD whose commits are unreachable (data loss).
#   * Removal is symlink-safe: links are unlinked, their targets in the main
#     repo are never followed/deleted.
#   * `git worktree remove` clears the admin dir + lock, so the branch can be
#     checked out again afterwards. The branch is NEVER deleted.
#   * On success: switch the tmux client to the main worktree's session if one
#     exists, then kill this worktree's session; otherwise just detach.
#
set -uo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Abort cleanly: print why, pause so it's readable, then exit non-zero.
die() {
  printf '\n  ✖ %s\n\n' "$1" >&2
  read -rp "  (press enter to close) " _ </dev/tty || true
  exit 1
}

# Canonical absolute path of an existing directory.
abspath() { (cd "$1" 2>/dev/null && pwd -P); }

# The repo's base ref for "unmerged" comparisons: origin/HEAD, else
# origin/main|master, else local main|master, else empty.
base_ref() {
  local d b
  d="$(git -C "$MAIN" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)"
  [[ -n "$d" ]] && { printf '%s' "${d#refs/remotes/}"; return; }
  for b in main master; do
    git -C "$MAIN" show-ref -q --verify "refs/remotes/origin/$b" && { printf 'origin/%s' "$b"; return; }
  done
  for b in main master; do
    git -C "$MAIN" show-ref -q --verify "refs/heads/$b" && { printf '%s' "$b"; return; }
  done
}

# ---------------------------------------------------------------------------
# 1. Resolve context
# ---------------------------------------------------------------------------
START_DIR="${PWD:-$HOME}"
git -C "$START_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "Not inside a git repository: $START_DIR"

MAIN="$(git -C "$START_DIR" worktree list --porcelain | awk '/^worktree /{print $2; exit}')"
MAIN="$(abspath "$MAIN")"
[[ -n "$MAIN" ]] || die "Could not determine the main worktree."

CUR="$(abspath "$(git -C "$START_DIR" rev-parse --show-toplevel)")"
[[ -n "$CUR" ]] || die "Could not determine the current worktree."

# ---------------------------------------------------------------------------
# 2. Guard: never tear down the main worktree
# ---------------------------------------------------------------------------
[[ "$CUR" != "$MAIN" ]] || die "This is the MAIN worktree ($MAIN). Refusing to tear it down."

REPO_NAME="$(basename "$MAIN")"
# Admin dir for this worktree (from its .git file: 'gitdir: <path>').
ADMIN=""
[[ -f "$CUR/.git" ]] && ADMIN="$(sed -n 's/^gitdir: //p' "$CUR/.git")"

# ---------------------------------------------------------------------------
# 3. Dirtiness check — ignoring our shared symlinks (links into $MAIN)
# ---------------------------------------------------------------------------
# 3a. Tracked changes (staged + unstaged) always block.
if [[ -n "$(git -C "$CUR" status --porcelain=v1 --untracked-files=no)" ]]; then
  die "Worktree has uncommitted tracked changes.
      Stash, commit, or discard them first, then re-run:
        git -C \"$CUR\" stash      # or: git commit -am …  /  git checkout -- ."
fi

# 3b. Untracked, non-ignored files block — UNLESS they're shared symlinks
#     that point back into the main repo (those are ours, created on setup).
real_untracked=()
while IFS= read -r p; do
  [[ -z "$p" ]] && continue
  full="$CUR/$p"
  if [[ -L "$full" ]]; then
    tgt="$(readlink "$full")"
    case "$tgt" in "$MAIN"/*) continue ;; esac   # shared link -> ignore
  fi
  real_untracked+=("$p")
done < <(git -C "$CUR" ls-files --others --exclude-standard)

if (( ${#real_untracked[@]} > 0 )); then
  die "Worktree has untracked files:
        $(printf '%s\n        ' "${real_untracked[@]}")
      Commit or remove them first, then re-run."
fi

# ---------------------------------------------------------------------------
# 4. Commit safety — block on unreachable detached HEAD, else collect warnings
# ---------------------------------------------------------------------------
WARN=()
if BRANCH="$(git -C "$CUR" symbolic-ref --quiet --short HEAD 2>/dev/null)"; then
  : # on a normal branch
else
  # Detached HEAD: if no branch contains this commit, removal loses it.
  if [[ -z "$(git -C "$CUR" branch --contains HEAD --format='%(refname:short)' 2>/dev/null)" ]]; then
    die "Detached HEAD with commits not reachable from any branch — removing
      this worktree would lose them. Create a branch first:
        git -C \"$CUR\" switch -c <name>"
  fi
  BRANCH="(detached)"
fi

if [[ "$BRANCH" != "(detached)" ]]; then
  # Unpushed vs upstream.
  if UP="$(git -C "$CUR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null)"; then
    ahead="$(git -C "$CUR" rev-list --count "${UP}..HEAD" 2>/dev/null || echo 0)"
    (( ahead > 0 )) && WARN+=("$ahead commit(s) not pushed to $UP")
  else
    WARN+=("branch '$BRANCH' has no upstream (never pushed)")
  fi
  # Unmerged vs base.
  BASE="$(base_ref)"
  if [[ -n "$BASE" ]]; then
    behind="$(git -C "$CUR" rev-list --count "${BASE}..HEAD" 2>/dev/null || echo 0)"
    (( behind > 0 )) && WARN+=("$behind commit(s) not merged into $BASE")
  fi
fi

# ---------------------------------------------------------------------------
# 5. Live processes still holding the worktree
# ---------------------------------------------------------------------------
if command -v lsof >/dev/null 2>&1; then
  # Exclude shells/tmux and this check's own pipeline tools (which run with
  # their cwd inside the worktree and would otherwise self-report).
  procs="$(lsof -nPw +D "$CUR" 2>/dev/null \
    | awk 'NR>1 { c=$1
        if (c=="zsh"||c=="-zsh"||c=="bash"||c=="-bash"||c=="sh"||c=="tmux" \
           ||c=="lsof"||c=="awk"||c=="sort"||c=="sed"||c=="grep"||c=="find") next
        print c" (pid "$2")" }' \
    | sort -u)"
  if [[ -n "$procs" ]]; then
    while IFS= read -r line; do WARN+=("open in worktree: $line"); done <<< "$procs"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Confirmation
# ---------------------------------------------------------------------------
SESSION="$(printf '%s' "$BRANCH" | tr ' /.:' '----')"
printf '\n  Tear down worktree\n'
printf '    repo    : %s\n' "$REPO_NAME"
printf '    branch  : %s  (kept — only the worktree is removed)\n' "$BRANCH"
printf '    path    : %s\n' "$CUR"
[[ -n "$ADMIN" && -f "$ADMIN/locked" ]] && printf '    locked  : %s\n' "$(cat "$ADMIN/locked")"
if (( ${#WARN[@]} > 0 )); then
  printf '\n  ⚠ warnings:\n'
  printf '    - %s\n' "${WARN[@]}"
fi
printf '\n  Type "y" to tear down (anything else aborts): '
read -r ans </dev/tty || ans=""
case "$ans" in
  y|Y|yes|YES) ;;
  *) die "Aborted — nothing was changed." ;;
esac

# ---------------------------------------------------------------------------
# 7. Teardown
# ---------------------------------------------------------------------------
cd "$MAIN" || die "Could not cd to main worktree $MAIN"

# Pre-remove first-level symlinks (belt & suspenders for the rm fallback —
# only unlinks the links, never follows them into $MAIN).
find "$CUR" -maxdepth 1 -type l -delete 2>/dev/null || true

# Remove the worktree (clears working dir + admin dir + the checkout lock).
if ! git -C "$MAIN" worktree remove --force "$CUR" 2>/dev/null; then
  if [[ -n "$ADMIN" && -f "$ADMIN/locked" ]]; then
    # Locked: override the lock.
    git -C "$MAIN" worktree remove --force --force "$CUR" 2>/dev/null || {
      rm -rf "$CUR"; [[ -n "$ADMIN" ]] && rm -rf "$ADMIN"; git -C "$MAIN" worktree prune
    }
  else
    rm -rf "$CUR"
    git -C "$MAIN" worktree prune
  fi
fi

[[ -e "$CUR" ]] && die "Removal incomplete — $CUR still exists. Check manually."

printf '\n  ✔ Removed worktree. Branch "%s" is free to check out again.\n' "$BRANCH"

# ---------------------------------------------------------------------------
# 8. tmux: switch to the main worktree's session, then kill this one
# ---------------------------------------------------------------------------
if [[ -n "${TMUX:-}" ]]; then
  CURRENT_SESSION="$(tmux display-message -p '#S' 2>/dev/null)"

  # Find a session whose active pane cwd is inside the main worktree.
  TARGET=""
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    sp="$(tmux display-message -p -t "$s" '#{pane_current_path}' 2>/dev/null)"
    sp="$(abspath "$sp")"
    if [[ "$sp" == "$MAIN" || "$sp" == "$MAIN"/* ]]; then TARGET="$s"; break; fi
  done < <(tmux list-sessions -F '#{session_name}' 2>/dev/null)

  read -rp "  (press enter to close) " _ </dev/tty || true

  if [[ -n "$TARGET" && "$TARGET" != "$CURRENT_SESSION" ]]; then
    tmux switch-client -t "$TARGET" 2>/dev/null || true
    tmux kill-session -t "$CURRENT_SESSION" 2>/dev/null || true
  elif [[ "$TARGET" == "$CURRENT_SESSION" ]]; then
    # We're already in the main-repo session; don't kill it. The launching
    # pane's cwd may now be stale — note it rather than send-keys into nvim.
    printf '  (your current session is the main repo — cd back to %s if needed)\n' "$MAIN"
  else
    # No main-repo session — just detach by killing this one.
    tmux kill-session -t "$CURRENT_SESSION" 2>/dev/null || true
  fi
fi
