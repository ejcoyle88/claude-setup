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
  `{ summary, truncated, truncatedChars?, chunked, chunkCount? }`. `focus`
  optionally steers what the summary emphasizes (e.g.
  `"security-relevant changes"`). Content over 12,000 characters is
  map-reduced across chunks rather than truncated — see
  [Chunking for oversized files](#chunking-for-oversized-files).
- **`extract(path, schema, startLine?, endLine?)`** — reads `path` (same
  slicing as above) and asks Ollama to return JSON matching the caller-supplied
  `schema` (a JSON-Schema-like object, e.g.
  `{ type: "object", properties: { title: { type: "string" } }, required: ["title"] }`),
  passed straight through to Ollama's structured-output `format`. Returns
  `{ data, truncated, truncatedChars?, chunked, chunkCount? }`. The response
  is validated against `schema` (required fields present, declared types
  match — see [Structured-output validation](#structured-output-validation))
  rather than just checked for valid JSON; on a parse or validation failure
  the generation is retried once with the identical prompt before giving up.
  If the retry also fails, this returns `isError: true` with a message
  describing what was wrong, never a partially-parsed or best-guess result.
  Content over 12,000 characters is map-reduced across chunks rather than
  truncated — see [Chunking for oversized files](#chunking-for-oversized-files).

  `path` may also be a **glob pattern** — anything containing `*`, `?`, or
  `[` — matching several files at once (bead claude-1nx): `*` (any run of
  characters within one path segment), `?` (exactly one character),
  `[...]`/`[!...]` (POSIX-style character classes/negation), and `**` (zero
  or more whole path segments, e.g. `src/**/*.ts`); no brace expansion
  (`{a,b}`). When `path` is a glob pattern, `startLine`/`endLine` and (for
  `summarize_file`) `focus` apply identically to every matched file, and the
  result shape changes to `{ results: [{ path, summary|data, truncated,
  truncatedChars? } | { path, error }, ...] }` instead of a single top-level
  `summary`/`data` — one file failing (unreadable, fails workspace
  confinement, model generation failure, ...) becomes that file's own
  `{ path, error }` entry rather than aborting the whole call; the overall
  tool response is only `isError: true` if *every* matched file failed. A
  pattern matching more than 20 files is rejected outright with
  `isError: true` (narrow the pattern or issue several calls) rather than
  silently processing only the first 20 or turning one tool call into an
  unbounded number of sequential Ollama generate calls. This repo's Node
  floor (20, see `engines` below) predates `fs.promises.glob` (Node 22), and
  a third-party glob dependency was judged unnecessary for this repo's
  minimal, POSIX-glob-subset needs — see `matchGlob`'s doc comment in
  `src/index.ts` for the (dependency-free) matching implementation.

  **Compounding with chunking:** matches are processed sequentially, and
  since `claude-xg9` each matched file can itself cost up to 7 sequential
  generate calls if it's large enough to chunk (see
  [Chunking for oversized files](#chunking-for-oversized-files)) instead of
  the 1 it cost before that bead — so a single glob-pattern call's worst case
  is up to 20 × 7 = 140 sequential generate calls, several times slower than
  before chunking existed, with no caller-facing way to opt out of chunking
  for a glob batch. This is documented, not (yet) mitigated further — see
  `MAX_GLOB_MATCHES`'s doc comment in `src/index.ts` for the reasoning behind
  leaving the 20-file cap as-is despite this.
- **`classify(pathOrText, labels, isPath?, startLine?, endLine?)`** — classifies
  content into exactly one of `labels` (min 2), returning `{ label, truncated,
  truncatedChars?, chunked, chunkCount? }`. Set `isPath: true` to have this
  server read `pathOrText` as a file path (recommended for anything beyond a
  short snippet, so the content stays out of Claude's context); when `isPath`
  is false/omitted, `pathOrText` is treated as literal text and should stay
  short — passing bulk file content directly here defeats the point of this
  server, use `isPath: true` instead. `startLine`/`endLine` only apply when
  `isPath` is true. Content over 12,000 characters samples a bounded subset
  of chunks and majority-votes the label rather than truncating — see
  [Chunking for oversized files](#chunking-for-oversized-files).

All three offload tools:

- Read and fully cover up to 72,000 characters of file content
  (`MAX_CHUNKABLE_CHARS`, a chunking budget built from `MAX_INPUT_CHARS` — a
  crude proxy for staying well inside a small model's context window —
  multiplied by up to 6 chunks); content beyond that falls back to a hard
  truncation at 12,000 characters (`MAX_INPUT_CHARS`), reported via
  `truncated`/`truncatedChars` and never silent. See
  [Chunking for oversized files](#chunking-for-oversized-files) for the full
  picture. The read itself is bounded too: files over 8MiB on disk are
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
  shorter 30s timeout, so a single *unchunked* tool call's worst-case latency
  before returning `isError: true` is ~90s, not 60s (a chunked call's
  worst-case latency is correspondingly longer — see
  [Chunking for oversized files](#chunking-for-oversized-files)).

### Chunking for oversized files

`claude-xg9` replaced claude-r30.4's original hard-truncation-at-12,000-
characters behavior with map-reduce chunking for content that doesn't fit in
one request, keeping truncation only as a last resort for content too large
even to chunk:

- Content up to **12,000 characters** (`MAX_INPUT_CHARS`, one chunk's budget)
  is sent to Ollama in a single request, exactly as before this bead —
  `chunked: false`, `chunkCount: 1`.
- Content from 12,001 up to **72,000 characters** (`MAX_CHUNKABLE_CHARS` =
  `MAX_INPUT_CHARS` × `MAX_CHUNK_COUNT`, 6 chunks) is split into
  `MAX_INPUT_CHARS`-sized chunks (never splitting a UTF-16 surrogate pair —
  see `splitIntoChunks`'s doc comment in `src/index.ts`) and map-reduced:
  - **`summarize_file`**: each chunk is summarized independently (told it's
    "part N of M of a larger file"), then the chunk summaries themselves are
    summarized into one final, cohesive summary — kept comparable in
    size/shape to a single-shot summary rather than growing with the chunk
    count.
  - **`extract`**: each chunk is extracted against the same caller-supplied
    `schema` independently, then merged: array-typed fields union across
    chunks (duplicates removed, first-occurrence order kept); object-typed
    fields merge recursively field-by-field; every other (scalar) field
    takes the first chunk with a non-null value. See
    `mergeExtractedChunks`'s doc comment in `src/index.ts` for the full
    policy and a known limitation (a `required` field's real value may only
    live in one chunk, and a small model may hallucinate a placeholder for
    the others rather than fail validation).
  - **`classify`**: unlike the other two, this does *not* run every chunk
    through the model — a single classification label is usually
    well-determined by a representative sample, so this samples up to 3
    evenly-spaced chunks (`CLASSIFY_MAX_SAMPLED_CHUNKS`) and majority-votes
    the label (`majorityLabel`), bounding a chunked classify call to at most
    3 generate calls regardless of how many chunks the content split into.
  - The result reports `chunked: true` and `chunkCount` (the number of
    chunks actually sent to the model — for `classify`, the sampled count,
    not the total chunk count).
- Content beyond 72,000 characters is more than chunking is willing to
  cover — this server falls back to the pre-chunking behavior: a hard
  truncation at 12,000 characters, reported via `truncated`/`truncatedChars`
  exactly as before this bead, with `chunked: false`.

`MAX_CHUNK_COUNT` (6) exists because each chunk pays its own full
`generateStructured` round trip — up to ~90s worst case on this CPU-only
sidecar with a retry (see `RETRY_TIMEOUT_MS`'s doc comment) — plus one more
call for `summarize_file`/`extract`'s reduce step; 6 bounds a single chunked
tool call to at most 7 sequential generate calls (mid-single-digit minutes
worst case) rather than letting a pathologically large file grow that
latency without bound. This latency estimate has not been measured against a
live sidecar for an actual chunked call; the merge/vote policies and the
chunk-splitting/chunk-cap-fallback logic are covered by
`src/chunking.test.ts` against a mocked `fetchImpl`, not a real model — see
this file's Follow-ups section.

**Prompt-injection risk in `summarize_file`'s reduce step.** Each part
summary above is model output derived from untrusted file content, and the
reduce step feeds those part summaries back into a *new* `generateStructured`
call to produce the final summary. A file crafted so that one chunk's own
summary contains embedded directives could, in principle, get those
directives "obeyed" by the reduce-step model rather than merely described.
The reduce prompt mitigates this by explicitly labeling the enclosed part
summaries as inert data to synthesize, not instructions to follow — but this
is a prompt-level instruction, not a guarantee, and a sufficiently motivated
or unusual model response could still fail to honor it. Treat a chunked
`summarize_file` result at the same trust level as any other model output,
not as sanitized input. `extract`/`classify`'s chunked paths don't have this
exposure: their merge/vote steps (`mergeExtractedChunks`/`majorityLabel`)
combine per-chunk results programmatically, without feeding chunk output
back into another generate call.

**All-or-nothing chunk failure.** The per-chunk map loops in
`summarizeContent`/`extractContent`/`classifyContent` are sequential with no
checkpointing: if any one chunk's generate call fails, the whole tool call
returns `isError: true` and discards every already-completed chunk's result
— potentially several minutes of real inference — with no way to resume
partway through. The one failure mode in that path that's plausibly
transient — the cross-process generate lock reporting "busy" because a
different `ollama-mcp` session currently holds it (see
[Concurrent-session contention](#concurrent-session-contention-claude-6ll))
— gets one bounded, ~5s-delayed retry of that same chunk
(`generateStructuredWithLockBusyRetry`) before giving up, so a short-lived
contention window mid-sequence doesn't necessarily waste the whole
operation's completed work. Any other failure (network/timeout, a
still-malformed response after `generateStructured`'s own built-in retry, or
lock contention that persists past this one extra retry) still discards the
whole chunked operation with no resume — a caller that hits this must re-run
the whole tool call from scratch.

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
This same per-file check applies to every file a glob pattern matches, not
just a plain single path — glob expansion only narrows candidates by
listing directories under `WORKSPACE_ROOT` (so a `../` segment can never
even produce a match), but a matched symlink pointing outside the root is
still individually rejected (its own `{ path, error }` entry, not silently
dropped from the result) exactly like a literal path would be.
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

### `dist/` build provenance — verify before trusting

`dist/index.js` is the actual binary `.mcp.json` auto-launches
(`node tools/ollama-mcp/dist/index.js`), but `dist/` is git-ignored (see
`tools/ollama-mcp/.gitignore`) and deliberately not committed — only `src/`
goes through code review and shows up in `git diff`. That means **trusting
this repo's `.mcp.json` only reviews `src/`; it says nothing about whether
the `dist/index.js` sitting on disk in your checkout was actually produced
from that reviewed `src/`.** A stale build left over from an earlier commit,
a local edit made directly to a `.js` file under `dist/`, or a `tsc` run
against a compromised/tampered transitive dependency would all execute
automatically the next time this server connects, with no diff ever showing
it.

Before trusting `ollama-mcp` in a new checkout (or after pulling changes that
touch `tools/ollama-mcp/src/`), rebuild and verify:

```bash
cd tools/ollama-mcp
npm install
npm run build     # compiles the currently checked-out src/ -> dist/
npm run verify     # rebuilds src/ into a scratch dir and sha256-diffs it against dist/
```

`npm run verify` (`scripts/verify-dist.mjs`, dependency-free — only Node
built-ins) runs a second, independent `tsc` build into a temporary directory
and compares every compiled `.js` file's sha256 against what's currently in
`dist/`. It exits non-zero and prints exactly which files are missing, extra,
or content-mismatched if `dist/` doesn't match a fresh build of `src/` — or
if `dist/` doesn't exist at all. A clean `npm run verify` means "what
`.mcp.json` would execute right now is exactly what this checkout's reviewed
`src/` produces," which is the actual property worth checking, not merely
"`dist/` is newer than `src/` by file mtime" (mtimes are trivially spoofable
and don't prove content matches).

This is a manual, explicit check — deliberately **not** wired into
`postinstall` or CI. There's no CI workflow that touches
`tools/ollama-mcp/` today, this is a low-value internal dev tool (not a
production supply chain), and running an extra full `tsc` pass on every
`npm install` would surprise anyone who just wants dependencies installed.
Run `npm run verify` yourself as a deliberate step — right after
`npm run build` in a fresh checkout, and again any time you're about to trust
`.mcp.json` in a checkout where `dist/` predates a `src/` change you haven't
personally rebuilt from.

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

### Concurrent-session contention (claude-6ll)

Because this server is registered at **project scope** (see above), every
Claude Code session opened against this repo spawns its own independent
`node dist/index.js` process — and every one of those processes talks to the
*same single* `OLLAMA_HOST` sidecar (one CPU-only `llama3.2:3b` instance, no
built-in request queue/pooling coordination between ollama-mcp processes).
`claude-6ll` benchmarked how much concurrent `/api/generate` load that shared
sidecar actually sustains, using
[`benchmark-concurrency.mjs`](./benchmark-concurrency.mjs) (fires N concurrent
`/api/generate` calls directly at the live sidecar, for increasing N, and times
each). A post-`claude-6ll` review flagged that the original run only ever sent
a short, fixed, few-hundred-character prompt — far below `MAX_INPUT_CHARS`
(12,000 chars) that a real `summarize_file`/`extract`/`classify` call against
a large (truncated) file can actually send — and ran concurrency levels
back-to-back with no gap, letting a prior level's stragglers (see "Residual
gap" below) bleed into the next level's numbers. The script now sweeps
`PROMPT_CHAR_SIZES` (default `400,12000` — a short best-case prompt and one at
`MAX_INPUT_CHARS`) and sleeps `COOLDOWN_MS` (default `GENERATE_TIMEOUT_MS +
5s`) between every consecutive run so a straggler has time to actually finish
before the next run starts. Run it yourself:
`node tools/ollama-mcp/benchmark-concurrency.mjs` (a full default sweep takes
roughly 15 minutes, most of it cooldown).

**Measured, in this sandbox** (CPU-only, `deploy.resources.limits.memory: 8g`
on a host with well under that much physical RAM actually free — see
`.devcontainer/docker-compose.yml`'s `ollama` service and
`.devcontainer/Dockerfile.ollama`/`ollama-entrypoint.sh` for the container's
setup; neither sets `OLLAMA_NUM_PARALLEL`/`OLLAMA_MAX_QUEUE`, so Ollama's own
defaults apply — auto-selected `OLLAMA_NUM_PARALLEL` based on available
memory, `OLLAMA_MAX_QUEUE` 512):

**Short prompt (~400 chars, matches the original `claude-6ll` run):**

| Concurrency (N) | Successes | Notes |
| --- | --- | --- |
| 1 | 1/1 | ~28.3s single-call latency — already ~47% of `GENERATE_TIMEOUT_MS` (60s) on its own. |
| 2 | BENCHMARK_SHORT_2 | BENCHMARK_SHORT_2_NOTE |
| 4 | BENCHMARK_SHORT_4 | BENCHMARK_SHORT_4_NOTE |
| 8 | BENCHMARK_SHORT_8 | BENCHMARK_SHORT_8_NOTE |

**Near-cap prompt (~12,000 chars, `MAX_INPUT_CHARS` — the realistic worst
case for a large truncated file):**

| Concurrency (N) | Successes | Notes |
| --- | --- | --- |
| 1 | 0/1 | **Even a single, uncontended call already times out at 60s** — a near-cap-size prompt alone exceeds `GENERATE_TIMEOUT_MS` on this CPU-only sidecar, before any concurrency is involved at all. |
| 2 | BENCHMARK_LARGE_2 | BENCHMARK_LARGE_2_NOTE |
| 4 | BENCHMARK_LARGE_4 | BENCHMARK_LARGE_4_NOTE |
| 8 | BENCHMARK_LARGE_8 | BENCHMARK_LARGE_8_NOTE |

**Decision: this needed a mitigation, not just a documented limitation.** The
bead's own criterion was whether contention shows up "at a concurrency level
that's realistically reachable (e.g. 2-3 concurrent Claude Code sessions each
doing one offload call)" — the N=2 row above *is* that scenario, and it
already produces a hard failure (`isError: true`, generic 60s timeout) for one
of the two sessions. Recording that as an accepted limitation without changing
anything would leave a second concurrent session silently eating a full 60s
wait for a failure it could have been told about immediately.

**What's implemented (`src/index.ts`, `acquireGenerateLock`/
`releaseGenerateLock`/`callOllamaGenerate`):** a cross-process, fail-fast
advisory lock, keyed off `OLLAMA_HOST` and stored as a file in `tmpdir()`
(shared by every ollama-mcp process on this host, unlike an in-process
semaphore, which can't coordinate across the separate OS processes each
Claude Code session spawns). Every `/api/generate` call — both
`generateStructured`'s first attempt and its retry — acquires this lock
first:

- If uncontended, it acquires immediately (writing its own pid, acquisition
  time, and a fresh per-acquisition `token` into the lock file, mode `0o600`),
  makes the real call, and releases the lock afterward (success or failure
  either way) — release re-reads the file first and only deletes it if its
  `token` still matches this acquisition's own, so a late release from a
  holder that's since been reclaimed as stale can never delete a *different*,
  currently-legitimate holder's lock (see below).
- If another ollama-mcp process currently holds it, the call **fails
  immediately** with a clear "sidecar is busy, retry shortly" error — it does
  **not** wait in a queue. Given the ~38.8s single-call baseline above (~65%
  of the 60s budget), queueing a second call behind a first would frequently
  blow through `GENERATE_TIMEOUT_MS` before the second call had done any real
  work anyway; failing fast turns an opaque, minute-long timeout into an
  immediate, actionable signal instead.
- A held lock is treated as abandoned and reclaimed if *either* its recorded
  pid is no longer alive (checked via `process.kill(pid, 0)`, `ESRCH`
  treated as dead regardless of the lock's recorded age — a dead holder can
  never release its own lock, so a merely-young timestamp shouldn't be
  trusted over that) or it's older than `GENERATE_LOCK_STALE_MS` (3 minutes —
  comfortably past the ~90s worst case a legitimate, still-alive call can
  take with its retry, see `RETRY_TIMEOUT_MS`'s doc comment). Either path lets
  one killed (or definitely-dead) holder's process be reclaimed without
  wedging every other session behind a lock nobody will ever release.
- **Lock-ownership fix (post-`claude-6ll` review):** the first shipped
  version of this lock had `releaseGenerateLock` unconditionally `unlink` the
  lock path with no check that the file still belonged to the releasing
  call — a holder whose call ran past `GENERATE_LOCK_STALE_MS` without
  crashing (e.g. slow under memory pressure) could have its lock reclaimed by
  a second caller, finish, and then delete *that second caller's* still-live
  lock in its own `finally`, letting a third caller acquire immediately and
  run concurrently with the second — silently defeating the mutual exclusion
  this lock exists to provide. Every acquisition now carries a random
  `token`, and release only deletes the file if the token on disk still
  matches its own — see `acquireGenerateLock`/`releaseGenerateLock`'s doc
  comments in `src/index.ts` and the regression test in `src/lock.test.ts`
  ("a late release from a reclaimed-out holder does not delete the current
  holder's lock") for the exact scenario this closes.
- Any unexpected lock-mechanics failure (unwritable `tmpdir()`, etc.)
  degrades to "proceed without coordination" (today's pre-`claude-6ll`
  behavior) rather than breaking every generate call — this lock is a
  best-effort mitigation for measured contention, not a correctness boundary
  the tools depend on to function at all.

Verified end-to-end (not just unit-level): two separate `node dist/index.js`
processes, each driven through the real MCP client SDK exactly as two
concurrent Claude Code sessions would, both calling `summarize_file` at the
same instant — one lost the race and returned the busy error in ~20ms, the
other proceeded uncontended and completed normally in ~19s.

**Residual gap, by design, not closed by this mitigation:** the lock tracks
this *local* bookkeeping, not Ollama's actual internal state. If a caller's
client-side `AbortController` fires at `GENERATE_TIMEOUT_MS` and gives up, this
releases the lock even though Ollama may still be processing that abandoned
request server-side for some time afterward — a freshly-acquiring caller can
still land on a sidecar that's still busy with the abandoned request during
that window. Closing that fully would require either a lower-level integration
with Ollama's own queue/worker state or accepting a slower fail-fast (waiting
out a supposedly-released lock's likely tail), neither of which was judged
worth the added complexity for a CPU-only local dev sidecar — flagged here for
awareness, not proposed as a follow-up bead.

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
- **Residual limitation as `claude-9hl` shipped it:** with the symlink
  vector above closed, every remaining way to fool the in-repo gate alone
  requires its own fresh, auditable commit — requiring a genuine git commit
  stops *accidental* drift (a stray hand-edit, a bad merge) and
  *uncommitted* mid-run tampering, but it does **not** stop an agent that
  already has commit rights in the workdir from deliberately committing its
  own rewritten `.mcp.json` plus a matching, freshly-committed trust file
  — `/build-next`'s unattended mode explicitly commits per completed task,
  so this was a real, not merely theoretical, gap.

**Closed (opt-in), `claude-o7u`: an out-of-band external trust anchor.**
`claude-9hl` named three candidate fixes for the gap above: a signed git
tag, a commit on a protected branch the overnight identity can't push to, or
a value held outside the workdir under different credentials. All three
were re-examined against what this sandbox can actually provision:

- **Signed tag/commit — investigated and rejected for this repo.** Every
  commit in this repo is already GPG-signed (`git log --show-signature`),
  using a key this same overnight identity's environment holds with no
  passphrase prompt (`gpg --list-secret-keys` finds the secret key,
  unlocked). Verifying `git verify-tag`/`git verify-commit` against that
  same key would be trivially self-satisfiable — the agent can just make
  another signed tag. A signed-tag anchor only works if the signing key is
  held somewhere the overnight identity genuinely cannot reach (a separate
  keyring, a human's local machine, an HSM); none of that is provisioned
  here, and faking it with the same ambient key would be worse than not
  building it — a false sense of closure.
- **Protected branch — not testable without real server-side enforcement.**
  "Protected" is a property a git *server* (GitHub/GitLab branch protection)
  enforces against push credentials; a plain local repo has no such
  authority, and standing up that infrastructure (and a second, restricted
  credential) is out of scope for this bead per its own sizing note.
- **Out-of-workdir value under different permissions — built.** This is the
  one anchor mechanism enforceable purely with what's already in the
  sandbox: filesystem permissions and a UID (`node`, uid 1000) that this
  repo's own `sudo -l` shows has **no general root access** (only a single
  NOPASSWD entry for `/usr/local/bin/init-firewall.sh`) — a real, narrow
  privilege boundary already in place, not one invented for this bead.

  `MCP_EXTERNAL_TRUST_ANCHOR` (env var, see `tools/run-overnight.sh`'s
  header comment) names an absolute path to a file holding just the trusted
  sha256, provisioned by an operator/build step with write access this
  identity lacks (e.g. `sudo install -o root -g root -m 0444 ...`). When
  set, `mcp_trust_gate()` additionally requires the anchor to:
  - exist as a plain, non-symlink regular file;
  - resolve to a path **outside** `$workdir` (so no `git add`/`commit` run
    inside the repo being gated can ever reach it — pointing the anchor at
    a path inside the repo would just be another file this identity can
    commit, which defeats the entire point, and the gate explicitly checks
    and refuses this);
  - be **unwritable by the identity running the script** — the anchor file
    itself, and *every* ancestor directory from its parent up to `/` (a
    writable immediate parent would let the file be deleted and recreated
    even if the file's own permissions were read-only; a writable
    grandparent-or-higher would let the whole anchor directory be renamed
    aside and replaced wholesale, so the walk doesn't stop at the immediate
    parent). The gate checks this directly with `[ -w ... ]` at every level
    rather than trusting that an operator configured permissions correctly:
    an anchor that turns out to be writable anywhere in that chain is
    **refused outright**, even if its current content happens to match,
    because a same-credential anchor provides none of the guarantee it
    exists for; and
  - sha256-match the working tree's actual `.mcp.json`.

  **Unset (the default):** the in-repo checks above still run exactly as
  `claude-9hl` shipped them, but the self-reauthorization gap is **not**
  closed — this mechanism cannot be provisioned with genuinely separate
  credentials from inside an unattended run itself; it requires a human or
  a privileged build step to create the anchor beforehand. `run-overnight.sh`
  logs a one-time warning at startup when it's unset, so this isn't a silent
  downgrade.

- **Residual limitation of the built mechanism, recorded honestly:** this
  closes the gap *when properly provisioned* — an anchor that is genuinely
  root-owned (or otherwise held by a different, unreachable identity) with
  restrictive permissions. It does **not** self-provision that separation;
  nothing in this sandbox can create a root-owned file without real root
  access, so the test suite (below) can only simulate the "unwritable"
  property via `chmod`, which the owning `node` user could technically
  reverse (`chmod u+w`) since `chmod` only checks file *ownership*, not
  current permission bits. In other words: the gate correctly *enforces*
  the boundary once it exists, but *creating* a boundary this identity
  truly cannot cross is an operational responsibility outside this script —
  document it, provision it in the container build or by the human
  triggering the run, and don't rely on `chmod`-only "protection" applied by
  the same identity that's supposed to be constrained by it.
- Covered by `tests/test_run_overnight.sh`: the original `test_mcp_gate_*`
  suite (committed-and-clean, untracked-trust-file, uncommitted-rewrite/
  "self-reauthorization", symlinked-`.mcp.json`, genuine-hash-mismatch, and a
  regression test against this repo's own real `.mcp.json` /
  `.mcp.json.trusted-sha256`), plus a new `test_external_anchor_*` suite
  covering the anchor missing/mismatched/symlinked/inside-workdir/writable-
  file/writable-parent-dir/writable-grandparent-dir cases (the writability
  check walks *every* ancestor directory up to `/`, not just the immediate
  parent — a writable grandparent-or-higher would otherwise let this
  identity rename the whole anchor directory aside and replace it wholesale)
  and `test_external_anchor_defeats_a_full_valid_self_committed_rewrite`,
  which performs a fully legitimate, clean, git-tracked, hash-matching
  commit of a rewritten `.mcp.json` (proving the in-repo layer alone would
  be fooled, reproducing `claude-9hl`'s documented gap as a control) and
  then shows the same rewrite is refused once an external anchor pinned to
  the prior, trusted hash is configured. Scoped claim: this demonstrates
  that a valid, clean, git-committed in-repo rewrite alone does not flip
  the decision when the anchor disagrees — it does **not** demonstrate that
  the anchor resists a same-UID attacker going one step further and
  directly rewriting the anchor file itself, which (per the residual
  limitation above) this sandbox cannot rule out without real separate
  credentials.

## Measured token savings

`claude-r30.7` drove real `summarize_file`/`extract`/`classify` calls against
the live `ollama` sidecar (via the actual MCP client SDK, not a simulation)
on real repo files, and compared the tokens that would otherwise enter
Claude's context against the tool call's actual round-trip cost — including
two real failures (an Ollama model-runner crash and an MCP-client timeout
footgun) hit live in that session. See
[`token-savings.md`](./token-savings.md) for the full numbers, what's
measured vs. estimated, and a recommendation on which task classes are worth
routing to ollama. Short version: classification and summarization of
files that stay within `MAX_INPUT_CHARS` without crashing the sidecar are
strongly net-positive (~90-94% token reduction, observed); small structured
extraction is net-positive but thinner once the `schema` argument's own cost
and retry risk are counted; large-file summarization that hits truncation on
a resource-constrained sidecar was, in that session, unreliable enough to
sometimes cost more than it saves.

## Follow-ups not built in this bead

Schema validation + retry-on-malformed-JSON for `extract`/`classify`/
`summarize_file` was tracked as `claude-r30.5` and is now built — see
[Structured-output validation](#structured-output-validation) above.

Chunking for oversized files (map-reduce for `summarize_file`/`extract`,
sample-and-vote for `classify`) was tracked as `claude-xg9` and is now built
— see [Chunking for oversized files](#chunking-for-oversized-files) above.
Left open by that bead:

- **No live-sidecar coverage of a chunked call.** `src/chunking.test.ts`
  covers the chunk-splitting logic and the map-reduce/merge/vote policies
  against a mocked `fetchImpl`, matching this repo's existing
  `generate.test.ts`/`glob.test.ts` conventions, but there's no live e2e test
  (mirroring `live-e2e.test.ts`'s single-call pattern) exercising an actual
  multi-chunk call against a real Ollama sidecar — a chunked call is several
  minutes of real inference latency per run, which didn't seem worth paying
  on every opted-in live-test run for behavior the mocked tests already
  cover at the orchestration level. Worth adding if a live sidecar becomes
  more routinely available in this repo's CI/dev environment.
- **`extract`'s per-chunk `required` fields.** Each chunk is extracted
  against the caller's exact `schema`, `required` fields included, even
  though a required field's real value may live in only one chunk — on the
  others, a small model may hallucinate a placeholder to satisfy the
  constraint rather than fail validation, and the current "first non-null
  wins" merge policy can't distinguish a real value from a hallucinated one.
  A follow-up could relax `required` for the per-chunk map calls (validating
  it only against the final merged result instead).
- **No empirical latency data for a chunked call.** `MAX_CHUNK_COUNT` (6) is
  sized from the same CPU-only-sidecar per-call latency estimate
  (`benchmark-concurrency.mjs`) claude-lp5 used for the unchunked worst case,
  not from a chunked call actually measured end-to-end against a live
  sidecar.
