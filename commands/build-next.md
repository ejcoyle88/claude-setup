---
description: >-
  Take the next backlog task end to end — clarify up front, implement with
  csharp-developer, then up to two specialist review cycles (the second only if
  the first finds blocking issues). Completes one task only.
argument-hint: "[bead-id] [--unattended]"
allowed-tools: Read, Grep, Glob, Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git merge-base:*), Bash(git rev-parse:*), Bash(git add:*), Bash(git commit:*), Bash(bd ready:*), Bash(bd show:*), Bash(bd update:*), Bash(bd close:*), Bash(bd create:*), Bash(bd dep:*), Task, AskUserQuestion
model: sonnet
---

You are the orchestrator for building one backlog task. Coordinate the
language-specialist developers (`csharp-developer`, `rust-developer`, …) and the
specialist reviewers (`security-reviewer`, `quality-reviewer`,
`performance-reviewer`); **do not write or review code yourself.** Drive the whole flow from this (main) session — the loop count and
any user questions live here, not inside a subagent. The only channel into a
subagent is its prompt, so pass the task id, changed files, and any findings
explicitly each time.

## Unattended mode (`--unattended` in `$ARGUMENTS`)

Used by the overnight runner (`run-overnight.sh`): headless, nobody to answer
questions. Everything below applies as written, with these overrides:

- **No async callback channel between iterations.** Each overnight iteration is
  a brand-new one-shot `claude -p` process; there is no later turn in this
  process to be "notified" on. If a developer or reviewer is dispatched to run
  in the background and the process exits before it resolves, its output is
  silently discarded and any bead it claimed is left stranded `in_progress`.
  Every subagent dispatch anywhere in this flow — Step 2's developer, Step 3's
  reviewers, any fix re-dispatch — **must be awaited in the foreground** before
  the iteration is considered to have made progress on it. Never end an
  iteration (or move to the next step) while a dispatched subagent's result is
  still outstanding.
- **Never call `AskUserQuestion`** — there is no one to answer; the run would
  hang or die.
- **Ambiguity → defer, don't guess.** If a bead is materially underspecified
  (Step 1) or the developer returns `NEEDS-INPUT` you can't resolve from the
  bead itself: create a question bead capturing the question, its context, and
  the recommendation (`bd create "Question: <summary> [for <id>]" -p 0`), make
  the original depend on it (`bd dep add <id> <question-id>`) so it leaves the
  ready queue, release your claim, and select the next ready bead. If three
  beads in a row defer this way, stop and report — the backlog needs a human
  pass. Exception: if a `NEEDS-INPUT` recommendation is low-risk and reversible
  (naming, internal structure — not schema, public API, data, or security),
  adopt the recommendation, proceed, and record the assumption in the bead's
  close summary.
- **Infeasible → defer immediately, same iteration.** See Step 1's "Infeasible
  bead" handling below — it applies unchanged here; unattended mode adds
  nothing on top of it (no `AskUserQuestion` either way, since infeasibility
  isn't ambiguity — see that section for why).
- **Commit per task.** After Step 4 closes a bead: `git add -A` and
  `git commit -m "<bead-id>: <one-line summary>"`. This is what keeps the next
  iteration's review diff scoped to one task. If blocking findings survive
  Round 2, still commit (`git add -A && git commit -m "wip(<bead-id>): unresolved
review findings"`), leave the bead in progress, and file a follow-up bead listing
  the unresolved findings.
- **Report tersely** — the final message lands in a log file, not a chat.

In interactive mode (no flag), ignore this section entirely.

## Step 1 — Select, claim, and clarify (cheap, up front)

Select the bead:

- If `$ARGUMENTS` names a bead id (e.g. `bd-a1b2`), use it.
- Otherwise list ready (unblocked) work with `bd ready --json` and pick the
  highest-priority bead — the lowest `-p` value, where `p0` is highest. Among
  beads of equal top priority, take the first in the returned order. (`bd ready`
  already excludes anything with open blockers, so "ready" _is_ "next" — you don't
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

**Infeasible bead → defer, don't re-litigate.** If the selected bead cannot be
worked in *this* environment — it needs a capability this session lacks (a
docker socket, a GUI, specific hardware, network reach to something
unreachable from here) — that's **infeasible**, a different failure mode from
"materially underspecified" above (an infeasible bead is perfectly well
specified; it just can't be done here). Handle it in the same iteration you
notice it, before selecting a replacement:

1. Defer it: `bd defer <id> --until=+7d` — a fixed default duration, not a
   per-bead judgment call. **This needs `Bash(bd defer:*)` in this command's
   `allowed-tools` frontmatter (line 7), which is not currently present** — a
   maintainer must add it before this step is actually executable. Until then,
   record in your report that you judged the bead infeasible and the intended
   defer command, and flag the missing grant, rather than silently treating
   the bead as handled. Verified empirically against the live `bd` CLI:
   `bd defer` only moves the issue's `status` from `in_progress` to `deferred`
   (a frozen-category status per `bd statuses`, which is what actually drops
   it from `bd ready`) — it does **not** touch `assignee`, so Step 1's
   `--claim` survives a defer on its own and step 2 below is still required.
2. Release the claim: `bd update <id> --assignee ""` — clears the assignee
   Step 1's `--claim` set, mirroring the Ambiguity path's "release your claim"
   above. This uses `Bash(bd update:*)`, already granted, so no new frontmatter
   entry is needed for this part. Do this regardless of whether the
   `Bash(bd defer:*)` grant above has landed yet: an unassigned-but-still-
   `in_progress` bead is still better than one left claimed indefinitely, and
   once defer *is* runnable this is what keeps the bead from looking claimed
   while it's frozen.
3. **Gate on whether step 1 actually ran.** Clearing `assignee` alone does not
   drop a bead from `bd ready` — only the `status` change from a successful
   `bd defer` does (see the empirical note above). So:
   - If `bd defer` succeeded: re-run (or reuse) `bd ready --json` — the
     deferred bead no longer appears, so the next-highest-priority bead
     surfaces on its own — and select it as normal.
   - If `bd defer` is blocked (tool not yet granted) or otherwise fails: do
     **not** re-run `bd ready`/select a replacement. The exact same bead would
     simply resurface at the top and the orchestrator would re-select,
     re-judge, and re-"handle" it in a tight loop. Instead, stop this
     iteration and report the bead as blocked-infeasible (per the report note
     in step 1), so a human can defer or otherwise resolve it out of band.

Do this immediately, not "next time": skipping the defer and just moving on
mentally leaves the same infeasible bead at the top of `bd ready` on the very
next iteration, so it re-pays the full selection cost (`bd ready`/`bd show` +
reasoning turns) every iteration until someone finally defers it. This applies
regardless of `--unattended` — feasibility doesn't depend on who's watching
(see the Unattended mode section's cross-reference to here).

## Step 2 — Route and implement

Pick the developer for this bead's language. The code isn't written yet, so infer
the language from the **bead itself** — its target component/area, or a language
label if your beads workflow tags one — not from file extensions:

- C# / .NET → `csharp-developer`
- Rust → `rust-developer`
- Angular / front-end (TypeScript) → `angular-developer`
- Plain TypeScript/Node service, CLI, or library code (not Angular
  front-end) → `node-developer`
- Claude Code setup / config (a bead about the `.claude/` suite itself —
  agents, skills, commands, hooks, settings, CLAUDE.md) → `agent-improvement-developer`
- Dev environment / containers / CI / observability (Dockerfile, compose,
  devcontainer, firewall, OTel stack) → `infra-developer`

If a bead spans languages, take the dominant one and file the rest as follow-up
beads in Step 4. If you genuinely can't tell, ask via `AskUserQuestion`.

Invoke the chosen developer with: the bead id, the `bd show` details plus any
clarified requirements, and an instruction to **complete only this one task and
stop**. Dispatch it in the **foreground** (`run_in_background: false`) and wait
for its result before proceeding to Step 3 — never background this call. In
unattended mode there is no later turn in this process to pick up a
backgrounded result at all (see "no async callback channel" above); even
interactively, Step 3 needs this developer's diff, so the dispatch must
resolve before you move on regardless of mode. Tell it to use its skills and
Serena tools as needed. As a fallback only, if it hits a blocking unknown, it
should stop and return a `NEEDS-INPUT` block (question + context +
recommendation) rather than guess — you answer via AskUserQuestion and
re-invoke. Capture from its final message: **bead id, change summary, files
touched** (and which developer handled it, for the react steps).

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

1. In a **single message**, dispatch all three reviewers **in parallel** via Task
   — three foreground (`run_in_background: false`) tool calls in that one
   message, which the harness runs concurrently and blocks on until all three
   return, not three background dispatches. Wait for all three results before
   continuing; never let this step complete with a reviewer still outstanding.
   Hand each the resolved base ref, the diff, and the changed files:
   `security-reviewer`, `quality-reviewer`, `performance-reviewer`.
2. **Verify each reviewer's response before trusting it — one re-dispatch
   decision, covering both checks together.** For each reviewer, evaluate both
   conditions before deciding whether to re-dispatch:
   - _CANNOT REVIEW claim_: verify against the diff you resolved above instead
     of accepting the self-report — was it truly empty/undecodable, did the
     fetch truly fail. If the claim checks out as legitimate, the
     coverage-completeness check below does not apply to that response — a
     genuine bail-out owes no per-file accounting.
   - _Coverage completeness_: on every completed review (any response other
     than a verified-legitimate CANNOT REVIEW), the reviewer's response must
     carry a `FILES REVIEWED: <list>` coverage note (its own line, after a
     trailing `---`, never folded into a finding block) naming every file you
     dispatched to it — unconditionally, regardless of how many findings it
     returned or what their `WHERE` fields say. A missing note, or one that
     omits a dispatched file, makes the response suspect. Don't accept a
     finding's `WHERE` as a substitute for the note, even one that lists
     several files at once — a single decoy finding whose `WHERE` names every
     dispatched file would otherwise "prove" coverage without ever requiring
     the note. (Extra files read for context beyond what was dispatched are
     fine; only dispatched files going unaccounted for count.)

   If either check is suspect, re-dispatch that reviewer **once**, foreground
   as always, re-checking both on the retry; if either still fails, surface it
   as a single 🟡
   warning-level finding (so it survives the filter step below) — do not
   silently drop it. Evaluating both together caps this at one re-dispatch per
   reviewer per round even when both misfire, closing both the bogus-bail-out
   route and the faked-clean-pass route (including a decoy finding whose
   `WHERE` lists every dispatched file at once) with one bounded mechanism.

3. Strip any `FILES REVIEWED:` line from a response before merging — it's a
   coverage note, not a finding. Merge the remaining structured findings;
   **keep only 🔴 critical and 🟡 warning** (drop suggestions — the developer is
   reacting, not polishing). Deduplicate; on overlap keep the higher severity
   and the clearer fix.
4. **If there are no blocking findings → go to Step 4.** The change is clean; do
   not spend a second cycle.
5. Otherwise, before invoking the developer, record a hash (or the literal
   text) of the diff you just reviewed — Round 2 below checks the fix against
   this. Then invoke **the same developer that implemented the bead**, in the
   foreground as in Step 2, with the bead id, the changed files, and the
   blocking findings verbatim. Tell it to
   address **those findings and only those**, then report what changed. (Same
   NEEDS-INPUT escalation applies.) **Round 2 is reached only from here** —
   immediately after this developer-fix dispatch has returned — never merely
   because Round 1 had blocking findings.

**Round 2** (gate: only entered right after Round 1, item 5's developer-fix
dispatch has returned; skip straight to Step 4 per Round 1, item 4, if Round 1
had no blocking findings in the first place — these two are one continuous
condition, not independent paths)

1. Re-resolve the diff and **compare it against the hash/text recorded in
   Round 1, item 5** before dispatching anyone. If the diff is unchanged, the
   developer-fix dispatch did not produce a delta — do not re-dispatch the
   reviewers against a diff they already reviewed. Instead, treat it as a
   failed fix: log/report that the fix dispatch produced no diff change, then
   re-invoke the same developer once more, foreground, with the same findings (first
   occurrence for this bead), then re-resolve the diff and re-compare against
   the same recorded hash/text before proceeding to item 2. If the diff still
   hasn't changed (i.e., this branch is being entered a second time for this
   bead), stop retrying and do not dispatch reviewers. Before escalating, commit
   the abandoned diff using the WIP-commit convention from the Unattended mode
   section's "Commit per task" bullet — applied here **regardless of mode**, a
   deliberate carve-out from that section's "ignore this section entirely"
   scoping for interactive mode, because cross-bead diff contamination is a
   risk in both modes, not only unattended runs:
   `git add -A && git commit -m "wip(<bead-id>): unresolved review findings —
   fix dispatch produced no diff change"`, leaving the bead in progress — so
   the abandoned diff is committed and labeled under its own bead id before
   any other bead's `git add -A` can absorb it. Then escalate: in unattended
   mode, per the defer handling in the Unattended mode section; in interactive
   mode, surface this via
   `AskUserQuestion` (developer's fix produced no diff change — retry,
   investigate manually, or abandon?) rather than silently deferring.
2. If the diff did change, dispatch the same three reviewers in parallel — same
   foreground, single-message convention as Round 1, item 1 — on the updated
   changes.
3. Apply the same combined verification as Round 1 (CANNOT REVIEW check, with
   its legitimate-bail-out exemption, plus the unconditional coverage-note
   check, capped at one re-dispatch per reviewer regardless of which condition
   failed), strip any `FILES REVIEWED:` line, then merge and filter to
   blocking findings as before.
4. If blocking findings remain, invoke **the same developer**, foreground, once
   more to address them, and wait for it to return. Then **stop — do not run a
   third review.**

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
- All three reviewers are dispatched together every round regardless of their
  descriptions' "Use when" clauses — those are non-exhaustive prioritization
  hints, not a filter this flow applies. `quality-reviewer` runs on sonnet with
  a deliberately broad trigger (fires on nearly every diff); whether that cost
  is warranted vs. a cheaper model or scope-based selective dispatch is an open
  question tracked in claude-58k, not something to route around here.
- This consumes the specialists' raw structured findings directly — it does not
  invoke the human-facing `/review` formatting, which is for a person reading a
  review, not an agent reacting to one.
