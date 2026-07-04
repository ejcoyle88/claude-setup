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

const OLLAMA_HOST = process.env.OLLAMA_HOST ?? "http://ollama:11434";
const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? "llama3.2:3b";

// Mirrors src/index.ts's GENERATE_TIMEOUT_MS exactly -- a "timeout" reported
// by this script is the SAME ceiling a real summarize_file/extract/classify
// call from a concurrent Claude Code session would hit, not an arbitrary
// benchmark cutoff.
const GENERATE_TIMEOUT_MS = 60_000;

const CONCURRENCY_LEVELS = (process.env.CONCURRENCY_LEVELS ?? "1,2,4,8")
  .split(",")
  .map((s) => Number.parseInt(s.trim(), 10))
  .filter((n) => Number.isInteger(n) && n > 0);

// A short, fixed, realistic prompt -- same shape as summarize_file's real
// prompt (instructions + a FILE CONTENT block), but with a short, fixed body
// so run time stays bounded and every request across every concurrency level
// does the same amount of work (isolates contention as the variable, not
// input size). Content is a paraphrase, not a copy, of a real short file so
// this script has no dependency on repo file contents changing under it.
const SAMPLE_CONTENT = `
This module implements a small HTTP client wrapper around fetch. It exposes
a single function, requestJson, which issues a GET request to a given URL,
parses the response body as JSON, and throws a descriptive error if the
response status is not in the 200-299 range or the body fails to parse.
Callers are expected to handle network errors (e.g. DNS failures, connection
resets) themselves, since this wrapper does not retry. A companion function,
requestJsonWithTimeout, wraps the same logic with an AbortController so a
caller can bound how long it waits before giving up.
`.trim();

const PROMPT =
  "Summarize the following file content in 3-6 sentences, plain prose, " +
  "no preamble.\n\n--- FILE CONTENT START ---\n" +
  SAMPLE_CONTENT +
  "\n--- FILE CONTENT END ---";

/** Single non-streaming /api/generate call, timed and never throwing --
 * mirrors callOllamaGenerate in src/index.ts (same endpoint, same body
 * shape, same AbortController-based timeout), just without the MCP
 * tool-response wrapping around it. */
async function timedGenerate(id) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GENERATE_TIMEOUT_MS);
  const dispatchedAt = performance.now();
  try {
    const response = await fetch(`${OLLAMA_HOST}/api/generate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ model: OLLAMA_MODEL, prompt: PROMPT, stream: false }),
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
      `GENERATE_TIMEOUT_MS=${GENERATE_TIMEOUT_MS} levels=[${CONCURRENCY_LEVELS.join(",")}]`,
  );

  const rows = [];
  for (const n of CONCURRENCY_LEVELS) {
    console.error(`\n--- concurrency=${n}: dispatching ${n} concurrent /api/generate calls ---`);
    const batchStart = performance.now();
    const results = await Promise.all(Array.from({ length: n }, (_, i) => timedGenerate(i)));
    const batchWallMs = performance.now() - batchStart;
    const summary = summarize(results);
    rows.push({ concurrency: n, batchWallMs, ...summary });

    console.error(
      `concurrency=${n} batchWallMs=${Math.round(batchWallMs)} ok=${summary.okCount}/${n} ` +
        `min=${Math.round(summary.minMs ?? NaN)}ms p50=${Math.round(summary.p50Ms ?? NaN)}ms ` +
        `p95=${Math.round(summary.p95Ms ?? NaN)}ms max=${Math.round(summary.maxMs ?? NaN)}ms`,
    );
    if (summary.failedCount > 0) {
      console.error(`  failures: ${JSON.stringify(summary.errors)}`);
    }
  }

  console.error("\n--- summary table (ms) ---");
  console.error(
    ["concurrency", "batchWallMs", "ok/n", "min", "p50", "p95", "max"].join("\t"),
  );
  for (const row of rows) {
    console.error(
      [
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
      ? "\nAt least one request failed/timed out at some concurrency level above -- see failures logged per level."
      : "\nNo failures/timeouts observed at any tested concurrency level (within GENERATE_TIMEOUT_MS).",
  );
}

main().catch((err) => {
  console.error("FATAL", err);
  process.exit(1);
});
