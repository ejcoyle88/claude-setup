/**
 * Unit tests for the progress-notification plumbing in `progress.ts` (bead
 * claude-lp5, following up on claude-r30.5's `generateStructured` retry
 * latency). Like `validate.test.ts`, these are pure-function/fake-timer
 * tests that exercise `withPeriodicProgress`/`makeProgressNotifier` directly
 * -- they do not, and cannot in this sandbox, exercise a live Ollama call or
 * a live MCP client actually resetting its timeout clock on a received
 * notification (see this repo's claude-r30.5 close notes and claude-lp5's
 * own scope decision for what remains unverified).
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  makeProgressNotifier,
  NO_OP_PROGRESS_NOTIFIER,
  withPeriodicProgress,
  type ProgressCapableExtra,
} from "./progress.js";

/** Small interval used throughout so these tests run fast (real timers, no
 * fake-timer library dependency -- matches this package's "no new
 * devDependency for a project this small" stance, see validate.ts's file
 * header). */
const TICK_MS = 20;

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

test("withPeriodicProgress: calls notify repeatedly while the operation is pending", async () => {
  const calls: number[] = [];
  const operation = delay(TICK_MS * 4.5); // resolves partway between the 4th and 5th tick

  const result = await withPeriodicProgress(
    operation.then(() => "done"),
    (elapsedMs) => calls.push(elapsedMs),
    TICK_MS,
  );

  assert.equal(result, "done");
  // Expect roughly 4 ticks (at ~1x, 2x, 3x, 4x TICK_MS) before the ~4.5x
  // resolution -- assert a range rather than an exact count to avoid
  // flaking on scheduler jitter.
  assert.ok(calls.length >= 3 && calls.length <= 5, `expected 3-5 calls, got ${calls.length}`);
  // Each call's elapsed time should be monotonically increasing.
  for (let i = 1; i < calls.length; i++) {
    assert.ok(calls[i] > calls[i - 1], `expected increasing elapsed times, got ${calls}`);
  }
});

test("withPeriodicProgress: stops calling notify once the operation has resolved", async () => {
  const calls: number[] = [];
  await withPeriodicProgress(delay(TICK_MS * 2.5), (elapsedMs) => calls.push(elapsedMs), TICK_MS);
  const countAtResolution = calls.length;

  // Wait several more intervals' worth of time after the operation settled;
  // the count must not have grown -- the interval timer must be cleared on
  // the operation's own resolution, not just eventually garbage collected.
  await delay(TICK_MS * 4);
  assert.equal(calls.length, countAtResolution, "notify must not fire again after the operation resolved");
});

test("withPeriodicProgress: stops calling notify once the operation has rejected", async () => {
  const calls: number[] = [];
  const failing = delay(TICK_MS * 2.5).then(() => {
    throw new Error("boom");
  });

  await assert.rejects(withPeriodicProgress(failing, (elapsedMs) => calls.push(elapsedMs), TICK_MS), /boom/);
  const countAtRejection = calls.length;

  await delay(TICK_MS * 4);
  assert.equal(calls.length, countAtRejection, "notify must not fire again after the operation rejected");
});

test("withPeriodicProgress: never calls notify for an operation that settles before the first interval", async () => {
  const calls: number[] = [];
  const result = await withPeriodicProgress(Promise.resolve("fast"), (elapsedMs) => calls.push(elapsedMs), TICK_MS);
  assert.equal(result, "fast");
  assert.deepEqual(calls, []);
});

test("makeProgressNotifier: returns the shared no-op when the request carried no progressToken", () => {
  let sent = 0;
  const extra = {
    _meta: undefined,
    sendNotification: async () => {
      sent++;
    },
  };
  const notifier = makeProgressNotifier(extra);
  assert.equal(notifier, NO_OP_PROGRESS_NOTIFIER);

  notifier(1000);
  notifier(2000);
  assert.equal(sent, 0, "no notification should be sent when the caller supplied no progressToken");
});

test("makeProgressNotifier: returns the shared no-op when _meta is present but has no progressToken", () => {
  let sent = 0;
  const extra = {
    _meta: {},
    sendNotification: async () => {
      sent++;
    },
  };
  const notifier = makeProgressNotifier(extra);
  assert.equal(notifier, NO_OP_PROGRESS_NOTIFIER);

  notifier(1000);
  assert.equal(sent, 0);
});

test("makeProgressNotifier: sends a notifications/progress carrying the caller's token when one is present", async () => {
  const sent: Array<{ method: string; params?: Record<string, unknown> }> = [];
  const extra = {
    _meta: { progressToken: "tok-123" },
    sendNotification: async (notification: { method: string; params?: Record<string, unknown> }) => {
      sent.push(notification);
    },
  };
  const notifier = makeProgressNotifier(extra);
  assert.notEqual(notifier, NO_OP_PROGRESS_NOTIFIER);

  notifier(5000);
  // sendNotification is fire-and-forget (a Promise the notifier doesn't
  // await) -- flush the microtask queue before asserting.
  await Promise.resolve();
  await Promise.resolve();

  assert.equal(sent.length, 1);
  assert.equal(sent[0].method, "notifications/progress");
  assert.equal(sent[0].params?.progressToken, "tok-123");
  assert.equal(sent[0].params?.progress, 1);
  assert.match(sent[0].params?.message as string, /5s elapsed/);
});

test("makeProgressNotifier: progress value increases monotonically across repeated calls", async () => {
  const sent: Array<Record<string, unknown>> = [];
  const extra = {
    _meta: { progressToken: 42 },
    sendNotification: async (notification: { params?: Record<string, unknown> }) => {
      sent.push(notification.params ?? {});
    },
  };
  const notifier = makeProgressNotifier(extra);

  notifier(1000);
  notifier(2000);
  notifier(3000);
  await Promise.resolve();
  await Promise.resolve();

  assert.deepEqual(
    sent.map((p) => p.progress),
    [1, 2, 3],
  );
  sent.forEach((p) => assert.equal(p.progressToken, 42));
});

test("makeProgressNotifier: a rejected sendNotification never throws out of the notifier", async () => {
  const extra = {
    _meta: { progressToken: "tok" },
    sendNotification: async () => {
      throw new Error("transport closed");
    },
  };
  const notifier = makeProgressNotifier(extra);
  assert.doesNotThrow(() => notifier(1000));
  // Let the rejected promise's .catch run so it doesn't surface as an
  // unhandled rejection in the test process.
  await Promise.resolve();
  await Promise.resolve();
});

test("makeProgressNotifier: a sendNotification that throws synchronously never throws out of the notifier", () => {
  // Simulates a transport shim/test double whose `sendNotification` isn't a
  // true `async function` and so can throw before ever returning a promise
  // -- the notifier must swallow this too, not just async rejections,
  // since it runs inside withPeriodicProgress's setInterval callback, a
  // call stack the operation's own try/finally can't protect.
  const extra = {
    _meta: { progressToken: "tok" },
    sendNotification: (() => {
      throw new Error("synchronous transport failure");
    }) as unknown as ProgressCapableExtra["sendNotification"],
  };
  const notifier = makeProgressNotifier(extra);
  assert.doesNotThrow(() => notifier(1000));
});

test("withPeriodicProgress + makeProgressNotifier: end-to-end, notifications fire during a long generation and stop after", async () => {
  const sent: number[] = [];
  const extra = {
    _meta: { progressToken: "tok" },
    sendNotification: async (notification: { params?: Record<string, unknown> }) => {
      sent.push(notification.params?.progress as number);
    },
  };
  const notifier = makeProgressNotifier(extra);

  await withPeriodicProgress(delay(TICK_MS * 3.5), notifier, TICK_MS);
  await Promise.resolve();
  await Promise.resolve();

  assert.ok(sent.length >= 2, `expected at least 2 progress notifications, got ${sent.length}`);
  assert.deepEqual(sent, [...sent].sort((a, b) => a - b), "progress values must be non-decreasing");

  const countAfterSettle = sent.length;
  await delay(TICK_MS * 3);
  assert.equal(sent.length, countAfterSettle, "no further notifications once the operation has settled");
});
