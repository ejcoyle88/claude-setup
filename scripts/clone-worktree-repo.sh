#!/usr/bin/env bash
# clone-worktree-repo.sh — clone a repo into a worktree-friendly layout.
#
# Layout produced (bare repo + sibling worktrees; no privileged "main checkout"):
#
#   <path>/
#   ├── .bare/           the bare repository (all git objects live here)
#   ├── .git             a file: "gitdir: ./.bare"  → git commands work from <path>
#   └── <default-branch>/  a worktree for the default branch (e.g. main/)
#
# Add more later:   git -C <path> worktree add <dir> <branch>
#                   git -C <path> worktree add -b feat/x feat-x
# List / remove:    git -C <path> worktree list  |  git -C <path> worktree remove <dir>
#
# Usage:
#   clone-worktree-repo.sh <repo-url> <path> [--branch <name>] [--no-fetch-all]
#
# Notes:
#   - `git clone --bare` sets no fetch refspec, so `git fetch` would only update
#     HEAD. We set a proper refspec so remote branches behave normally.
#   - Idempotent-ish: refuses to touch a non-empty target unless it's already
#     one of our layouts (in which case it reports and exits 0).

set -euo pipefail

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-1}"; }

REPO_URL=""; TARGET=""; BRANCH=""; FETCH_ALL=1
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    --branch) BRANCH="${2:?--branch needs a value}"; shift 2 ;;
    --no-fetch-all) FETCH_ALL=0; shift ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) if [ -z "$REPO_URL" ]; then REPO_URL="$1"; elif [ -z "$TARGET" ]; then TARGET="$1";
       else echo "Unexpected argument: $1" >&2; usage 1; fi; shift ;;
  esac
done

[ -n "$REPO_URL" ] && [ -n "$TARGET" ] || usage 1
command -v git >/dev/null || { echo "git not found on PATH" >&2; exit 1; }

# Already set up? Report and exit cleanly rather than clobbering.
if [ -d "$TARGET/.bare" ]; then
  echo "Already a worktree layout: $TARGET"
  git -C "$TARGET" worktree list
  exit 0
fi
if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null)" ]; then
  echo "Target exists and is not empty: $TARGET" >&2; exit 1
fi

mkdir -p "$TARGET"
TARGET="$(cd "$TARGET" && pwd)"   # absolutise

echo "Cloning $REPO_URL → $TARGET/.bare"
git clone --bare "$REPO_URL" "$TARGET/.bare"

# Make plain `git` commands work from the repo root.
printf 'gitdir: ./.bare\n' > "$TARGET/.git"

# A bare clone has no fetch refspec: without this, `git fetch` updates only HEAD
# and remote-tracking branches never appear.
git -C "$TARGET" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
if [ "$FETCH_ALL" -eq 1 ]; then
  echo "Fetching all remote branches..."
  git -C "$TARGET" fetch origin
fi

# Resolve the branch to check out first: explicit flag, else the remote's HEAD.
if [ -z "$BRANCH" ]; then
  BRANCH="$(git -C "$TARGET" symbolic-ref --short HEAD 2>/dev/null || true)"
  [ -n "$BRANCH" ] || BRANCH="$(git -C "$TARGET" remote show origin 2>/dev/null \
      | sed -n 's/.*HEAD branch: //p' | head -n1)"
  [ -n "$BRANCH" ] || BRANCH=main
fi

# Worktree dirs must be flat siblings: a branch like `feature/x` would otherwise
# nest (proj/feature/x). Flatten separators for the directory name only.
DIR="$(printf '%s' "$BRANCH" | tr '/' '-')"

echo "Creating worktree for '$BRANCH' → $TARGET/$DIR"
if git -C "$TARGET" show-ref --verify --quiet "refs/heads/$BRANCH"; then
  git -C "$TARGET" worktree add "$DIR" "$BRANCH"
else
  # Only the remote ref exists: create a local branch tracking it.
  git -C "$TARGET" worktree add -b "$BRANCH" "$DIR" "origin/$BRANCH"
fi

# Ensure the checked-out branch tracks its remote (worktree add -b doesn't
# always set upstream), so push/pull/status work without extra flags.
if git -C "$TARGET" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git -C "$TARGET" branch --set-upstream-to="origin/$BRANCH" "$BRANCH" >/dev/null 2>&1 || true
fi

cat <<EOF

Done. Layout:
  $TARGET/
  ├── .bare/     (bare repo)
  ├── .git       (gitdir: ./.bare)
  └── $DIR/      (worktree for '$BRANCH')

Next:
  cd $TARGET/$DIR
  git -C $TARGET worktree add -b feat/thing feat-thing   # new branch + worktree
  git -C $TARGET worktree list
EOF