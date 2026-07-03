---
description: >-
  Turn a rough outline of intended work into small, well-isolated bd tasks.
  Grills you one question at a time to resolve the design, proposes a
  decomposition for your approval, then files the beads with dependency links and
  priorities. The inverse of /build-next — this creates the beads it later
  consumes.
argument-hint: "[rough outline of the work]"
allowed-tools: Read, Grep, Glob, Bash(git log:*), Bash(git diff:*), Bash(bd create:*), Bash(bd dep:*), Bash(bd list:*), Bash(bd show:*), Bash(bd ready:*), Task, AskUserQuestion, WebFetch
model: opus
---

You are helping turn a rough idea into a clean set of `bd` tasks. Two phases:
**grill** to resolve the design, then **decompose** into beads. Take
`$ARGUMENTS` as the starting outline (if empty, ask what they want to build).

## Phase 1 — Grill (resolve the design before decomposing)

Interrogate the plan until you understand it well enough to break down. Rules:

- **One question at a time.** Never batch — a wall of questions is bewildering.
  Ask, get the answer, let it inform the next question.
- **Walk the design as a dependency tree.** Resolve foundational decisions
  (data model, boundaries, contracts) before the details that depend on them.
  Don't ask about a leaf while its parent is unsettled.
- **Always offer a recommendation.** Give your best-guess answer with brief
  reasoning and let them correct it — decisions are faster to react to than to
  originate. Use `AskUserQuestion` with the recommended option first, labelled
  "(Recommended)".
- **Check the code before asking.** If the answer is discoverable — an existing
  pattern, a convention, how a neighbouring feature did it — explore with Read /
  Grep / Glob (or a subagent for a wider sweep) and confirm what you found
  instead of asking. Only ask what the codebase can't tell you.
- **Grill the decomposition-relevant unknowns**: scope boundaries, what's in vs
  out, sequencing constraints, where the seams are (so tasks isolate cleanly),
  interface/contract shapes (so parallel tasks don't collide), test strategy,
  and any risky or ambiguous area that would otherwise become a mid-build
  `NEEDS-INPUT`.
- Stop when you could write the tasks yourself without guessing. Don't
  over-grill settled things.

## Phase 2 — Decompose (propose, then file on approval)

Draft a set of beads. Aim each one at a **small, well-isolated changeset a
single person or agent can implement and that a reviewer can read in one sitting**:

- **One concern per bead.** If a bead needs "and", it's probably two.
- **Vertically sliced where possible** (a thin end-to-end capability) over broad
  horizontal layers, so each merges independently.
- **Isolated seams.** Where two beads touch the same surface, define the
  interface/contract in an earlier bead they both depend on, so they don't
  collide.
- **Self-contained brief.** Each bead states its goal, acceptance criteria, the
  files/area it touches, and any decision settled during grilling — enough that a
  fresh agent needs no extra context.
- **Right-sized.** If a bead can't be described in a sentence or two of outcome,
  split it. Prefer many small beads to a few large ones.

Then present the plan for approval — **do not file yet**:

- A dependency-ordered list: for each proposed bead, a title, one-line intent,
  priority, dependencies, and the target area/label.
- The dependency graph in outline (what blocks what, what can run in parallel).
- Call out any assumption you're making and anything still uncertain.

Ask the person to **approve, edit, or reject**. Apply their edits (re-present if
the changes are substantial). Only once they approve:

1. Create each bead: `bd create "<title>" -p <priority> --label <area> -d "<brief:
goal | acceptance | files/area | settled decisions>"`. Capture the returned ids.
2. Wire dependencies: `bd dep add <blocked-id> <blocker-id>` for every edge, so
   only the genuinely-ready beads surface in `bd ready`.
3. Set priorities to reflect the critical path (foundational/blocking beads
   higher).

## Report

List the beads created (id, title, priority), the dependency edges wired, and
which are immediately ready (`bd ready`) vs blocked. Note that `/build-next` will
pick these up in dependency order. Do not start implementing — this command only
plans.

## Notes

- If the outline is large, grill and decompose one coherent slice at a time
  rather than boiling the ocean; a follow-up `/plan-work` can handle the rest.
- Requires `bd` initialised (`bd init`). Beads route in `/build-next` by area/label
  — set a label that matches the intended specialist (e.g. the language, or
  `infra` / config), so downstream routing is unambiguous.
