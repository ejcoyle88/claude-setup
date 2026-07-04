// Ad hoc measurement script for claude-6ll: drives real concurrent
// POST /api/generate load straight at the live `ollama` sidecar (same URL,
// model, and non-streaming shape `callOllamaGenerate` in src/index.ts uses --
// see that function for the production call this mirrors) to answer the
// bead's actual question: how many concurrent generate calls does this
// CPU-only, single-instance sidecar sustain before requests start queuing
// (visibly higher latency than a solo call) or timing out against the real
// GENERATE_TIMEOUT_MS (60_000ms, duplicated below -- see measure-tokens.mjs's
// header comment for why these constants are copied literals here rather
// than imported: this is a plain .mjs run directly via `node`, not through
// the TS build).
//
// Not part of the server; ad hoc, throwaway-but-kept for reproducibility, same
// convention as measure-tokens.mjs/measure-tokens-retry.mjs in this directory.
// Run from repo root: node tools/ollama-mcp/benchmark-concurrency.mjs
// Override concurrency levels: CONCURRENCY_LEVELS=1,2,4,8,12 node tools/ollama-mcp/benchmark-concurrency.mjs
//
// claude-6ll review follow-up (findings #4/#5): the original version of this
// script only ever sent a few-hundred-character fixed prompt, far below
// MAX_INPUT_CHARS (12,000 chars, duplicated below same as GENERATE_TIMEOUT_MS
// -- see src/index.ts) that a real summarize_file/extract/classify call can
// send, and ran concurrency levels back-to-back with no gap between them --
// letting a prior level's stragglers (a client-timed-out request Ollama may
// still be processing server-side, see README's "Residual gap" note)
// contaminate the next level's numbers. Both are addressed here:
//   - PROMPT_CHAR_SIZES (default "400,12000", same override-via-env-var
//     pattern as CONCURRENCY_LEVELS) sweeps the *same* concurrency levels at
//     more than one content size, so the README's numbers cover both a
//     best-case short prompt and a near-cap-size prompt close to what a real
//     large-file summarize_file call would actually send.
//   - COOLDOWN_MS (default GENERATE_TIMEOUT_MS + 5s) sleeps between every
//     consecutive (contentChars, concurrency) run in the sweep -- comfortably
//     past GENERATE_TIMEOUT_MS, so a straggler still being processed
//     server-side after its client gave up has time to actually finish
//     before the next run dispatches new load at the same sidecar.

const OLLAMA_HOST = process.env.OLLAMA_HOST ?? "http://ollama:11434";
const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? "llama3.2:3b";

// Mirrors src/index.ts's GENERATE_TIMEOUT_MS exactly -- a "timeout" reported
// by this script is the SAME ceiling a real summarize_file/extract/classify
// call from a concurrent Claude Code session would hit, not an arbitrary
// benchmark cutoff.
const GENERATE_TIMEOUT_MS = 60_000;

// Mirrors src/index.ts's MAX_INPUT_CHARS -- see that constant's doc comment.
const MAX_INPUT_CHARS = 12_000;

const CONCURRENCY_LEVELS = (process.env.CONCURRENCY_LEVELS ?? "1,2,4,8")
  .split(",")
  .map((s) => Number.parseInt(s.trim(), 10))
  .filter((n) => Number.isInteger(n) && n > 0);

// Content sizes (characters) to sweep, in order: a short/best-case prompt and
// a size at/near MAX_INPUT_CHARS -- what real summarize_file/extract/classify
// calls against a large (truncated) file actually send. Override via env var,
// same pattern as CONCURRENCY_LEVELS.
const PROMPT_CHAR_SIZES = (process.env.PROMPT_CHAR_SIZES ?? `400,${MAX_INPUT_CHARS}`)
  .split(",")
  .map((s) => Number.parseInt(s.trim(), 10))
  .filter((n) => Number.isInteger(n) && n > 0);

// Idle gap between every consecutive run in the sweep (both between
// concurrency levels within one content size, and between content-size
// groups). Default comfortably exceeds GENERATE_TIMEOUT_MS so a client-side
// timeout's straggler has time to actually finish server-side before the next
// run starts (see README's "Residual gap" note this addresses). Override via
// COOLDOWN_MS for a faster (less rigorous) local run.
const COOLDOWN_MS = Number.parseInt(process.env.COOLDOWN_MS ?? String(GENERATE_TIMEOUT_MS + 5_000), 10);

// A paraphrase (not a copy) of a real short file's content/shape, matching
// summarize_file's real prompt structure (instructions + a FILE CONTENT
// block). Repeated/truncated by buildContent() below to hit any requested
// PROMPT_CHAR_SIZES entry, so every size in the sweep is built from the same
// realistic prose rather than synthetic filler -- this script has no
// dependency on repo file contents changing under it.
const BASE_PARAGRAPH = `
This module implements a small HTTP client wrapper around fetch. It exposes
a single function, requestJson, which issues a GET request to a given URL,
parses the response body as JSON, and throws a descriptive error if the
response status is not in the 200-299 range or the body fails to parse.
Callers are expected to handle network errors (e.g. DNS failures, connection
resets) themselves, since this wrapper does not retry. A companion function,
requestJsonWithTimeout, wraps the same logic with an AbortController so a
caller can bound how long it waits before giving up. Error messages include
the request URL and status code, and are designed to be logged directly
without further formatting. Response parsing tolerates an empty body by
returning null instead of throwing a JSON syntax error, since some endpoints
legitimately return 204 No Content. The module has no dependencies beyond the
platform fetch/AbortController globals, and is intended to be copy-pasted into
small scripts rather than published as a package.
`.trim();

/** Builds file content of exactly `targetChars` characters by repeating
 * BASE_PARAGRAPH (joined with blank lines, like real multi-paragraph file
 * content) until it's long enough, then truncating to the exact size --
 * mirrors how a real large file would be sliced to MAX_INPUT_CHARS by
 * `readFileSlice` in src/index.ts. */
function buildContent(targetChars) {
  if (targetChars <= BASE_PARAGRAPH.length) {
    return BASE_PARAGRAPH.slice(0, targetChars);
  }
  const parts = [];
  let length = 0;
  while (length < targetChars) {
    parts.push(BASE_PARAGRAPH);
    length += BASE_PARAGRAPH.length + 2; // +2 for the "\n\n" join below
  }
  return parts.join("\n\n").slice(0, targetChars);
}

function buildPrompt(content) {
  return (
    "Summarize the following file content in 3-6 sentences, plain prose, " +
    "no preamble.\n\n--- FILE CONTENT START ---\n" +
    content +
    "\n--- FILE CONTENT END ---"
  );
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Single non-streaming /api/generate call, timed and never throwing --
 * mirrors callOllamaGenerate in src/index.ts (same endpoint, same body
 * shape, same AbortController-based timeout), just without the MCP
 * tool-response wrapping around it. */
async function timedGenerate(id, prompt) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GENERATE_TIMEOUT_MS);
  const dispatchedAt = performance.now();
  try {
    const response = await fetch(`${OLLAMA_HOST}/api/generate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: OLLAMA_MODEL, prompt, stream: false }),
      signal: controller.signal,
    });
    const wallMs = performance.now() - dispatchedAt;
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      return { id, ok: false, wallMs, error: `HTTP ${response.status} ${response.statusText}${body ? `: ${body}` : ""}` };
    }
    const body = await response.json();
    return {
      id,
      ok: true,
      wallMs,
      // Ollama-reported timings, ns -> ms, when present (newer server
      // versions): total_duration is server-side wall time for this
      // request (queue + eval), separate from this script's own wallMs
      // (client-observed round trip, includes any client-side queuing too
      // since all N requests are dispatched in the same tick).
      totalDurationMs: typeof body.total_duration === "number" ? Math.round(body.total_duration / 1e6) : undefined,
      evalCount: body.eval_count,
    };
  } catch (error) {
    const wallMs = performance.now() - dispatchedAt;
    const timedOut = error instanceof Error && error.name === "AbortError";
    return {
      id,
      ok: false,
      wallMs,
      error: timedOut ? `timed out after ${GENERATE_TIMEOUT_MS}ms (GENERATE_TIMEOUT_MS)` : String(error?.message ?? error),
    };
  } finally {
    clearTimeout(timer);
  }
}

function summarize(results) {
  const ok = results.filter((r) => r.ok);
  const failed = results.filter((r) => !r.ok);
  const latencies = ok.map((r) => r.wallMs).sort((a, b) => a - b);
  const pct = (p) => (latencies.length === 0 ? NaN : latencies[Math.min(latencies.length - 1, Math.floor((p / 100) * latencies.length))]);
  return {
    n: results.length,
    okCount: ok.length,
    failedCount: failed.length,
    minMs: latencies[0],
    p50Ms: pct(50),
    p95Ms: pct(95),
    maxMs: latencies[latencies.length - 1],
    errors: failed.map((r) => r.error),
  };
}

async function main() {
  console.error(
    `benchmark-concurrency: host=${OLLAMA_HOST} model=${OLLAMA_MODEL} ` +
      `GENERATE_TIMEOUT_MS=${GENERATE_TIMEOUT_MS} levels=[${CONCURRENCY_LEVELS.join(",")}] ` +
      `promptCharSizes=[${PROMPT_CHAR_SIZES.join(",")}] cooldownMs=${COOLDOWN_MS}`,
  );

  // Flatten (contentChars x concurrency) into one ordered run list, so the
  // cooldown below applies uniformly between every consecutive run --
  // including across a content-size boundary, where a straggler from the
  // last (largest) concurrency level of one size could otherwise bleed into
  // the first level of the next size's sweep.
  const runs = [];
  for (const contentChars of PROMPT_CHAR_SIZES) {
    for (const n of CONCURRENCY_LEVELS) {
      runs.push({ contentChars, n });
    }
  }

  const rows = [];
  for (let i = 0; i < runs.length; i++) {
    const { contentChars, n } = runs[i];
    const content = buildContent(contentChars);
    const prompt = buildPrompt(content);

    console.error(`\n--- promptChars=${contentChars} concurrency=${n}: dispatching ${n} concurrent /api/generate calls ---`);
    const batchStart = performance.now();
    const results = await Promise.all(Array.from({ length: n }, (_, id) => timedGenerate(id, prompt)));
    const batchWallMs = performance.now() - batchStart;
    const summary = summarize(results);
    rows.push({ contentChars, concurrency: n, batchWallMs, ...summary });

    console.error(
      `promptChars=${contentChars} concurrency=${n} batchWallMs=${Math.round(batchWallMs)} ok=${summary.okCount}/${n} ` +
        `min=${Math.round(summary.minMs ?? NaN)}ms p50=${Math.round(summary.p50Ms ?? NaN)}ms ` +
        `p95=${Math.round(summary.p95Ms ?? NaN)}ms max=${Math.round(summary.maxMs ?? NaN)}ms`,
    );
    if (summary.failedCount > 0) {
      console.error(`  failures: ${JSON.stringify(summary.errors)}`);
    }

    if (i < runs.length - 1) {
      console.error(`  cooling down ${Math.round(COOLDOWN_MS / 1000)}s before the next run (see COOLDOWN_MS)...`);
      await sleep(COOLDOWN_MS);
    }
  }

  console.error("\n--- summary table (ms) ---");
  console.error(
    ["promptChars", "concurrency", "batchWallMs", "ok/n", "min", "p50", "p95", "max"].join("\t"),
  );
  for (const row of rows) {
    console.error(
      [
        row.contentChars,
        row.concurrency,
        Math.round(row.batchWallMs),
        `${row.okCount}/${row.n}`,
        Math.round(row.minMs ?? NaN),
        Math.round(row.p50Ms ?? NaN),
        Math.round(row.p95Ms ?? NaN),
        Math.round(row.maxMs ?? NaN),
      ].join("\t"),
    );
  }

  const anyTimeouts = rows.some((r) => r.failedCount > 0);
  console.error(
    anyTimeouts
      ? "\nAt least one request failed/timed out at some (promptChars, concurrency) combination above -- see failures logged per run."
      : "\nNo failures/timeouts observed at any tested (promptChars, concurrency) combination (within GENERATE_TIMEOUT_MS).",
  );
}

main().catch((err) => {
  console.error("FATAL", err);
  process.exit(1);
});
