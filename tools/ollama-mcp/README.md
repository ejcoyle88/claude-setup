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
  `{ data, truncated, truncatedChars? }`. Best-effort: on a small model the
  output can still fail to match `schema` or fail to parse as JSON at all — in
  either case this returns `isError: true` with a clear message rather than
  silently returning garbage. (Schema *validation* + retry-on-malformed-JSON
  is tracked separately as `claude-r30.5` — deliberately not built here.)
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
- Use a 60s timeout on the Ollama request itself (`health`'s reachability
  probe uses a much shorter 3s timeout — generation is slower).

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
- **Schema validation + malformed-JSON retry for `extract`.** Already tracked
  as `claude-r30.5`; this bead only detects and reports malformed/non-object
  JSON, it doesn't retry or validate against the caller's `schema`.
