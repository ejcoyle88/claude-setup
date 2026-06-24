---
description: >-
  Orchestrate a code review — inline for small changes, fan out to specialist
  reviewers for large ones. Outputs findings categorised by severity.
argument-hint: "[base-ref] [--suggestions] [--praise]"
allowed-tools: Read, Grep, Glob, Bash(git diff:*), Bash(git status:*), Bash(git log:*), Bash(git merge-base:*), Bash(git rev-parse:*), Task
---

You are orchestrating a code review. You either review the changeset yourself
(small changes) or fan out to specialist subagents and synthesise their findings
(large changes). Either way, you own the final presentation. You are read-only:
review and report, never edit.

## Orientation

- Branch / status: !`git status --short --branch`
- Change size vs HEAD: !`git diff --stat HEAD`

## Arguments

Treat `$ARGUMENTS` as an optional base ref followed by optional flags:

- A leading non-flag token is the **base ref** to diff against. If omitted,
  resolve it as `git merge-base HEAD <default-branch>`, trying `origin/main`,
  then `main`, then `origin/master`.
- `--suggestions` → include 🔵 Suggestion findings (off by default).
- `--praise` → include 🟢 Praise findings (off by default).

Resolve the review diff yourself with Bash: prefer the branch diff
`git diff <base>...HEAD`; if there is no meaningful branch delta, fall back to
staged, then working-tree, changes. Read changed files for context as needed.

## Routing

Measure the changeset (changed lines and files), then:

- **Small** — roughly ≤ 400 changed lines and ≤ 8 changed files: review it
  yourself, inline, using the Review dimensions below. Do not spawn subagents.
- **Large** — above either threshold: fan out. In a **single message**, dispatch
  these subagents **in parallel** via the Task tool, handing each the resolved
  base ref, the diff, and the list of changed files:
  - `security-reviewer`
  - `quality-reviewer`
  - `performance-reviewer`

  Then synthesise their returned findings (see Synthesis).

(The thresholds are a starting point — tune them to your repo and cost appetite.)

## Review dimensions (inline path)

Judge each by real impact on the running system, not a rulebook. This is the
union of what the specialists cover:

- **Security** — unvalidated input, injection, missing authn/authz, secrets in
  source/logs, weak crypto, unsafe deserialization, sensitive data exposure.
- **Correctness** — wrong logic, off-by-one, unhandled cases, bad null/empty
  handling, broken invariants.
- **Error handling** — caught at the right level, not swallowed; resources
  released on every path.
- **Concurrency** — races, deadlocks, unawaited work, missing cancellation (bugs)
  and contention/starvation (cost).
- **Performance** — algorithmic blow-ups, N+1 queries, unbounded allocations,
  resource leaks, missing/incorrect caching.
- **Maintainability** — naming, coupling, duplication, dead code, error-prone
  complexity. Treat coverage/complexity thresholds as signals, not gates.
- **Tests** — meaningful coverage of new behaviour and failure modes; isolated;
  asserting behaviour, not implementation.
- **Dependencies** — new packages: known CVEs, supply-chain risk, license,
  maintenance health, and whether the dependency is warranted.
- **Documentation** — public APIs and non-obvious decisions explained; comments
  that haven't drifted.

## Severity scale (you own this)

- 🔴 **Critical** — bugs, data-loss risks, blocking async anti-patterns,
  breaking changes, or performance issues that will cause production problems.
  **Must** fix before merge. Always reported.
- 🟡 **Warning** — standards violations, missing error handling, logic concerns,
  performance degradations. Should fix. Always reported.
- 🔵 **Suggestion** — style, minor improvements, nitpicks. Report **only** if
  `--suggestions` was passed.
- 🟢 **Praise** — genuinely good choices worth reinforcing. Report **only** if
  `--praise` was passed, and only when there's something real to call out.

## Synthesis (fan-out path)

Each specialist returns structured findings (provisional severity, `WHERE`,
`CATEGORY`, `ISSUE`, `FIX`). You turn them into one coherent review:

1. **Merge** all findings into a single list.
2. **Deduplicate** — if two agents flag the same issue at the same location,
   keep one, taking the higher severity and the clearer fix.
3. **Reconcile severity** against the scale above; a specialist's tag is only
   provisional.
4. **Filter** — drop 🔵 unless `--suggestions`, drop 🟢 unless `--praise`.
5. **Order** 🔴 → 🟡 → 🔵 → 🟢, most impactful first within each tier.

## Output format

Open with one summary line: counts per reported severity, the changeset's
primary language, and — when a language specialist exists for it — a note that a
language-specific pass is recommended (e.g. C# → `csharp-developer`); the main
session owns that mapping. Then the findings, each in exactly this block,
separated by a line containing only `---`. Match the emoji/category to the
finding's severity:

🔴 **Critical** - `filename:approx_line_number`

**Issue:** A clear description of what is wrong and why it matters.

**Fix:** Concrete suggestion or example code snippet.
---

If there are no 🔴 or 🟡 findings, say "No blocking issues found." in one line
instead of emitting an empty review — and still surface any requested 🔵/🟢
items.
