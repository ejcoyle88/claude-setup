---
description: Audit every subagent and skill against Anthropic's current authoring guidelines and produce a human-facing review.
argument-hint: "[agents|skills|<path-or-glob>]   (optional; default: audit everything)"
allowed-tools: Bash(find:*), Bash(ls:*), Read, Glob, Grep, WebFetch, Agent
model: sonnet
---

You are the **orchestrator** for a configuration audit. You review the *authoring
quality* of this project's subagents and skills against Anthropic's **current
published guidance** — not the code they help write. This is a **read-only**
review: you do not edit any file. You produce a single human-facing report,
much like `/review`, but the subject is the config suite itself.

Do not do the per-artifact reading yourself. Fetch the guidelines once, distill
them, then delegate each artifact to a read-only reviewer and consolidate the
findings — the same fetch → fan-out → consolidate shape `/review` uses.

## Step 0 — Scope

Read `$ARGUMENTS`:

- empty            → audit **both** subagents and skills
- `agents`         → subagents only
- `skills`         → skills only
- a path or glob   → only artifacts matching it (e.g. `dotnet-*`, `rust-developer`)

Default to project scope (`.claude/`). If the person wants their user-scope suite
too, they'll say so — then also include `~/.claude/agents` and `~/.claude/skills`.

## Step 1 — Fetch the current guidelines (the point of this command)

WebFetch both canonical docs and distil each into a compact rubric you'll hand to
the reviewers. Do **not** paste whole docs into reviewer prompts — distil to the
checks below, refreshed against whatever the live pages now say.

- Subagents: `https://code.claude.com/docs/en/sub-agents`
- Skill authoring: `https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices`

Record **today's date and the fetch outcome** for each doc — you'll stamp the
report with it so the reader knows the baseline.

**If a fetch fails** (offline, rate-limited, page moved): fall back to the
*Embedded baseline rubric* at the bottom of this file, and flag prominently in the
report that guidelines could **not** be refreshed, naming which doc and why. A
stale audit that says so is fine; a stale audit that pretends to be current is not.

Reconcile the two: prefer the live pages; use the embedded baseline only to fill
gaps or when a fetch fails. If the live guidance has clearly changed a check
below, trust the live guidance and note the delta in the report.

## Step 2 — Inventory

```bash
find .claude/agents  -maxdepth 1 -name '*.md'        # subagents
find .claude/skills  -maxdepth 2 -name 'SKILL.md'    # skills (dir per skill)
```

Apply the Step 0 scope filter. If the inventory is empty for a requested type,
say so and continue with the other type rather than aborting.

## Step 3 — Dispatch reviews (parallel, batched)

For each artifact, dispatch the read-only **Explore** subagent (Haiku by default —
the right cost tier for a lint pass; if Explore isn't available in this version,
use `general-purpose` restricted to `Read, Glob, Grep, Bash(ls:*)`). The only
channel into a subagent is the prompt string, so each dispatch must carry
everything the reviewer needs: the **distilled rubric for that artifact's type**,
the **artifact path**, and the **return shape** below. The reviewer reads the
files itself; you pass the rubric, not the file bodies.

Batch the dispatches — up to ~6 in a single message, in parallel — so a 30-artifact
suite doesn't fan out all at once. Reviewers **report only; they never fix.**

Per-reviewer instructions to embed in each prompt:

- **Subagent** (`*.md` in `agents/`): read the file. Check its YAML frontmatter and
  its body against the *subagent rubric*.
- **Skill** (a `SKILL.md` + its directory): `ls -R` the skill directory first, then
  read `SKILL.md`, then spot-check any files it references. Several checks need the
  whole directory (references one level deep, scripts, path style, packages), not
  just `SKILL.md`. Check against the *skill rubric*.

**Required return shape** (identical for every reviewer, so you can merge them):

```
### <artifact name>  (<type>)
VERDICT: <clean | needs-work | broken>
- <severity> <check-id> — <location>: <finding>. Fix: <one line>.
- ...
```

Severity tags (mirror `/review`): 🔴 critical (breaks discovery/invocation, or an
outright rule violation) · 🟡 warning (works but drifts from guidance) · 🟢
suggestion (polish). If an artifact is clean, return `VERDICT: clean` with no
findings.

## Step 4 — Consolidate into the report

This is the `/review`-style human-facing output. Assemble:

1. **Header** — audit date; each guideline doc with ✅ fetched / ⚠️ baseline-fallback;
   the scope audited.
2. **Summary table** — one row per artifact: `name | type | 🔴 | 🟡 | 🟢 | verdict`,
   sorted worst-first.
3. **Per-artifact findings** — worst-first, each artifact's block verbatim from its
   reviewer, deduplicated.
4. **Systemic patterns** — issues recurring across many artifacts (e.g. "9 skills'
   descriptions state *what* but not *when to use*", "3 reviewers grant `Edit`/`Write`
   despite being read-only"). These are the highest-leverage fixes — call them out
   explicitly.
5. **Top actions** — the 3–5 changes that would most improve the suite.

Do **not** edit anything. Close by noting the person can run a follow-up fix pass
on any subset if they want.

---

## Embedded baseline rubric (fallback + what the reviewers check)

Use the live docs as the source of truth; this is the offline floor.

### Skill rubric — from the "Checklist for effective Skills"

- **FM-VALID** 🔴 — `name` ≤64 chars, lowercase/digits/hyphens only, no XML tags,
  not `anthropic`/`claude`; `description` non-empty, ≤1024 chars, no XML tags.
- **DESC-WHATWHEN** 🔴/🟡 — description states **both** what the skill does **and
  when to use it** (concrete trigger terms), in **third person**, specific not vague.
  This field drives discovery; a vague one is the top cause of a skill never firing.
- **BODY-500** 🟡 — `SKILL.md` body under ~500 lines; split into reference files if over.
- **DISCLOSURE** 🟡 — progressive disclosure: references are **one level deep** from
  `SKILL.md` (no reference-chains); reference files >100 lines carry a table of contents.
- **NO-TIMEBOMB** 🟡 — no time-sensitive info in the main body (quarantine legacy notes
  in an "Old patterns" section).
- **TERMS** 🟡/🟢 — consistent terminology throughout (one word per concept).
- **CONCRETE** 🟢 — examples are concrete input/output, not abstract description.
- **NO-OVEREXPLAIN** 🟢 — assumes Claude is already smart; no paragraphs teaching
  things Claude knows. Every paragraph justifies its token cost.
- **PATHS** 🔴 — forward slashes only, never `\`.
- **SCRIPTS** 🟡 — bundled scripts solve rather than punt, handle errors explicitly,
  no "voodoo constants", required packages listed, execute-vs-read intent stated.
- **MCP-QUALIFIED** 🟡 — MCP tools referenced as `Server:tool_name`, fully qualified.

### Subagent rubric — from the subagents docs + best practices

- **FM-REQUIRED** 🔴 — frontmatter present with `name` and `description`; optional
  `tools`, `model`, `skills`, `memory`, `hooks`, `effort` well-formed if present.
- **ONE-JOB** 🟡 — a single clear responsibility (one goal, one input, one output,
  one handoff). Grab-bag agents invoke unpredictably.
- **DESC-TRIGGER** 🔴/🟡 — description is action-oriented and says **when to use**
  ("Use after…", "Use proactively when…"). It's the delegation trigger; vague → under-
  or mis-invocation.
- **TOOLS-SCOPED** 🟡/🔴 — tools listed intentionally and least-privilege. **Omitting
  `tools` inherits ALL tools** — flag it. A read-only reviewer must not carry
  `Edit`/`Write`/`Bash` write access. 🔴 when a review-only agent can mutate.
- **MODEL-ROUTING** 🟢 — model fits the job (Haiku for mechanical/lint, Sonnet/Opus
  for reasoning); flag an expensive model on a trivial agent or vice-versa.
- **RETURN-SHAPE** 🟡 — body defines a concrete return shape the caller can act on
  (the parent gets only the final message).
- **NO-ASKUSER** 🔴 — the body must **not** rely on `AskUserQuestion` inside the
  subagent; it's unavailable/unreliable there. It should return a `NEEDS-INPUT`
  block for the orchestrator instead.
- **BG-SAFE** 🟢 — clear stop conditions and a defined "can't proceed" return, since
  background subagents auto-deny permission prompts.

### House conventions (project-specific — edit freely)

- **CONV-CHECKLIST** 🟡 — convention skills that are a shared source of truth
  (data-access, dependencies, testing, caching, performance, async, errors) carry a
  `## Review checklist` so a reviewer judges against the same standard the builder writes to.
- **LANG-SCOPED** 🟡 — language-convention skill descriptions name their language
  (`dotnet-*` → ".NET / C#", `rust-*` → "Rust", `angular-*` → "Angular") so a diff
  auto-routes to the right checklists without per-language reviewer edits.
- **DEV-WORKFLOW** 🟢 — each `<lang>-developer` preloads the shared `developer-workflow`
  skill rather than re-stating scaffolding, preventing drift across languages.