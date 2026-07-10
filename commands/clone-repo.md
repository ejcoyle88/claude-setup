---
description: >-
  Clone a git repository into a worktree-friendly layout (bare repo + sibling
  worktrees), then report the structure and next steps. Takes a repo URL and a
  target path.
argument-hint: "<repo-url> <path> [--branch <name>]"
allowed-tools: Bash(git clone:*), Bash(git worktree:*), Bash(git -C:*), Bash(git config:*), Bash(git remote:*), Bash(git branch:*), Bash(git fetch:*), Bash(git show-ref:*), Bash(git symbolic-ref:*), Bash(ls:*), Bash(cat:*), Bash($HOME/.claude/scripts/clone-worktree-repo.sh:*), Read
---

Clone a repository into a layout built for worktree-based development.

## Do this

1. Parse `$ARGUMENTS` for the repo URL and target path (plus an optional
   `--branch <name>`). If either the URL or the path is missing, ask for it
   rather than guessing.
2. Run the script (it does the real work — don't reimplement it inline):

   ```
   $HOME/.claude/scripts/clone-worktree-repo.sh <repo-url> <path> [--branch <name>]
   ```

3. If it fails, report the error plainly. Common causes: the target exists and
   is non-empty (the script refuses rather than clobber), no network/auth for
   the remote, or `git` missing. Don't retry with force.
4. On success, show `git -C <path> worktree list` and tell them the checked-out
   worktree's path.

## The layout it produces

```
<path>/
├── .bare/       the bare repository (all git objects)
├── .git         a file containing "gitdir: ./.bare"
└── <branch>/    a worktree for the default (or requested) branch
```

No worktree is privileged — the repo data lives in `.bare/`, and each branch is
a sibling directory you can add or remove freely. The `.git` pointer file means
plain `git` commands work from `<path>` itself. Branch names with slashes are
flattened for the directory (`feature/x` → `feature-x/`) to keep siblings flat.

## Follow-on operations (mention only if useful)

- Add a worktree for a new branch: `git -C <path> worktree add -b feat/x feat-x`
- Add one for an existing remote branch: `git -C <path> worktree add feat-x origin/feat/x`
- List: `git -C <path> worktree list` · Remove: `git -C <path> worktree remove <dir>`
- Prune stale entries after deleting a directory by hand: `git -C <path> worktree prune`

## Why this layout

Worktrees let several branches be checked out at once in separate directories
sharing one object store — no stashing to switch, and independent build outputs.
That's what makes parallel agent work practical: `run-overnight.sh` with
`PARALLEL_WORKERS > 1` gives each worker its own worktree. This structure sets a
repo up for that from the start.

Do not create worktrees, branches, or commits beyond what was asked.