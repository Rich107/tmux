#!/usr/bin/env bash
# pr-pick — fzf picker for open PRs of the repo tied to the current directory.
#
# The list is ordered: PR(s) for the current branch first, then everything
# else newest-first by creation date. The list shows only PR titles; the fzf
# preview shows the title + description.
#
#   Enter      open the PR in your browser
#   ctrl-o     check out the PR branch locally (then exit)
#   ctrl-y     copy the PR url to the clipboard
#   ctrl-r     reload the list
#   esc        quit
#
# Internal subcommands (used by fzf binds): --list, --preview <num>

set -euo pipefail

die() { echo "$1" >&2; read -rp "Press enter to close…" _ || true; exit 1; }

# --- subcommand: print the picker list -------------------------------------
# Output is tab-delimited: "<number>\t<label>". fzf shows only the label.
if [[ "${1:-}" == "--list" ]]; then
  branch="$(git branch --show-current 2>/dev/null || true)"
  gh pr list --limit 100 --json number,title,headRefName,isDraft,createdAt,author \
    | jq -r --arg b "$branch" '
        def pad($w): . + (" " * ([$w - length, 0] | max));
        sort_by(.createdAt) | reverse
        | (map(select(.headRefName == $b)) + map(select(.headRefName != $b)))
        | .[]
        | "\(.number)\t"
          + (.author.login | pad(18)) + "  "
          + (if .isDraft then "🚧 " else "" end)
          + .title
          + (if .headRefName == $b and $b != "" then "  ◀ current branch" else "" end)
      '
  exit 0
fi

# --- subcommand: render the preview for a PR number -------------------------
if [[ "${1:-}" == "--preview" ]]; then
  num="${2:?missing pr number}"
  gh pr view "$num" --json title,body,headRefName,author,isDraft \
    --template '# {{.title}}
{{if .isDraft}}🚧 draft · {{end}}@{{.author.login}} · {{.headRefName}}

{{if .body}}{{.body}}{{else}}_(no description)_{{end}}
' | bat --language markdown --color always --style plain --paging never 2>/dev/null \
    || gh pr view "$num"
  exit 0
fi

# --- main: preflight --------------------------------------------------------
git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || die "Not inside a git repository."

repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -n "$repo" ]] || die "Couldn't determine a GitHub repo for this directory."

# --- main: the picker -------------------------------------------------------
selection="$(
  pr-pick --list \
  | fzf --ansi \
        --delimiter=$'\t' \
        --with-nth=2.. \
        --header="  $repo — enter: open · ctrl-o: checkout · ctrl-y: copy url · ctrl-r: reload · esc: quit" \
        --header-first \
        --prompt="PR ❯ " \
        --pointer="▶" \
        --preview="pr-pick --preview {1}" \
        --preview-window="up,55%,wrap,border-bottom" \
        --bind="ctrl-r:reload(pr-pick --list)" \
        --bind="ctrl-y:execute-silent(gh pr view {1} --json url -q .url | tr -d '\n' | pbcopy)" \
        --expect=ctrl-o
)" || exit 0

[[ -z "$selection" ]] && exit 0

# fzf --expect puts the pressed key on line 1, the selected row on line 2.
key="$(head -1 <<<"$selection")"
row="$(sed -n '2p' <<<"$selection")"
[[ -z "$row" ]] && exit 0
num="${row%%$'\t'*}"   # number is field 1

case "$key" in
  ctrl-o)
    echo "Checking out PR #$num…"
    gh pr checkout "$num"
    read -rp "Done. Press enter to close…" _ || true
    ;;
  *)
    gh pr view "$num" --web
    ;;
esac
