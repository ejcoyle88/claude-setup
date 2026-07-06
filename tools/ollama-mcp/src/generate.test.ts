/**
 * Unit tests for abort-signal wiring into `callOllamaGenerate`/
 * `generateStructured` in `index.ts` (bead claude-144, surfaced during
 * claude-9sm's Round-2 review). Before this bead, the tool handlers
 * (`extract`/`summarize_file`/`classify`) never forwarded the incoming MCP
 * request's `AbortSignal` (a handler's `extra.signal`) into the outbound
 * `/api/generate` fetch -- only `GENERATE_TIMEOUT_MS`/`RETRY_TIMEOUT_MS`'s own
 * timer-driven `AbortController` could cancel it, so a client that gave up
 * left the CPU-only sidecar running the abandoned inference for up to its
 * own worst-case duration.
 *
 * Like `health.test.ts`/`lock.test.ts`, these use Node's built-in test
 * runner (`node:test`) and exercise the actual production functions -- not
 * a re-implementation of their logic -- via the same injectable-parameter
 * pattern already established in this file (`fetchImpl`, matching
 * `checkOllamaHealth`'s; `lockOptions`, matching `acquireGenerateLock`'s
 * `GenerateLockOptions`). Every test uses its own throwaway `lockPath`
 * under `tmpdir()` (see `scratchLockPath`, copied from lock.test.ts's own
 * helper of the same name/purpose) so these tests never acquire or reclaim
 * the real, shared `GENERATE_LOCK_PATH` a live `node dist/index.js` process
 * on this host might actually be holding.
 *
 * There is no live Ollama sidecar in this sandbox, so every `fetchImpl`
 * here is a fake -- none of this touches a real network call (see
 * claude-9sm's live-e2e.test.ts for that separate, out-of-scope live-sidecar
 * coverage).
 */
import assert from "node:assert/strict";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { callOllamaGenerate, generateStructured } from "./index.js";
import type { JsonSchema } from "./validate.js";

/** Each test gets its own scratch lock file, same rationale as
 * lock.test.ts's identically-named helper: never share, or race on, a real
 * lock file with another test or with a live process on this host. */
async function scratchLockPath(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-generate-test-"));
  return path.join(dir, "generate.lock");
}

/** A `fetch` stand-in that resolves immediately with a 2xx JSON body
 * `{ response: text }`, matching the shape `callOllamaGenerate` expects from
 * a real Ollama `/api/generate` response. Also counts how many times it was
 * actually invoked, so a test can assert an aborted call never reaches (or
 * reaches exactly once, for the retry case) the outbound fetch. */
function fakeFetchResolving(text: string): { fetchImpl: typeof fetch; callCount: { count: number } } {
  const callCount = { count: 0 };
  const fetchImpl = (async () => {
    callCount.count++;
    return {
      ok: true,
      status: 200,
      statusText: "OK",
      json: async () => ({ response: text }),
      text: async () => "",
    } as unknown as Response;
  }) as typeof fetch;
  return { fetchImpl, callCount };
}

/** A `fetch` stand-in that never resolves on its own -- it only settles by
 * rejecting once the `AbortSignal` passed in `init.signal` fires, the same
 * way Node's real `fetch` behaves. Rejects with `signal.reason` (falling
 * back to a generic `AbortError` DOMException if the signal was aborted
 * with no explicit reason, e.g. a bare `controller.abort()`) rather than
 * always a fixed `AbortError`-named DOMException -- this matters because
 * `callOllamaGenerate`'s caller-vs-timeout distinction deliberately does
 * NOT rely on the rejection's shape/name (see its doc comment): it's
 * driven by re-checking `callerSignal?.aborted` after the fact, precisely
 * because a real cancel notification's `reason` (or a bare `.abort()`'s
 * default reason) can look identical to the timeout's own `AbortError`. */
function fakeFetchHangingUntilAborted(): { fetchImpl: typeof fetch; callCount: { count: number } } {
  const callCount = { count: 0 };
  const fetchImpl = (async (..._args: Parameters<typeof fetch>) => {
    callCount.count++;
    const init = _args[1];
    const signal = init?.signal;
    return new Promise<Response>((_resolve, reject) => {
      const abortWith = () => reject(signal?.reason ?? new DOMException("This operation was aborted", "AbortError"));
      if (signal?.aborted) {
        abortWith();
        return;
      }
      signal?.addEventListener("abort", abortWith);
    });
  }) as typeof fetch;
  return { fetchImpl, callCount };
}

const summarizeSchema: JsonSchema = {
  type: "object",
  properties: { summary: { type: "string" } },
  required: ["summary"],
};

test("callOllamaGenerate: happy path resolves ok:true with the model response (no abort-wiring regression)", async () => {
  const lockPath = await scratchLockPath();
  const { fetchImpl } = fakeFetchResolving("hello world");
  const result = await callOllamaGenerate("prompt", undefined, 5000, undefined, fetchImpl, { lockPath });
  assert.deepEqual(result, { ok: true, response: "hello world" });
});

test("callOllamaGenerate: an already-aborted caller signal short-circuits before any fetch call", async () => {
  const lockPath = await scratchLockPath();
  const controller = new AbortController();
  controller.abort();
  const { fetchImpl, callCount } = fakeFetchResolving("should never be seen");

  const result = await callOllamaGenerate("prompt", undefined, 5000, controller.signal, fetchImpl, { lockPath });

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /cancelled by the caller/i);
  assert.equal(callCount.count, 0, "fetch must never be called for an already-aborted caller signal");
});

test("callOllamaGenerate: caller signal aborting mid-flight cancels the outbound fetch promptly", async () => {
  const lockPath = await scratchLockPath();
  const controller = new AbortController();
  const { fetchImpl } = fakeFetchHangingUntilAborted();

  const start = Date.now();
  const pending = callOllamaGenerate("prompt", undefined, 60_000, controller.signal, fetchImpl, { lockPath });
  // Bare abort(), no explicit reason -- exercises the default-reason path
  // (see fakeFetchHangingUntilAborted's doc comment) rather than a
  // convenient custom string a real MCP client would rarely supply.
  controller.abort();
  const result = await pending;
  const elapsedMs = Date.now() - start;

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /cancelled by the caller/i);
  assert.ok(!(!result.ok && /timed out/i.test(result.error)), "must not be reported as a timeout");
  // Should resolve promptly on the caller's abort, not wait out the 60s
  // timeoutMs -- generous bound to avoid flaking on a loaded machine, tight
  // enough to catch "caller signal was never actually wired in."
  assert.ok(elapsedMs < 2000, `expected the caller abort to cancel the fetch quickly, took ${elapsedMs}ms`);
});

test("callOllamaGenerate: existing timeout-driven abort still fires when the caller signal never aborts", async () => {
  const lockPath = await scratchLockPath();
  const controller = new AbortController(); // never aborted by this test
  const { fetchImpl } = fakeFetchHangingUntilAborted();

  const start = Date.now();
  const result = await callOllamaGenerate("prompt", undefined, 20, controller.signal, fetchImpl, { lockPath });
  const elapsedMs = Date.now() - start;

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /timed out after 20ms/);
  assert.ok(elapsedMs < 2000, `expected the timeout to fire quickly, took ${elapsedMs}ms`);
});

test("callOllamaGenerate: timeout-driven abort still works with no caller signal at all", async () => {
  const lockPath = await scratchLockPath();
  const { fetchImpl } = fakeFetchHangingUntilAborted();

  const result = await callOllamaGenerate("prompt", undefined, 20, undefined, fetchImpl, { lockPath });

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /timed out after 20ms/);
});

test("generateStructured: already-aborted caller signal short-circuits before any fetch call, no retry attempted", async () => {
  const lockPath = await scratchLockPath();
  const controller = new AbortController();
  controller.abort();
  const { fetchImpl, callCount } = fakeFetchResolving("{}");

  const result = await generateStructured(
    "prompt",
    summarizeSchema,
    undefined,
    controller.signal,
    fetchImpl,
    { lockPath },
  );

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /cancelled by the caller/i);
  assert.equal(callCount.count, 0, "fetch must never be called for an already-aborted caller signal");
});

test("generateStructured: caller abort mid-flight is reported once, not retried as a malformed-response failure", async () => {
  const lockPath = await scratchLockPath();
  const controller = new AbortController();
  const { fetchImpl, callCount } = fakeFetchHangingUntilAborted();

  const pending = generateStructured("prompt", summarizeSchema, undefined, controller.signal, fetchImpl, {
    lockPath,
  });
  controller.abort();
  const result = await pending;

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /cancelled by the caller/i);
  // A client-driven abort is a network/timeout-class failure, not a
  // malformed-response one -- generateStructured must not have retried it
  // (only one fetch call total), and the error text must not read like the
  // "retry after malformed response failed" branch this could otherwise be
  // mistaken for.
  assert.equal(callCount.count, 1, "an aborted call must not be retried");
  assert.doesNotMatch(!result.ok ? result.error : "", /retry after malformed response/i);
});

test("generateStructured: happy path with a live (never-aborted) caller signal works exactly as before", async () => {
  const lockPath = await scratchLockPath();
  const controller = new AbortController();
  const { fetchImpl } = fakeFetchResolving(JSON.stringify({ summary: "a summary" }));

  const result = await generateStructured("prompt", summarizeSchema, undefined, controller.signal, fetchImpl, {
    lockPath,
  });

  assert.deepEqual(result, { ok: true, value: { summary: "a summary" } });
});
