# Measured token savings: ollama-mcp offload (claude-r30.7)

Spike for `claude-r30.7`. Goal: run real repo tasks through `summarize_file`/
`extract`/`classify` against the live `ollama` sidecar in this session, and
compare the tokens that would otherwise enter Claude's context against the
tokens the offloaded round trip actually costs — accounting for retries and
outright failures, not just the happy path.

## What's real here vs. what's estimated

Be precise about this, per the bead's own instruction:

- **Real, measured this session**: every "After" row below comes from an
  actual MCP round trip — a small Node script (`measure-tokens.mjs`,
  `measure-tokens-retry.mjs`, this directory) using
  `@modelcontextprotocol/sdk`'s `Client` + `StdioClientTransport` to spawn the
  real `dist/index.js` over stdio and call `summarize_file`/`extract`/
  `classify` exactly as Claude Code itself would, against the live `ollama`
  sidecar (`llama3.2:3b`, Ollama `0.31.1`) in this devcontainer. Wall-clock
  latency, `isError`, and result payloads are all real observed output, not
  simulated. Two real failures (see "Reliability" below) are also real,
  unprompted observations, not injected faults.
- **Estimated, clearly heuristic**: every "Before" row (what Claude's own
  context would have spent reading the file directly) is a `chars/4`
  token-count heuristic applied to real file contents — no tokenizer library
  (`tiktoken` or equivalent) was available in this sandbox (checked: neither
  a Python `tiktoken` module nor an npm `tiktoken` package was installed), so
  this is a documented approximation, not a measured Claude tokenizer count.
  Output-token estimates for what Claude's own equivalent summary/label/
  extraction would cost are likewise a heuristic, sized off the real,
  comparable output the offloaded call itself produced for that task (see
  each row's note).
- **Not attempted, and why**: driving this through a real `claude -p`
  invocation with `OTEL_ENABLED=1` and reading the delta back out of
  Prometheus/Loki was considered (`tools/run-overnight.sh`'s
  `OTEL_EXPORTER_OTLP_*` plumbing) and rejected for this spike specifically
  because `commands/analyze-telemetry.md` already documents the actual
  ceiling of that telemetry: "Claude Code's `/usage` per-session
  skill/subagent/MCP breakdown is NOT retrievable after the fact." The
  Prometheus/Loki pipeline records session-level cost and
  `claude_code_token_usage_tokens_total{type=...}` aggregates, not
  per-tool-call deltas — even a real overnight-style run wouldn't isolate "how
  many tokens did this one `summarize_file` call save" any better than the
  direct MCP-round-trip measurement below, and would cost far more wall-clock
  time to set up for one spike. `otel-collector:13133` also didn't respond in
  this session (000) when checked — not investigated further, since it isn't
  load-bearing for this method.

## Method

1. Picked four real, already-in-repo inputs spanning "large file" / "small
   file" / "small structured extraction" / "small classification."
2. For each, computed the `chars/4` "Before" estimate against the actual raw
   file content (or a 1-indexed line slice of it) that would otherwise enter
   Claude's context, plus a comparably-sized output-token estimate.
3. Called the real tool via the MCP client script above, with the client's
   own request timeout deliberately raised to 180s (see "A real MCP-client
   footgun found live" below for why the SDK default wasn't enough), and
   recorded wall-clock latency, `isError`, and the exact JSON result payload
   `chars/4`-estimated the same way for a like-for-like comparison against
   "Before."
4. Where a call failed, retried once via a fresh process (a second real
   round trip, not a script-internal retry) to see whether it was transient,
   and recorded that as real retry-overhead data.

## Results

### Task A — `summarize_file`, large file (`tools/run-overnight.sh`, 102,253 raw chars / 1,704 lines, truncated to `MAX_INPUT_CHARS`=12,000 before being sent to Ollama)

| | tokens (est./real) |
|---|---|
| **Before** (full file read into Claude's context) | ≈ 25,563 input + ≈150–200 output (sized off Task B's real output length) ≈ **~25,700–25,750 tokens** |
| **After**, attempt 1 (real) | tool-call arg ≈ 8 tokens → **HTTP 500, `isError: true`, 1.0s wall** ("model runner has unexpectedly stopped, this may be due to resource limitations") → error payload ≈ 49 tokens back. **No summary produced.** |
| **After**, attempt 2 (real, fresh process) | tool-call arg ≈ 8 tokens → generation ran until the server's own internal `GENERATE_TIMEOUT_MS` (60,000ms) fired, but the call didn't actually return until **119.2s wall-clock** → error payload (`{"error":"timed out after 60000ms"}`) ≈ 9 tokens back. **No summary produced.** |

**Net for this task, as actually observed:** the offload path never completed
successfully for this file in two real attempts (~120s of wall-clock spent
between them). Claude-context token cost of the two failed attempts is
trivial (~74 tokens total), but if the caller then falls back to reading the
file directly — the realistic behavior after a repeated tool failure — the
total cost becomes **the full ~25,700-token direct read anyway, plus the
~74 wasted tokens and ~120s of latency achieving nothing.** That's net
*negative* versus never having tried the offload at all, in this specific
session. See "Reliability" below for why this happened and whether it's this
task class's fault or the sandbox's.

### Task B — `summarize_file`, small file (`commands/analyze-telemetry.md`, 5,519 raw chars, not truncated)

| | tokens |
|---|---|
| **Before** (est.) | ≈ 1,380 input + ≈60 output (real comparable summary length, see below) ≈ **~1,440 tokens** |
| **After** (real, succeeded on the first try) | arg ≈ 10 tokens + result ≈ 72 tokens = **~82 tokens**. Wall-clock: 49.9s. |

Real result returned: `{"summary": "This script analyzes an overnight run's
token efficiency by correlating telemetry with session artifacts. It
identifies patterns of wasted tokens, provides specific fixes and estimates
the rough saving, and files these findings as beads for triage.",
"truncated": false}`

**Net: ~1,440 → ~82 tokens, a ~94% reduction**, first try, no retry needed.
Cost is ~50s of added latency, borne by Ollama's CPU-only inference, not by
Claude API spend.

### Task C — `extract`, structured extraction from a real bead entry (`.beads/issues.jsonl` line 1, 2,082 raw chars of prose — a `GOAL`/`ACCEPTANCE`/`FILES`/`SETTLED DECISIONS` bead description — 5-field schema: `id`, `title`, `priority`, `status` enum, `files_mentioned` array)

| | tokens |
|---|---|
| **Before** (est.) | ≈ 521 input + ≈65 output (real comparable extraction-result length, see below) ≈ **~586 tokens** |
| **After**, attempt 1 (real) | arg ≈ 92 tokens (the schema itself is a real, nontrivial cost — see below) → **HTTP 500, `isError: true`, 0.47s wall** (same "model runner has unexpectedly stopped" failure as Task A's crash on the same sidecar — see "Reliability" below for why "cascading from Task A" specifically is *not* well-supported by the call order) → error payload ≈ 49 tokens back. **No extraction produced.** |
| **After**, attempt 2 (real, fresh process, after the runner recovered) | arg ≈ 92 tokens + result ≈ 64 tokens = **~156 tokens**. Wall-clock: 49.4s. **Succeeded**, correctly extracting all 5 required fields — notably inferring `files_mentioned: [".devcontainer/Dockerfile.ollama"]` from free prose ("FILES: .devcontainer/Dockerfile.ollama (lines ~21–26)."), correctly dropping the line-range annotation. |

Real result returned: `{"data": {"id": "claude-arv", "title": "Add
build-time guard that setpriv accepts the exact drop args", "priority": 0,
"status": "closed", "files_mentioned": [".devcontainer/Dockerfile.ollama"]},
"truncated": false}`

**Net, counting the real failed attempt:** ~586 → (92+49 failed) + (92+64
succeeded) = **~297 tokens, a ~49% reduction** — real, but much thinner than
Task B's, for two structural reasons, not just the one failure: (1) the
input itself is small, so "Before" was never that expensive to begin with;
(2) `extract`'s own `schema` argument is a fixed cost paid on *every* call
(~92 tokens here) that `summarize_file`/`classify` don't carry, and a retry
pays it twice. A single clean success alone would be ~586→156 (~73%); the one
real retry observed here roughly halves that margin.

### Task D — `classify`, same bead entry into 5 labels

| | tokens |
|---|---|
| **Before** (est.) | ≈ 521 input + ≈5 output (a single label word) ≈ **~525 tokens** |
| **After** (real, succeeded on the first try) | arg ≈ 41 tokens (labels list) + result ≈ 14 tokens = **~55 tokens**. Wall-clock: 12.8s — the fastest and most reliable of the four calls. |

Real result returned: `{"label": "security hardening", "truncated": false}`.

**Net: ~525 → ~55 tokens, a ~90% reduction**, first try, fastest latency of
any call this session.

## Reliability: the actual retry/failure story this session

The bead's acceptance criteria specifically calls for accounting for
"retries/corrections." What was actually observed doesn't match the
retry path the README documents in detail (the schema-validation
parse/retry in `generateStructured`) — **no malformed-JSON validation
failure was observed at all this session; every response that came back
successfully was valid on the first pass.** What *was* observed, twice, was
a different and more consequential failure mode the README doesn't cover
with a retry: the Ollama **model runner itself crashing** (`HTTP 500
"model runner has unexpectedly stopped, this may be due to resource
limitations or an internal error"`), once immediately after the large
12,000-char summarize prompt (Task A) and again on the extract call (Task C).

**Revised causal read, correcting an earlier draft of this section:** an
earlier version of this write-up attributed both crashes to "a cascading
effect while the sidecar's runner process was still recovering" from Task
A's crash. That doesn't hold up against the actual call order: Task B —
a `summarize_file` call on a different, smaller file — ran *between* the
two crashes (immediately after Task A, immediately before Task C) and
succeeded cleanly in 49.9s with no errors. If the runner were genuinely
still in a degraded "recovering" window covering that stretch of wall-clock
time, Task B should plausibly have failed too; it didn't. That undercuts a
time-based recovery-window explanation and points instead at something
call-specific: Task A's crash followed a large (12,000-char, truncated)
prompt, and Task C's crash followed `extract`'s JSON-schema-constrained
`format` generation — both structurally different from Task B and Task D
(plain unconstrained generation on smaller inputs), which succeeded. A
call-specific trigger (large-prompt generation and/or schema-constrained
generation specifically) is at least as plausible an explanation as a
time-based recovery window, and the evidence here doesn't cleanly
distinguish between them — this write-up should not be read as having
established the "cascading recovery" explanation. A later, independent
direct `/api/generate` call against the same small file also hit the
identical HTTP 500, which is consistent with either explanation and doesn't
resolve it.

On resource pressure: this container reports only ~3.7GiB total RAM
(`free -h`, run inside the devcontainer's main service, not the `ollama`
service itself). That figure is very likely the shared Docker Desktop VM's
total memory — visible identically from every container in the stack —
rather than the `ollama` service's own cgroup ceiling (`.devcontainer/
docker-compose.yml` sets an 8g `deploy.resources.limits.memory` for
`ollama`, and the full running stack's aggregate configured memory limit is
~13.5g — ollama's own 8g plus ~5.5g across otel-collector (1g), prometheus
(2g), loki (2g), and grafana (0.5g) — against that same ~3.7GiB host VM;
`ollama-gpu`'s own 8g limit is excluded from that total since it's gated
behind `profiles: ["gpu"]` and was not running in this CPU-only,
`llama3.2:3b` session). This spike did not have `docker` CLI
access to check `docker stats ollama` or the `ollama` container's own
`/sys/fs/cgroup/memory.max` / `memory.current` near crash time, so it
cannot confirm the crashes were the `ollama` container individually hitting
its own limit rather than the host VM's aggregate memory simply being
oversubscribed by the whole stack's configured caps. Given that, "genuine
resource pressure" should be read as a plausible but unconfirmed hypothesis,
not a conclusion — the more mundane explanation (the sidecar stack's
aggregate configured limits exceed what the host VM actually has, a
stack-sizing question distinct from "this one 12,000-char prompt was too
much") has not been ruled out.

By design (confirmed in the source, `generateStructured` in `src/index.ts`),
a network/HTTP-level failure like this is **not** auto-retried by the
server — only a parse/validation failure on an otherwise-successful response
is. That's a reasonable design distinction in principle (an overloaded/down
model shouldn't be hammered automatically), but it means the caller (Claude,
in practice) is the one who has to notice `isError: true` and decide whether
to retry the whole tool call — which is exactly the "corrections" cost this
bead asks about, and it's cheap in tokens (each failed attempt cost ~50–100
tokens of context) but not cheap in wall-clock (potentially another ~50–120s
per retry) or in reliability (Task A never completed at all in two real
attempts).

## A real MCP-client footgun found live

The README's "Progress notifications during generation" section names an
*unverified* risk: the calling MCP client's own tool-call timeout could fire
at/near 60s, before the server's own ~90s worst-case (60s + 30s retry)
degradation gets a chance to return `isError: true`. This session confirmed
it's real, not just theoretical: the MCP SDK client's **default** 60,000ms
request timeout fired (`McpError -32001: Request timed out`) on the very
first live call in this measurement, before raising it. All numbers above
use a client-side timeout raised to 180s to work around this. Whether Claude
Code's own actual client-side timeout is high enough to avoid this in
practice remains open — this spike didn't verify that (out of scope here),
but it's now empirically demonstrated as a real risk rather than a
theoretical one, worth flagging back to whoever owns `claude-lp5`'s
follow-up.

## Recommendation

- **Worth routing to ollama:** small-to-medium, low-stakes, high-volume
  work where the "Before" cost is dominated by input size and the output is
  short and low-precision-tolerant — **classification** (Task D, ~90%
  reduction, fastest and most reliable call observed) and **summarization of
  files whose truncated-to-12,000-char slice reliably fits without crashing
  the runner** (Task B, ~94% reduction, reliable first-try success in this
  session). These are the two classes where the token math is overwhelming
  even after padding for an occasional retry.
- **Marginal, evaluate case by case:** **structured extraction from small
  inputs** (Task C, ~49–73% depending on whether a retry was needed). The
  `schema` argument's fixed token cost, plus this bead's own retry
  observation, meaningfully erodes the margin versus summarize/classify —
  still net-positive here, but not by the wide margin of the other two, and
  a schema with more fields would erode it further while the model's
  reliability on multi-field extraction from a genuinely small 3B model is
  the thing most likely to need that retry.
- **Cost more than they save, or too unreliable to trust as-is in this
  sandbox:** **large-file summarization that hits `MAX_INPUT_CHARS`
  truncation on a CPU-only sidecar** — Task A never completed in two real
  attempts this session. The *token* math for a successful call would still
  be excellent (>99% reduction, ~57–74 tokens vs. ~25,700), but reliability,
  not tokens, is the actual blocker: a caller that can't tell in advance
  whether a large-file call will crash the runner or hang to a timeout has no
  way to bank on that saving. This isn't necessarily inherent to "large-file
  summarization" as a task class — as covered in "Reliability" above, this
  spike couldn't confirm whether the trigger was memory pressure (and if so,
  whose: the `ollama` container's own configured cap, or the shared host VM
  being oversubscribed by the whole sidecar stack's aggregate limits — not
  distinguished here) or something call-specific like large-prompt or
  schema-constrained generation — but it's the honest, reproducible result
  observed here, and it's the strongest argument in this write-up for not
  blanket-routing every large-file summarization to ollama without first
  confirming the sidecar's actual resource headroom and failure mode under
  realistic concurrent/sequential load.

## Reproducing this

```bash
cd /workspace/tools/ollama-mcp
node measure-tokens.mjs        # runs the four calls in sequence, real MCP round trips
node measure-tokens-retry.mjs  # re-runs the summarize_file + extract calls (used here to get a second data point after a crash)
```

Both scripts are ad hoc/throwaway but kept in this directory (not deleted)
since they're a working, reusable harness for re-measuring this if the
sidecar's model, resource limits, or `MAX_INPUT_CHARS` change.
