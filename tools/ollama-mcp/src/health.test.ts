/**
 * Unit tests for the two transport/reachability tools -- `ping` (via
 * `pingResult`) and `health` (via `checkOllamaHealth`) -- in `index.ts` (bead
 * claude-dha, following up on claude-r30.3's quality review, which noted
 * `checkOllamaHealth`'s async/timeout logic had no committed test). Like
 * `validate.test.ts`/`progress.test.ts`, these use Node's built-in test
 * runner (`node:test`) rather than a mocking framework, matching this
 * package's "no new devDependency for a project this small" stance (see
 * validate.test.ts's file header).
 *
 * `checkOllamaHealth` takes two parameters purely for this file's benefit:
 * an injectable `fetchImpl` (defaults to the real global `fetch`) and an
 * injectable `timeoutMs` (defaults to the real HEALTH_CHECK_TIMEOUT_MS).
 * Neither is used by `index.ts`'s own `health` tool handler, which still
 * calls `checkOllamaHealth()` with no arguments -- see that function's doc
 * comment in index.ts. These tests substitute a fake `fetchImpl` (never a
 * real network call) to exercise `checkOllamaHealth`'s actual reachable /
 * unreachable / abort-on-timeout branches, including a fetch mock that
 * hangs until the real AbortController set up inside `checkOllamaHealth`
 * fires -- not a stand-in that merely returns a canned "timed out" string.
 * There is no live Ollama sidecar in this sandbox, so none of this touches
 * a real Ollama instance (see claude-9sm for that separate, out-of-scope
 * live-sidecar test).
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import { checkOllamaHealth, pingResult } from "./index.js";

/** Minimal stand-in for the parts of the global `fetch` Response object
 * `checkOllamaHealth` actually touches (`ok`, `status`, `statusText`,
 * `body.cancel()`) -- cast to `typeof fetch` the same way progress.test.ts
 * casts its `sendNotification` test doubles, rather than constructing a
 * fully spec-compliant Response.
 *
 * Returns the `fetch` double alongside a `spy` whose `cancelCalls` counter
 * lets a test assert `checkOllamaHealth` actually released the response body.
 * `checkOllamaHealth` calls `await response.body?.cancel()` on *both* the 2xx
 * and non-2xx branches specifically to release the socket instead of
 * buffering the /api/tags body (its doc comment calls this out as intentional
 * resource cleanup). A silent no-op `cancel` stub would let a future edit
 * that dropped or short-circuited that call still pass every test, so the spy
 * is how these tests actually pin that resource-cleanup contract. */
function fakeFetchResolving(response: {
  ok: boolean;
  status?: number;
  statusText?: string;
}): { fetchImpl: typeof fetch; spy: { cancelCalls: number } } {
  const spy = { cancelCalls: 0 };
  const fetchImpl = (async () =>
    ({
      ok: response.ok,
      status: response.status ?? (response.ok ? 200 : 500),
      statusText: response.statusText ?? (response.ok ? "OK" : "Internal Server Error"),
      body: {
        cancel: async () => {
          spy.cancelCalls++;
        },
      },
    }) as unknown as Response) as typeof fetch;
  return { fetchImpl, spy };
}

/** A `fetch` stand-in that rejects immediately, simulating Ollama being
 * completely unreachable (connection refused, DNS failure, etc.) rather than
 * responding with a non-2xx status. */
function fakeFetchRejecting(message: string): typeof fetch {
  return (async () => {
    throw new Error(message);
  }) as typeof fetch;
}

/** A `fetch` stand-in that never resolves on its own -- it only settles by
 * rejecting with an AbortError once the `AbortSignal` `checkOllamaHealth`
 * passes in is aborted, the same way Node's real `fetch` behaves when its
 * signal fires. This exercises `checkOllamaHealth`'s actual
 * AbortController/setTimeout logic (a short injected `timeoutMs` below), not
 * a fake that just asserts a magic string. */
function fakeFetchHangingUntilAborted(): typeof fetch {
  return (async (..._args: Parameters<typeof fetch>) => {
    const init = _args[1];
    return new Promise((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => {
        reject(new DOMException("This operation was aborted", "AbortError"));
      });
    });
  }) as typeof fetch;
}

test("pingResult: returns a static ok, the ping tool's happy path", () => {
  assert.deepEqual(pingResult(), { ok: true });
});

test("checkOllamaHealth: reports reachable:true on a 2xx response", async () => {
  const { fetchImpl, spy } = fakeFetchResolving({ ok: true });
  const result = await checkOllamaHealth(fetchImpl);
  assert.equal(result.reachable, true);
  assert.equal(result.error, undefined);
  assert.ok(result.host.length > 0);
  assert.ok(result.model.length > 0);
  // Releasing the response body (instead of buffering /api/tags) is part of
  // this branch's contract -- see fakeFetchResolving's comment.
  assert.equal(spy.cancelCalls, 1, "the response body must be cancelled exactly once on the reachable path");
});

test("checkOllamaHealth: reports reachable:false with the status on a non-2xx response", async () => {
  const { fetchImpl, spy } = fakeFetchResolving({ ok: false, status: 503, statusText: "Service Unavailable" });
  const result = await checkOllamaHealth(fetchImpl);
  assert.equal(result.reachable, false);
  assert.match(result.error ?? "", /503/);
  assert.match(result.error ?? "", /Service Unavailable/);
  // The body is cancelled on the non-2xx branch too, not just the happy path.
  assert.equal(spy.cancelCalls, 1, "the response body must be cancelled exactly once on the non-2xx path");
});

test("checkOllamaHealth: reports reachable:false when fetch rejects (connection refused / DNS failure)", async () => {
  const result = await checkOllamaHealth(fakeFetchRejecting("connect ECONNREFUSED 127.0.0.1:11434"));
  assert.equal(result.reachable, false);
  assert.match(result.error ?? "", /ECONNREFUSED/);
});

test("checkOllamaHealth: aborts and reports reachable:false when the request exceeds the timeout", async () => {
  const start = Date.now();
  const result = await checkOllamaHealth(fakeFetchHangingUntilAborted(), 20);
  const elapsedMs = Date.now() - start;

  assert.equal(result.reachable, false);
  assert.match(result.error ?? "", /aborted/i);
  // Should resolve close to the injected 20ms timeout, not hang -- generous
  // upper bound to avoid flaking on a loaded CI/sandbox machine, but tight
  // enough to catch "never actually timed out."
  assert.ok(elapsedMs < 2000, `expected the abort to fire quickly, took ${elapsedMs}ms`);
});

test("checkOllamaHealth: never throws even when fetch behaves unexpectedly", async () => {
  await assert.doesNotReject(checkOllamaHealth(fakeFetchRejecting("boom")));
});
