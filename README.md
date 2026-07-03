# Claude Config

A personal, opinionated [Claude Code](https://claude.com/claude-code) setup that
turns a backlog into shipped, reviewed commits — interactively or unattended
overnight. It's a suite of specialist agents, on-demand skills, an orchestration
command, a semantic-navigation hook, an autonomous runner, and a sandboxed
container with observability.

This is my own config, published for reference rather than as a product. You
almost certainly don't want to adopt it wholesale — but the structure and the
reasoning behind it are meant to be clear enough to borrow from. Everything here
assumes Claude Code plus [beads](https://github.com/gastownhall/beads) (`bd`), a
dependency-aware issue tracker built for coding agents; "bead" means "issue/task"
throughout.

---

## What it does

A single task flows like this:

```
bd ready ──▶ /build-next ──▶ clarify ──▶ route to a language developer
                                              │
                                    implement (TDD)
                                              │
                              ◀── review: security + quality + performance ──▶
                                    (react to blocking findings; ≤2 cycles)
                                              │
                                    close bead ──▶ commit
```

`/build-next` is the orchestrator. It pulls the next ready bead, works out which
specialist should handle it, has that developer implement it test-first, runs
three reviewers over the diff in parallel, feeds blocking findings back for a
fix, and closes the bead. Run it once for one task, or let `run-overnight.sh`
loop it in fresh headless processes until the backlog is empty — and then mine
the night's telemetry to file its own token-efficiency improvements.

---

## Why it's built this way

The design has a few load-bearing principles. They're the reason the pieces look
the way they do.

**Token efficiency is a first-class constraint.** Agent bodies stay lean —
identity, a handful of always-on defaults, and an index of skills. The depth
lives in _skills_ that load only when a task touches their domain (progressive
disclosure). A bug-fix bead never pays for the Temporal or caching guidance it
doesn't use. The same instinct drives fresh-context-per-task, conditional second
review cycles, and passing structured findings between steps instead of raw
diffs. The cheapest token is the one you don't spend.

**One source of truth, consumed two ways.** The convention skills (data access,
testing, dependencies, …) carry a `## Review checklist`. The _developer_ writes
to that standard; the _reviewers_ judge against the same text. The standard can't
drift because there's only one copy. Likewise, every developer preloads a single
`developer-workflow` skill for the shared scaffolding (context-gathering,
navigation, escalation, quality-gate shape, return contract), so a fix there
lands in every language at once.

**Each job gets the right mechanism.** Claude Code offers several extension
points and they are not interchangeable: **skills** for progressively-disclosed
know-how, **CLAUDE.md** for always-relevant standing conventions, **hooks** for
deterministic enforcement the model can't drift away from, **commands** for
user-invoked orchestration, and **subagents** for isolated specialist context.
Putting an always-on rule in a skill (won't reliably load) or a one-line
convention in a hook (overkill) is a design smell. Most of the choices here come
down to picking the right one.

**Orchestration lives in the main session, not a subagent.** Two hard limits
shape this: a subagent can't prompt the user (`AskUserQuestion` doesn't work
inside one), and only its final message returns to the caller. So the
orchestrator owns the loop count, the routing, and any clarifying questions, and
passes everything a subagent needs forward in its prompt. The developers and
reviewers are subagents; the coordination is not.

**Verify deterministically; don't trust self-report.** An LLM saying "tests
pass" is not evidence. The overnight runner runs the build and tests _itself_
before a task counts as done, and the meta-agents verify tool flags and schemas
against current docs rather than memory (Claude Code drifts between releases).

**Language-agnostic core, language-specific edges.** The reviewers, the
orchestrator, and `developer-workflow` are shared and never change when you add a
language. A new language is a slim `<lang>-developer`, a few `<lang>-*` skills,
and one routing row. Reviewers pick up the new language automatically because the
skill _descriptions_ are language-scoped — a Rust diff matches `rust-*`, not
`dotnet-*`.

**The loop tunes itself.** Each night's telemetry is analysed at the end of the
run; token-waste findings become `[token-efficiency]` beads that flow back into
`/build-next` the next night. The config maintains its own config.

---

## The pieces

### Agents (`agents/`)

- **Language developers** — `csharp-developer`, `rust-developer`,
  `angular-developer`. Build and fix code in one stack; scope is stated in each
  (e.g. server-side .NET, not UI).
- **Meta developers** — `agent-improvement-developer` (edits this suite itself:
  agents, skills, commands, hooks, settings) and `infra-developer` (the
  containerized dev environment: Dockerfiles, compose, the firewall, the
  observability stack, CI).
- **Reviewers** — `security-reviewer`, `quality-reviewer` (on Sonnet),
  `performance-reviewer`. Read-only; return structured findings for the
  orchestrator to merge. Each carries a short _Project conventions_ note pointing
  at the `<lang>-*` skills so it flags deviations from house style, not adherence
  to it.

### Skills (`skills/`)

Folders with a `SKILL.md`; loaded on demand by description match.

- `developer-workflow` — shared scaffolding every developer preloads.
- `dotnet-*`, `rust-*`, `angular-*` — per-language convention suites; the shared
  ones carry review checklists.
- `dotnet-language-version` — detects the effective C# floor across the solution
  and gates feature use to it (bundles a detector script).
- `claude-config-authoring`, `container-infra`, `observability-stack` — the
  meta-agents' domain knowledge, footguns included.

### Commands (`commands/`)

- **`/build-next`** — the task orchestrator (below). Interactive and
  `--unattended` modes.
- **`/plan-work`** — turns a rough outline into small, isolated beads: grills you
  one question at a time to resolve the design, proposes a decomposition for your
  approval, then files dependency-linked, prioritised beads. The inverse of
  `/build-next` — it creates what the loop consumes.
- **`/review`** — human-facing code review; small changes inline, large ones fan
  out to the three reviewers, formatted for a person.
- **`/analyze-telemetry`** — end-of-night token-efficiency analysis; files
  `[token-efficiency]` beads.

### Hook (`hooks/lsp-first-guard.py`)

Steers agents to LSP-backed semantic tools (Serena, rust-analyzer, csharp-lsp)
instead of grep. A `SessionStart` primer states the policy; a `PreToolUse(Grep)`
guard denies a grep _only_ when it's a bare-identifier symbol search in a
language with an LSP — free-text and config searches pass through. Conservative
by design (it under-blocks); tune via the `LANGUAGES` map.

### Runner (`tools/run-overnight.sh`)

Loops fresh headless Claude processes over `/build-next --unattended` until the
backlog is empty, with a deterministic verification gate, budget caps, telemetry,
and optional worktree parallelism.

### Sandbox (`.devcontainer/`)

A network-restricted container (default-DROP egress with an allowlist) plus an
optional OpenTelemetry sidecar stack (Collector → Prometheus + Loki → Grafana).
This is where unattended runs belong.

---

## Usage flows

### 0. Plan a piece of work into beads

```
/plan-work add rate limiting to the public API
```

Grills you one question at a time to nail the design (checking the codebase
before asking, always offering a recommendation), proposes a decomposition into
small isolated tasks for you to approve or edit, then files them with dependency
links and priorities. You now have a ready backlog for the flows below.

### 1. One task, interactively

```
/build-next            # next ready bead
/build-next bd-a1b2    # a specific bead
```

The orchestrator clarifies anything ambiguous up front (it has `AskUserQuestion`;
the developer subagent doesn't), routes to a developer, runs the review cycle,
and closes the bead. A second review cycle runs only if the first found blocking
issues.

### 2. Review on demand

```
/review                # working changes
/review main --suggestions --praise
```

Independent of the loop — a human-readable review of a diff.

### 3. Autonomous overnight

```
VERIFY_CMD="dotnet build && dotnet test" ./tools/run-overnight.sh
```

Each iteration is a fresh process (fresh context, deliberately). The runner
checks `bd ready` for termination, runs `VERIFY_CMD` before counting a task done,
commits per bead, and stops on an empty backlog, a stop file (`touch
.stop-overnight`), the iteration cap, the budget, or a failure streak. Unattended
mode replaces user prompts with **question beads**: an ambiguous task is deferred
by filing a `Question:` bead it now depends on, dropping it from the ready queue
for a morning pass. At the end, `/analyze-telemetry` mines the run and files
efficiency beads. **Run this in the container**, and start with `MAX_ITERATIONS=2`
on a small backlog.

### 4. Maintaining and extending the suite

The suite edits itself: a bead about a skill or agent routes to
`agent-improvement-developer`; one about the container or telemetry routes to
`infra-developer`. To add a language by hand, see _Extending_ below.

---

## Install

### Prerequisites

- **Claude Code** (v2.1.83+ for auto mode).
- **beads** (`bd`) on `PATH` with an initialised store (`bd init`).
- **jq** (used by `install.sh` and the firewall).
- The **toolchains** for whatever you build (.NET SDK, Rust, Node/Angular CLI).
- Optional **MCP servers**: Serena (semantic navigation, all languages), Context7
  (library docs), plus per-language doc/package servers (Microsoft Learn + NuGet
  for .NET, the Angular CLI MCP). Names must match your registration — see
  Configuration.
- Optional **Docker** for the sandbox and overnight runs.

### Steps

```bash
git clone <this-repo> claude-config && cd claude-config
./install.sh
```

`install.sh` symlinks `agents/ skills/ commands/ hooks/ scripts/` into
`~/.claude/`, links `statusline-command.sh`, and merges `settings.shared.json`
into `~/.claude/settings.json` (so the hook registers without clobbering your
local settings). Symlinks mean edits in the repo are live immediately; _adding or
removing_ an entry needs a re-run. `tools/` (the overnight runner, ollama-mcp)
is project-local and deliberately NOT symlinked — it's invoked directly from
within the repo (e.g. `./tools/run-overnight.sh`), not from `~/.claude/`.

Global (`~/.claude/`) is the intended scope — this is a personal toolchain, not
per-repo config. Per-project overrides still work from a repo's `.claude/`.

### Sandbox / overnight

Copy `.devcontainer/` into the target repo and open it in a devcontainer. The
container installs Claude Code and `bd` at build time (so the runtime firewall
never needs them), runs the firewall then `install.sh` at start, and — if you use
the compose stack — brings up the telemetry sidecars. See
[`skills/container-infra/SKILL.md`](skills/container-infra/SKILL.md) for the
mount and networking details (single-file bind mounts are delivered via compose
`configs` to avoid a class of silent failures).

### Dogfooding this repo

Because this repo _is_ Claude config, the container mounts it at `/workspace` and
`install.sh` links it into `~/.claude` — so you develop the config using the
config. For overnight runs set `PRE_ITERATION_CMD="./install.sh"` so newly added
skills are linked before the next iteration.

---

## Testing

Two standalone scripts under `tests/`, no framework required:

- `tests/test_install.sh` — exercises `install.sh` (symlinking, settings merge,
  re-run idempotency).
- `tests/test_run_overnight.sh` — exercises the completed-iteration/spend
  extraction logic in `tools/run-overnight.sh` against fabricated worker logs,
  without launching Claude or doing a real overnight run.

```bash
bash tests/test_install.sh
bash tests/test_run_overnight.sh
```

---

## Configuration

### Overnight runner (environment variables)

| Variable                      | Default                     | Purpose                                                                                                                                                     |
| ----------------------------- | --------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `VERIFY_CMD`                  | _(empty)_                   | Deterministic gate, e.g. `"dotnet build && dotnet test"`. Run at startup and after each iteration; a red result halts the worker. **Strongly recommended.** |
| `MAX_ITERATIONS`              | `20`                        | Per-worker loop cap; also your cost ceiling.                                                                                                                |
| `RUN_TIMEOUT`                 | `90m`                       | Per-iteration kill timer.                                                                                                                                   |
| `MAX_TOTAL_COST_USD`          | `50`                        | Whole-run budget (from telemetry; notional on a subscription).                                                                                              |
| `MAX_TURNS`                   | `150`                       | Per-run agentic turn cap.                                                                                                                                   |
| `MAX_CONSEC_FAILURES`         | `3`                         | Halt a worker after this many failures in a row.                                                                                                            |
| `PERMISSION_FLAGS`            | `--permission-mode auto`    | Permission strategy (see Safety).                                                                                                                           |
| `PARALLEL_WORKERS`            | `1`                         | Worktree parallelism — **requires `bd` in server mode** (shared claims).                                                                                    |
| `PRE_ITERATION_CMD`           | _(empty)_                   | Runs before each iteration (e.g. `./install.sh` when dogfooding).                                                                                           |
| `ANALYZE_TELEMETRY`           | `1`                         | Run `/analyze-telemetry` at end of night.                                                                                                                   |
| `OTEL_ENABLED`                | `1`                         | Export OpenTelemetry metrics + logs.                                                                                                                        |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317`     | Collector endpoint (use a service name / host-gateway inside a container).                                                                                  |
| `PROM_URL` / `LOKI_URL`       | compose service URLs        | Query endpoints for the analyzer (optional).                                                                                                                |
| `STOP_FILE`                   | `<project>/.stop-overnight` | `touch` to halt gracefully.                                                                                                                                 |

### Hook

`LANGUAGES` in `hooks/lsp-first-guard.py` maps a language to the LSP tools to
recommend; add an entry (a TypeScript stub is commented in) to cover a new
language. Registered globally in `~/.claude/settings.json` via `$HOME/.claude/...`
paths (a quoted `~` won't expand; `$CLAUDE_PROJECT_DIR` is the _project_ root, not
`~/.claude`). If the guard doesn't fire inside developer subagents, add the same
`PreToolUse` block to each developer's frontmatter.

### MCP servers

Each developer's `tools:` list names its MCP servers as `mcp__<server>__*` — the
`<server>` must match your registered name (`claude mcp list`). Serena and
Context7 are cross-language; the rest are per-stack.

### Models

Reviewers route per role (`quality-reviewer`, security, and performance all on
Sonnet). Keep the orchestrator on Sonnet or higher — it does multi-step judgment
(routing, finding reconciliation, defer-vs-clarify), which is where a weak model
costs the most.

### Telemetry backends

Defaults target a local collector. Point `OTEL_EXPORTER_OTLP_*` at a hosted
backend if you prefer — but keep credentials in a host-side collector, not in the
sandbox. If nothing listens at the endpoint, exports **drop silently**; verify
with `OTEL_METRICS_EXPORTER=console`. Telemetry is structural (no prompt text)
unless you opt in.

---

## Extending: add a language

1. Copy an existing `<lang>-developer.md`; swap the house defaults, skill index,
   MCP servers, and quality-gate commands.
2. Write the `<lang>-*` skills you need (start with 2–3); give shared ones a
   `## Review checklist`.
3. Add one row to `/build-next`'s routing table.

The reviewers, `/review`, the loop, and `developer-workflow` are untouched.

---

## Repository layout

```
.
├── agents/                 language developers, meta developers, reviewers
├── skills/                 developer-workflow + per-language + meta skill suites
├── commands/               build-next, plan-work, review, analyze-telemetry
├── hooks/                  lsp-first-guard.py
├── scripts/                git-ro.sh, reviewer-bash-guard.py — symlinked into ~/.claude
├── tools/                  project-local tooling (run-overnight.sh, ollama-mcp/) — not symlinked into ~/.claude
├── tests/                  test_install.sh, test_run_overnight.sh
├── .devcontainer/          sandbox + OpenTelemetry sidecar stack
├── settings.shared.json    merged into ~/.claude/settings.json by install.sh
├── CLAUDE.md               always-on standing conventions
├── statusline-command.sh   custom status line
└── install.sh              symlink + settings-merge installer
```

---

## Safety and honesty

Unattended autonomy is the sharp edge here.

- **Auto mode** (the default) reviews each action with a classifier and needs
  v2.1.83+, a Team/Enterprise plan, and the Anthropic API provider; a preflight
  probe fails fast if it's unavailable. The fallback is
  `--dangerously-skip-permissions`, which should only run in the container (it
  refuses to run as root) — never against a machine with production credentials
  in its environment.
- **The deterministic gate is your real safety net**, not the LLM review loop.
  Set `VERIFY_CMD`.
- **Cost figures are notional on a subscription** (API-equivalent), but still
  work as relative caps.
- **Version-sensitive claims drift.** Flags, frontmatter fields, hook schemas,
  and model defaults change between Claude Code releases; verify against current
  docs before relying on a specific one.
