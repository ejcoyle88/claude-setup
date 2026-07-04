# ollama-mcp

A small stdio [MCP](https://modelcontextprotocol.io/) server that talks to a
local [Ollama](https://ollama.com/) instance, so Claude Code can offload work
to it instead of spending API tokens.

`claude-r30.3` scaffolded the transport (`ping`/`health`). `claude-r30.4` adds
the actual offload tools: `summarize_file`, `extract`, `classify`. All three
are **reference-based** — they take a file path (or, for `classify` only, a
short literal string), read the content themselves, and return only a compact
result. The point: if the caller had to pass file content as a tool argument,
that content would already be in Claude's context and there'd be nothing to
save. Only the path goes in; only a summary/extracted-fields/label comes out.

## Tools

- **`ping`** — takes no arguments, returns a static `{ ok: true }`. Proves the
  MCP stdio transport is working; does not contact Ollama.
- **`health`** — takes no arguments, does a lightweight `GET /api/tags`
  against `OLLAMA_HOST`. Never throws: returns
  `{ reachable, host, model, error? }`, degrading gracefully when Ollama is
  down or not yet deployed.
- **`summarize_file(path, focus?, startLine?, endLine?)`** — reads `path`
  (optionally sliced to a 1-indexed inclusive `startLine`/`endLine` range),
  sends it to `OLLAMA_MODEL` via `POST /api/generate` (structured-output
  `format` constrained to `{ summary: string }`), and returns
  `{ summary, truncated, truncatedChars? }`. `focus` optionally steers what
  the summary emphasizes (e.g. `"security-relevant changes"`).
- **`extract(path, schema, startLine?, endLine?)`** — reads `path` (same
  slicing as above) and asks Ollama to return JSON matching the caller-supplied
  `schema` (a JSON-Schema-like object, e.g.
  `{ type: "object", properties: { title: { type: "string" } }, required: ["title"] }`),
  passed straight through to Ollama's structured-output `format`. Returns
  `{ data, truncated, truncatedChars? }`. The response is validated against
  `schema` (required fields present, declared types match — see
  [Structured-output validation](#structured-output-validation)) rather than
  just checked for valid JSON; on a parse or validation failure the
  generation is retried once with the identical prompt before giving up. If
  the retry also fails, this returns `isError: true` with a message
  describing what was wrong, never a partially-parsed or best-guess result.
- **`classify(pathOrText, labels, isPath?, startLine?, endLine?)`** — classifies
  content into exactly one of `labels` (min 2), returning `{ label, truncated,
  truncatedChars? }`. Set `isPath: true` to have this server read `pathOrText`
  as a file path (recommended for anything beyond a short snippet, so the
  content stays out of Claude's context); when `isPath` is false/omitted,
  `pathOrText` is treated as literal text and should stay short — passing bulk
  file content directly here defeats the point of this server, use
  `isPath: true` instead. `startLine`/`endLine` only apply when `isPath` is
  true.

All three offload tools:

- Truncate file content to 12,000 characters (a crude proxy for staying well
  inside a small model's context window) before sending it to Ollama.
  Truncation is always reported back (`truncated`/`truncatedChars`), never
  silent — a file needing more than that isn't chunked in this bead (see
  Follow-ups). The read itself is bounded too: files over 8MiB on disk are
  rejected outright (`fstat`-checked before any read), and reads are
  streamed/capped rather than always buffering the whole file, even when
  it's well under that limit.
- Never throw: a bad/slow/unreachable Ollama, a missing file, or a malformed
  model response all come back as `isError: true` with a message, same
  graceful-degradation pattern as `health`.
- Validate the model's JSON response against the schema they asked Ollama's
  `format` to constrain, retry once on a parse or validation failure, and
  never pass a malformed/partially-parsed response through as if it were
  valid — see [Structured-output validation](#structured-output-validation).
- Use a 60s timeout on the first Ollama request (`health`'s reachability
  probe uses a much shorter 3s timeout — generation is slower); on a
  malformed/invalid response, the one retry (see
  [Structured-output validation](#structured-output-validation)) uses a
  shorter 30s timeout, so a single tool call's worst-case latency before
  returning `isError: true` is ~90s, not 60s.

### Structured-output validation

`llama3.2:3b` (this sidecar's default, CPU-only) doesn't reliably produce
output matching Ollama's structured-output `format` constraint even when it's
passed one. `claude-r30.5` addressed this: every tool that asks Ollama for
JSON (`summarize_file`'s `{ summary }`, `classify`'s `{ label }`, and
`extract`'s caller-supplied `schema`) runs the response through a shared
parse-and-validate step (`src/validate.ts`), not just "is this valid JSON, is
it an object" as before:

- The response is checked against the actual schema shape — required fields
  present, and each property's declared `type` (`string`/`number`/
  `integer`/`boolean`/`object`/`array`, recursively through nested
  `properties`/`items`, plus `enum` membership) matches what came back.
- On either a JSON parse failure or a schema-validation failure, the
  *identical* prompt is re-issued to Ollama exactly once (with a shorter 30s
  timeout rather than the first attempt's 60s — a retry is "resample the
  dice," not "give it more thinking time"), and the retry's response is
  validated the same way. Worst-case latency for a single tool call before
  it returns an error is therefore ~90s (60s + 30s), not 60s.
- If the retry also fails, the tool returns `isError: true` with a message
  describing exactly what was wrong (e.g. a missing field, a type mismatch, a
  label outside the given list, or invalid JSON) — never a raw stack trace,
  and never a best-guess/partially-parsed result passed through as if it were
  valid.

This validator is a small hand-written one (`validateAgainstSchema` in
`src/validate.ts`), not a library like `ajv` — the schemas actually used here
are flat-ish and one level deep at most, so a full JSON-Schema implementation
wasn't judged worth the dependency weight; see that file's header comment for
the detailed reasoning. Covered unit tests live in `src/validate.test.ts`
(run via `npm test`, Node's built-in `node:test` runner — no new
devDependency). There is no live Ollama sidecar in most dev sandboxes this
was built in, so the retry path itself (an actual second round-trip to a real
model) has only been exercised via hand-constructed good/bad JSON payloads
against the pure validation function, not against a live model.

### Progress notifications during generation

The ~90s worst-case latency above (`claude-lp5`, a follow-up to
`claude-r30.5`) is a risk if the *calling* MCP client's own tool-call timeout
is at/near 60s: it could fire a hard client-side transport timeout before
this server's own `isError: true` degradation ever gets a chance to return.
Confirming the real deployed client's timeout comfortably exceeds ~90s, and
getting empirical live-Ollama latency data to justify a tighter
`RETRY_TIMEOUT_MS`, both require a live MCP client and a live Ollama instance
that aren't available in this build sandbox — those two mitigations remain
open/unverified.

What *is* implemented here: while `generateStructured` awaits each of its
`callOllamaGenerate` calls (the first attempt and, if needed, the retry),
`summarize_file`/`extract`/`classify` send a `notifications/progress`
(`src/progress.ts`'s `withPeriodicProgress`/`makeProgressNotifier`) every
`PROGRESS_INTERVAL_MS` (12s) — well under both `GENERATE_TIMEOUT_MS` (60s) and
`RETRY_TIMEOUT_MS` (30s) — so a compliant client that opted in (by attaching a
`progressToken` to the request's `_meta`, per the MCP spec) keeps getting its
own timeout clock reset across the combined worst case. Per spec, a
`progressToken` is opt-in per request: if the caller didn't supply one, no
notification is ever sent (`makeProgressNotifier` returns a no-op). This is a
pure addition — it never changes a tool call's actual success/error/timeout
outcome, only adds an out-of-band side channel alongside it. Unit tests for
the timer/cadence logic and the opt-in gating live in `src/progress.test.ts`;
like the retry path above, an actual compliant client resetting its timeout
clock on a received notification hasn't been (and can't be, in this sandbox)
verified end-to-end.

## Environment variables

| Variable         | Default                 | Purpose                                                     |
| ---------------- | ------------------------ | ------------------------------------------------------------ |
| `OLLAMA_HOST`    | `http://ollama:11434`    | Base URL of the Ollama server (no path).                    |
| `OLLAMA_MODEL`   | `llama3.2:3b`            | Default model for future offload tools.                     |
| `WORKSPACE_ROOT` | this process's cwd       | Root directory that `path`/`pathOrText` args are confined to (see below). |

The `ollama` hostname above resolves to the Ollama sidecar container added by
a separate bead (`claude-r30.1`). That sidecar is not required for this server
to start — `ping` and `health` both work (with `health` reporting
`reachable: false`) even when Ollama isn't running yet.

`OLLAMA_MODEL` here **must match** the model the sidecar actually warms (see
the Model section below) — `docker-compose.yml`'s `x-ollama-common` anchor
sets the sidecar's own `OLLAMA_MODEL` the same way, defaulting to the same
`llama3.2:3b`. If you override one, override the other.

### Path confinement

Every `path` (and `pathOrText` when `isPath: true`) argument is resolved
against `WORKSPACE_ROOT` and, after following symlinks, must still land
inside it — an absolute path (e.g. `/etc/passwd`), a `../` traversal out of
the root, or a symlink that points outside it are all rejected with a clear
error rather than read. This also closes an indirect path: `extract`'s
caller-supplied `schema` could otherwise be crafted to have the model echo
arbitrary file content back into the tool result, so confining *which* files
can be read at all is the actual control, not just validating output shape.
`WORKSPACE_ROOT` defaults to this process's working directory, which is the
repo root when launched as a stdio MCP server from the devcontainer.

## Model

`claude-r30.2` picked [`llama3.2:3b`](https://ollama.com/library/llama3.2) as
the default model, and made the ollama sidecar (`.devcontainer/`) pull and
load it automatically on first start — see
`.devcontainer/ollama-entrypoint.sh`'s WARM section and
`.devcontainer/Dockerfile.ollama`'s `HEALTHCHECK` (the sidecar only reports
`healthy` once the model is actually present, so an MCP tool call after that
point should never hit a cold "model not found").

| Model                         | Pull size | RAM/VRAM (Q4_K_M) | Hardware        | Speed / accuracy                                  |
| ------------------------------ | --------- | ------------------ | ---------------- | -------------------------------------------------- |
| `llama3.2:3b` (default)        | ~2.0 GB   | ~2-3 GB             | CPU-only is fine | Faster, noticeably weaker reasoning/instruction-following than a 7B+ model — fine for trivial, low-stakes work (classification, short summarization, extraction from small inputs). |
| `qwen2.5:7b` (alternative)      | ~4.7 GB   | ~5.5 GB VRAM        | Wants a GPU       | Slower and heavier to pull/run, but meaningfully stronger accuracy — better fit if the offloaded task needs more careful reasoning and a GPU is available.                        |

Both are set via the single `OLLAMA_MODEL` variable (see the table above) —
no code change needed to switch. To use `qwen2.5:7b`:

```bash
export OLLAMA_MODEL=qwen2.5:7b
docker compose --profile gpu up -d --scale ollama=0 ollama-gpu
# Note the host: ollama is scaled to 0 above, so the MCP must point at the
# ollama-gpu service by name instead — http://ollama:11434 would resolve to
# nothing.
claude mcp add --transport stdio ollama-mcp --scope project \
  --env OLLAMA_HOST=http://ollama-gpu:11434 --env OLLAMA_MODEL=qwen2.5:7b \
  -- node tools/ollama-mcp/dist/index.js
```

The CPU-only default (`ollama` service, no GPU profile) is sized for
`llama3.2:3b`'s footprint (`docker-compose.yml`'s `deploy.resources.limits.memory: 8g`)
— overriding to a meaningfully larger model on that (non-GPU) service without
also reviewing that limit risks an OOM under load.

## Build and run

```bash
cd tools/ollama-mcp
npm install
npm run build     # compiles src/ -> dist/ via tsc
npm test           # compiles, then runs the node:test unit tests in dist/
npm start          # runs dist/index.js over stdio
```

For local development without a full reinstall loop, `npx tsc --noEmit` type-checks
without emitting.

## Register with Claude Code

Project scope (shared via `.mcp.json`, checked into the repo):

```bash
claude mcp add --transport stdio ollama-mcp --scope project \
  --env OLLAMA_HOST=http://ollama:11434 --env OLLAMA_MODEL=llama3.2:3b \
  -- node tools/ollama-mcp/dist/index.js
```

Or by hand in `.mcp.json` at the repo root:

```json
{
  "mcpServers": {
    "ollama-mcp": {
      "command": "node",
      "args": ["tools/ollama-mcp/dist/index.js"],
      "env": {
        "OLLAMA_HOST": "http://ollama:11434",
        "OLLAMA_MODEL": "llama3.2:3b"
      }
    }
  }
}
```

Run `npm install && npm run build` in `tools/ollama-mcp/` first so
`dist/index.js` exists — Claude Code spawns the compiled server directly, it
does not build it for you.

After registering, run `/mcp` inside Claude Code to confirm `ollama-mcp` is
connected, then try the `ping` and `health` tools, followed by
`summarize_file`/`extract`/`classify` against a real file once the `ollama`
sidecar is up and healthy.

### Enabling/disabling the offload

This server is registered at **project scope** via `.mcp.json`, which is
checked into the repo — so it's on by default for anyone who clones this repo
and trusts its project MCP config (Claude Code will prompt to approve
project-scoped servers from an unfamiliar repo on first use **in an
interactive TTY session** — see "Headless/unattended trust behavior" below for
the `-p`/headless exception, where no prompt occurs at all).

To disable it for everyone who uses this repo (edits the tracked `.mcp.json`
in your working tree — this is a shared-file change, not a personal one; it
will show up in `git status` and you should be deliberate about whether/when
to commit it):

- Remove (or comment out) the `ollama-mcp` entry from `.mcp.json`, or
- Run `claude mcp remove ollama-mcp --scope project`.

To disable it only for yourself, without touching the shared `.mcp.json` at
all, use local scope instead: `claude mcp remove ollama-mcp --scope local`
records the removal in your personal, untracked Claude Code config, leaving
`.mcp.json` and everyone else's setup untouched.

Either way, no change to `settings.shared.json` is needed: the
`mcp__ollama-mcp__*` allowlist entries there just grant permissions for tools
that a removed/absent server will never expose, so leaving them in place is
harmless. Re-enable by restoring the `.mcp.json` entry (or re-running
`claude mcp add`, see above) — the allowlist already covers it.

### Allowlist trust scope (cross-project caveat)

The `mcp__ollama-mcp__*` entries in `settings.shared.json` (repo root) are
merged into your *global* `~/.claude/settings.json` by `install.sh`, and they
match purely on MCP server name + tool name — they carry no binding to this
repo or this implementation. That means the auto-approval applies in **every
project you open**, not just this one: if some other, unrelated project
registers its own MCP server also named `ollama-mcp` exposing tools also named
`ping`/`health`/`summarize_file`/`extract`/`classify`, calls to that server
would be silently auto-approved too, with no guarantee it has this server's
path-confinement or local-only-egress properties. Be aware of this before
opening an unfamiliar repo that defines its own project-scoped `.mcp.json`.

### Headless/unattended trust behavior (claude-1bz)

`tools/run-overnight.sh` runs unattended `claude -p ...` loops with no human
present to answer an interactive "do you trust this folder / this project's
`.mcp.json`?" prompt. `claude-1bz` verified empirically what happens to this
server's registration in that situation, on a **fresh checkout that had never
been opened by Claude Code before** (a `git worktree`, built via
`npm install && npm run build` per the Build and run section above, with a
project path absent from `~/.claude.json`'s `projects` map — i.e. genuinely
untrusted).

**Finding: headless/`-p` mode silently auto-connects the project's
`.mcp.json` servers — it does not fail closed.** Both of the following were
tested and both connected `ollama-mcp` with zero prompts:

- `claude -p "..." --permission-mode auto --max-turns 1` (this repo's
  `run-overnight.sh` default)
- `claude -p "..." --max-turns 1` (no permission-mode flag at all — headless
  mode's own default, `acceptEdits`)

In both cases the `stream-json` `system`/`init` event reported
`{"name":"ollama-mcp","status":"connected"}` and the session's tool list
included the full `mcp__ollama-mcp__*` set
(`ping`/`health`/`summarize_file`/`extract`/`classify`), all usable
immediately, with no trust dialog shown and no interactive step blocking or
skipping a tool grant. Notably, `~/.claude.json` also never gained a `projects` entry
for the scratch checkout's path at all — this isn't "an approval got silently
recorded"; the project-trust gate that the interactive TTY normally enforces
appears not to be consulted for `.mcp.json` loading in `-p` mode at all.

This matches Claude Code's documented and independently-reported behavior:
non-interactive/headless mode has no path to render an interactive
trust/onboarding dialog, so it bypasses the check rather than defaulting to
deny — see the [headless-mode
docs](https://code.claude.com/docs/en/headless) (`--bare` exists specifically
to *not* auto-discover `.mcp.json`/hooks/skills at all) and
[anthropics/claude-code#5307](https://github.com/anthropics/claude-code/issues/5307)
("MCP Enablement Dialog Bypassed in Bypass Permission Mode").

**Risk:** every fresh checkout of this repo that gets run through
`run-overnight.sh` (or any other headless `claude -p` invocation) will spawn
`node tools/ollama-mcp/dist/index.js` automatically, with no human ever
exercising a trust decision over it — the committed `.mcp.json` is the only
gate, and CI/overnight-loop checkouts don't discriminate between "this repo's
own tooling" and "an unreviewed process execution declared by whoever last
touched `.mcp.json`." For *this* repo's own `ollama-mcp` server that's a
reviewed, path-confined, local-only-egress process (see above), so the
practical exposure today is low — but the mechanism itself would auto-run
*any* command a `.mcp.json` in this position of trust declared, reviewed or
not.

**Built in `claude-9hl`: hash-diff pre-trust gate, not `--bare`.** Two
candidates were on the table — a startup hash-diff check in
`run-overnight.sh`, or `--bare` + explicit `--mcp-config` so headless runs
never auto-discover the working tree's `.mcp.json` at all. `--bare` was
investigated first (it's structurally stronger, per the original
recommendation here) and rejected: per [Claude Code's skills
docs](https://code.claude.com/docs/en/skills) and [headless-mode
docs](https://code.claude.com/docs/en/headless), "custom commands have been
merged into skills," and `--bare` explicitly skips auto-discovery of
**hooks, skills, plugins, MCP servers, auto memory, and CLAUDE.md** — with no
equivalent to `--mcp-config` for pinning an explicit skill/command set (only
`--plugin-dir`, which would mean repackaging `/build-next` itself, its
specialist subagents, and this repo's whole `.claude/` layout as a plugin —
well beyond this bead's scope). `run-overnight.sh`'s entire reason to exist
is launching `claude -p "/build-next --unattended"`; `/build-next` is a
project skill (`commands/build-next.md`), so `--bare` would silently break
the very command the overnight loop runs, in addition to closing the
`.mcp.json` hole. Falling back to the documented alternative:

- **`mcp_trust_gate()` in `tools/run-overnight.sh`** computes the working
  tree's `.mcp.json` sha256 and compares it against a committed
  `.mcp.json.trusted-sha256` (repo root — currently trusting this repo's own
  `ollama-mcp` entry). No `.mcp.json` present → nothing to gate, launches
  proceed as before.
- **The comparison is not bytes-only.** An earlier version of this gate only
  compared file contents, which is self-computable by the very unattended
  agent the gate exists to constrain: `/build-next` runs headlessly *with git
  commit access inside the exact workdir being gated*, so nothing stopped it
  (or a prompt-injected tool call from an already-connected MCP server) from
  rewriting `.mcp.json`, regenerating a matching hash into
  `.mcp.json.trusted-sha256`, and never committing either file — a
  bytes-only gate would have trusted that. (This was concretely
  demonstrated during review: `.mcp.json.trusted-sha256` was an *untracked*
  file in this repo when the bytes-only version shipped, and the gate passed
  anyway.) The gate now additionally requires, for **both**
  `.mcp.json` and `.mcp.json.trusted-sha256`:
  - `git ls-files --error-unmatch` succeeds (the path is actually tracked by
    git), and
  - `git diff --quiet HEAD --` is clean (no staged or unstaged
    modifications relative to the last commit).

  Only once both files are genuinely tracked, clean, and hash-matching does
  the gate pass.
- **Symlinks are rejected outright.** A committed, *clean* symlink would
  otherwise still pass the tracked+clean check above: git records a
  symlink's target *string* as its blob and never dereferences it, so
  `git diff --quiet HEAD` reports clean regardless of what the link
  currently points at — while `sha256sum` *does* follow the link and hashes
  whatever that is. One commit swapping `.mcp.json` and/or
  `.mcp.json.trusted-sha256` for a symlink into a writable location would
  let an agent rewrite the pointed-to content indefinitely afterward with
  **zero further commits and zero git-diff signal** — stealthier than the
  residual limitation below, which at least implies a fresh auditable commit
  per rewrite. The gate now checks `[ -L "$mcp_json" ] || [ -L "$trust_file" ]`
  and refuses if either path is a symlink, closing this specific vector.
- The gate runs **before every headless `claude -p` launch** in the script:
  the startup preflight probe, the per-worker baseline check, every
  `/build-next` iteration (re-checked each loop, since a completed bead could
  itself have modified `.mcp.json` — committed or not), and the end-of-night
  `/analyze-telemetry` pass.
- **To (re)trust a legitimate `.mcp.json` change:** review the diff, then
  `sha256sum .mcp.json | awk '{print $1}' > .mcp.json.trusted-sha256 && git add .mcp.json .mcp.json.trusted-sha256 && git commit`.
  This is a deliberate, reviewed commit — the same bar as any other change to
  a shared, trust-bearing file.
- **On mismatch/missing/untracked/dirty trust pair:** fails loud. The
  top-level check aborts the whole run before the preflight probe ever
  launches `claude`; the per-worker/per-iteration checks halt that worker
  with a logged reason (`worker-N.log` and the run summary) rather than
  proceeding.
- **Escape hatch:** `SKIP_MCP_TRUST_CHECK=1` bypasses the gate entirely — not
  recommended, since it reintroduces the exact risk this section describes;
  it exists for debugging only, and only with a `.mcp.json` an operator
  already trusts.
- **Residual limitation, recorded honestly rather than implied-closed:** with
  the symlink vector above closed, every remaining way to fool this gate
  requires its own fresh, auditable commit — requiring a genuine git commit
  stops *accidental* drift (a stray hand-edit, a bad merge) and
  *uncommitted* mid-run tampering, but it does **not** stop an agent that
  already has commit rights in the workdir from deliberately committing its
  own rewritten `.mcp.json` plus a matching, freshly-committed trust file
  — `/build-next`'s unattended mode explicitly commits per completed task,
  so this is a real, not merely theoretical, gap. A complete fix needs a
  trust anchor the overnight agent cannot mutate: a signed tag, a commit on
  a protected branch the agent can't push to, or a value held outside the
  workdir under different credentials (e.g. checked by the *human*
  triggering the run, or fetched from a store the overnight process's own
  git identity has no write access to). That out-of-band anchor is a larger
  change than this bead's scope and is not built here.
- Covered by `tests/test_run_overnight.sh` (`test_mcp_gate_*`), which
  exercises the gate against fabricated git repos (committed-and-clean,
  untracked-trust-file, uncommitted-rewrite/"self-reauthorization",
  symlinked-`.mcp.json`, and genuine-hash-mismatch cases) without launching
  `claude`, plus a regression
  test that runs the gate against this repo's own real `.mcp.json` /
  `.mcp.json.trusted-sha256` so a hash/file drift here fails at test time
  instead of silently aborting an overnight run at 2am.

## Follow-ups not built in this bead

- **Glob support.** The design doc mentioned "a file path / glob"; this bead
  ships single-path input only (plus an optional line range) as the MVP —
  Node 20 (this repo's floor, see `engines` above) has no built-in
  `fs.promises.glob` (that lands in Node 22), and a dependency-free glob
  implementation was judged out of scope for this bead. A follow-up bead could
  add either a small glob dependency or bump the Node floor.
- **Chunking for oversized files.** Content beyond `MAX_INPUT_CHARS` (12,000
  chars) is truncated, not chunked-and-summarized-per-chunk. Truncation is
  reported (`truncated`/`truncatedChars`) rather than silent, but a genuinely
  large file only gets a summary of its first ~12,000 characters. A follow-up
  could add map-reduce-style chunking for `summarize_file` specifically.

Schema validation + retry-on-malformed-JSON for `extract`/`classify`/
`summarize_file` was tracked as `claude-r30.5` and is now built — see
[Structured-output validation](#structured-output-validation) above.
