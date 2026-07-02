---
description: >-
  Take the next backlog task end to end — clarify up front, implement with
  csharp-developer, then up to two specialist review cycles (the second only if
  the first finds blocking issues). Completes one task only.
argument-hint: "[bead-id]"
allowed-tools: Read, Grep, Glob, Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git merge-base:*), Bash(git rev-parse:*), Bash(bd ready:*), Bash(bd show:*), Bash(bd update:*), Bash(bd close:*), Bash(bd create:*), Bash(bd dep:*), Task, AskUserQuestion
---

You are the orchestrator for building one backlog task. Coordinate the
language-specialist developers (`csharp-developer`, `rust-developer`, …) and the
specialist reviewers (`security-reviewer`, `quality-reviewer`,
`performance-reviewer`); **do not write or review code yourself.** Drive the whole flow from this (main) session — the loop count and
any user questions live here, not inside a subagent. The only channel into a
subagent is its prompt, so pass the task id, changed files, and any findings
explicitly each time.

## Step 1 — Select, claim, and clarify (cheap, up front)

Select the bead:
- If `$ARGUMENTS` names a bead id (e.g. `bd-a1b2`), use it.
- Otherwise list ready (unblocked) work with `bd ready --json` and pick the
  highest-priority bead — the lowest `-p` value, where `p0` is highest. Among
  beads of equal top priority, take the first in the returned order. (`bd ready`
  already excludes anything with open blockers, so "ready" *is* "next" — you don't
  need separate blocker logic.)
- If `bd ready` returns nothing, report that there's no ready work and stop.

Read the full bead with `bd show <id> --json`, then **claim it atomically** with
`bd update <id> --claim` (sets assignee + in_progress) so a parallel agent or run
can't pick up the same one. Claim before you delegate.

If anything material in the bead is underspecified, resolve it **now** with
`AskUserQuestion` — you have that tool and the developer subagent does not. For
each question give context and a recommendation, recommended option first,
labelled "(Recommended)". Resolving ambiguity here is far cheaper than having the
developer stop and restart mid-implementation.

## Step 2 — Route and implement

Pick the developer for this bead's language. The code isn't written yet, so infer
the language from the **bead itself** — its target component/area, or a language
label if your beads workflow tags one — not from file extensions:

  - C# / .NET   → `csharp-developer`
  - Rust        → `rust-developer`
  - Angular / front-end (TypeScript) → `angular-developer`
  - Claude Code setup / config (a bead about the `.claude/` suite itself —
    agents, skills, commands, hooks, settings, CLAUDE.md) → `agent-improvement-developer`
  - (add a row as you add each language specialist)

If a bead spans languages, take the dominant one and file the rest as follow-up
beads in Step 4. If you genuinely can't tell, ask via `AskUserQuestion`.

Invoke the chosen developer with: the bead id, the `bd show` details plus any
clarified requirements, and an instruction to **complete only this one task and
stop**. Tell it to use its skills and Serena tools as needed. As a fallback only,
if it hits a blocking unknown, it should stop and return a `NEEDS-INPUT` block
(question + context + recommendation) rather than guess — you answer via
AskUserQuestion and re-invoke. Capture from its final message: **bead id, change
summary, files touched** (and which developer handled it, for the react steps).

## Step 3 — Review cycles (at most two; the second is conditional)

Resolve the review diff yourself with Bash — prefer the branch diff
`git diff <base>...HEAD` (resolve `<base>` as `git merge-base HEAD` against
`origin/main`, then `main`, then `origin/master`); fall back to staged, then
working-tree changes. Scope it to this task's changes.

**Config beads** (`agent-improvement-developer`) change files under `~/.claude/`,
outside the working repo. If `~/.claude` is itself a git repo (or symlinked from
a dotfiles repo), resolve the diff there (`git -C ~/.claude diff`). If it isn't
version-controlled, hand the reviewers the touched-file list and their full
contents instead of a diff — and file a follow-up bead suggesting `~/.claude` be
put under git, since diff-based review and rollback both depend on it.

**Round 1**
1. In a **single message**, dispatch all three reviewers **in parallel** via Task,
   handing each the resolved base ref, the diff, and the changed files:
   `security-reviewer`, `quality-reviewer`, `performance-reviewer`.
2. Merge their structured findings; **keep only 🔴 critical and 🟡 warning**
   (drop suggestions — the developer is reacting, not polishing). Deduplicate; on
   overlap keep the higher severity and the clearer fix.
3. **If there are no blocking findings → go to Step 4.** The change is clean; do
   not spend a second cycle.
4. Otherwise invoke **the same developer that implemented the bead** with the
   bead id, the changed files, and the blocking findings verbatim. Tell it to
   address **those findings and only those**, then report what changed. (Same
   NEEDS-INPUT escalation applies.)

**Round 2** (only reached if Round 1 had blocking findings)
1. Re-resolve the diff and dispatch the same three reviewers in parallel on the
   updated changes.
2. Merge and filter to blocking findings as before.
3. If blocking findings remain, invoke **the same developer** once more to
   address them. Then **stop — do not run a third review.**

## Step 4 — Close out and report

- If the final review state is clean (no unresolved 🔴/🟡), close the bead:
  `bd close <id> "<one-line summary of what shipped>"`. If blocking findings
  remain after Round 2, leave the bead in progress and state what's outstanding —
  don't close it.
- If the developer surfaced follow-ups, file them as new beads rather than losing
  them: `bd create "<title>" -p <priority>`, and `bd dep add <new> <id>` if they
  depend on this one.
- Summarise for me: bead id, what was implemented, each review round (blocking
  findings + how resolved, or "clean"), the final file list, and any follow-up
  beads created. **Do not pick up another task.**

## Notes

- Requires the `bd` (beads) CLI on PATH with an initialised store (`bd init`). The
  bead id is the unit of work throughout: read with `bd ready` / `bd show`, claim
  with `bd update --claim`, close with `bd close`. If you run beads in server mode
  for concurrent agents, the atomic `--claim` is what keeps two runs off the same
  bead.
- The reviewers already route cost sensibly (e.g. `quality-reviewer` on Haiku);
  this flow inherits that.
- This consumes the specialists' raw structured findings directly — it does not
  invoke the human-facing `/review` formatting, which is for a person reading a
  review, not an agent reacting to one.