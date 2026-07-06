/**
 * Unit tests for the cross-process generate lock (`acquireGenerateLock`/
 * `releaseGenerateLock` in `index.ts`, bead claude-6ll, hardened by a
 * follow-up review of that bead's diff). Like `health.test.ts`, these use
 * Node's built-in test runner (`node:test`) and exercise the actual
 * production functions -- not a re-implementation of their logic -- via the
 * same injectable-parameter pattern `checkOllamaHealth` already established
 * (`lockPath`/`staleMs`/`isPidAlive`, all defaulting to this module's real
 * constants/behavior; see `GenerateLockOptions`'s doc comment in index.ts).
 * Every test uses its own throwaway `lockPath` under `tmpdir()` so tests
 * never share, or race on, a real lock file with each other or with a live
 * `node dist/index.js` process.
 *
 * The most important test here is
 * "a late release from a reclaimed-out holder does not delete the current
 * holder's lock" -- a regression test for this review's critical finding:
 * the pre-fix `releaseGenerateLock` unconditionally `unlink`ed whatever
 * currently sat at the lock path, with no check it was the caller's own
 * lock, so a holder whose call outlived `GENERATE_LOCK_STALE_MS` (without
 * crashing) could delete a different, legitimately reclaimed lock out from
 * under its new holder -- silently defeating the mutual exclusion this lock
 * exists to provide.
 */
import assert from "node:assert/strict";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import { acquireGenerateLock, releaseGenerateLock } from "./index.js";

/** Each test gets its own scratch directory (rather than a shared one, or
 * individual files directly under `tmpdir()`) so a failed test's leftover
 * lock file can never be mistaken for another test's, and so nothing here
 * ever collides with the real `GENERATE_LOCK_PATH` a live process might be
 * using concurrently on this same host. */
async function scratchLockPath(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-lock-test-"));
  return path.join(dir, "generate.lock");
}

/** Directly writes a lock file's contents, bypassing `acquireGenerateLock`
 * entirely -- used to set up a pre-existing "held by someone else" lock with
 * a specific `acquiredAt`/`pid`/`token` that the real acquire path (which
 * always writes `Date.now()`) can't otherwise produce on demand. */
async function writeLockFile(
  lockPath: string,
  holder: { pid: number; acquiredAt: number; token: string },
): Promise<void> {
  await writeFile(lockPath, JSON.stringify(holder));
}

test("acquireGenerateLock/releaseGenerateLock: uncontended acquire+release round-trip", async () => {
  const lockPath = await scratchLockPath();

  const acquired = await acquireGenerateLock({ lockPath });
  assert.equal(acquired.state, "acquired");
  assert.equal(typeof (acquired as { token: string }).token, "string");
  assert.ok((acquired as { token: string }).token.length > 0);

  // Created with an explicit, restrictive mode (review finding #2) -- not
  // Node's default (0o666 minus umask).
  const fileStat = await stat(lockPath);
  assert.equal(fileStat.mode & 0o777, 0o600);

  await releaseGenerateLock((acquired as { token: string }).token, { lockPath });
  await assert.rejects(stat(lockPath), /ENOENT/);
});

test("acquireGenerateLock: reports busy when a fresh lock is held", async () => {
  const lockPath = await scratchLockPath();

  const first = await acquireGenerateLock({ lockPath });
  assert.equal(first.state, "acquired");

  const second = await acquireGenerateLock({ lockPath, staleMs: 60_000 });
  assert.equal(second.state, "busy");
  if (second.state === "busy") {
    assert.ok(second.heldForMs >= 0);
    assert.ok(second.heldForMs < 60_000);
  }

  await releaseGenerateLock((first as { token: string }).token, { lockPath });
});

test("acquireGenerateLock: stale-reclaim succeeds once a held lock exceeds staleMs", async () => {
  const lockPath = await scratchLockPath();
  const originalToken = "original-stale-token";
  // Recorded pid is this test process's own pid -- very much alive -- so the
  // reclaim here is driven purely by age (heldForMs > staleMs), isolating
  // this test from the pid-liveness path covered separately below.
  await writeLockFile(lockPath, { pid: process.pid, acquiredAt: Date.now() - 10_000, token: originalToken });

  const result = await acquireGenerateLock({ lockPath, staleMs: 1_000 });
  assert.equal(result.state, "acquired");
  assert.notEqual((result as { token: string }).token, originalToken);

  const onDisk = JSON.parse(await readFile(lockPath, "utf8")) as { token: string };
  assert.equal(onDisk.token, (result as { token: string }).token);

  await releaseGenerateLock((result as { token: string }).token, { lockPath });
});

test("acquireGenerateLock: reclaims immediately when the recorded pid is dead, even if the lock isn't old", async () => {
  const lockPath = await scratchLockPath();
  const originalToken = "dead-pid-token";
  // acquiredAt is "now" (not stale by age at all) -- only the injected
  // isPidAlive returning false should trigger the reclaim (review finding
  // #2: a dead holder can never release its own lock, so age is
  // irrelevant).
  await writeLockFile(lockPath, { pid: 999_999_999, acquiredAt: Date.now(), token: originalToken });

  const result = await acquireGenerateLock({
    lockPath,
    staleMs: 10 * 60_000,
    isPidAlive: () => false,
  });
  assert.equal(result.state, "acquired");
  assert.notEqual((result as { token: string }).token, originalToken);

  await releaseGenerateLock((result as { token: string }).token, { lockPath });
});

test("acquireGenerateLock: does NOT reclaim a fresh lock whose recorded pid is alive, even with a permissive isPidAlive default", async () => {
  const lockPath = await scratchLockPath();
  const first = await acquireGenerateLock({ lockPath });
  assert.equal(first.state, "acquired");

  // This process's own pid is genuinely alive -- a real acquireGenerateLock
  // call (no isPidAlive override) must not falsely treat it as dead.
  const second = await acquireGenerateLock({ lockPath, staleMs: 60_000 });
  assert.equal(second.state, "busy");

  await releaseGenerateLock((first as { token: string }).token, { lockPath });
});

test("releaseGenerateLock: a late release from a reclaimed-out holder does not delete the current holder's lock (regression test for the critical lock-ownership bug)", async () => {
  const lockPath = await scratchLockPath();

  // Process A acquires normally.
  const acquiredByA = await acquireGenerateLock({ lockPath });
  assert.equal(acquiredByA.state, "acquired");
  const tokenA = (acquiredByA as { token: string }).token;

  // Simulate A's call running long enough to go stale (e.g. slow under
  // memory pressure) by rewriting the lock file in place with an old
  // acquiredAt but A's *same* token -- this is what A's own lock actually
  // looks like on disk once enough time has passed, without this test
  // needing to sleep past a real GENERATE_LOCK_STALE_MS.
  await writeLockFile(lockPath, { pid: process.pid, acquiredAt: Date.now() - 10_000, token: tokenA });

  // Process B, blocked, judges A's lock stale and reclaims it -- correct in
  // isolation.
  const acquiredByB = await acquireGenerateLock({ lockPath, staleMs: 1_000 });
  assert.equal(acquiredByB.state, "acquired");
  const tokenB = (acquiredByB as { token: string }).token;
  assert.notEqual(tokenB, tokenA);

  // A's call now finishes and its `finally` calls releaseGenerateLock with
  // its OWN (now-stale/reclaimed) token -- this must be a no-op, not an
  // unconditional unlink of whatever currently occupies the path.
  await releaseGenerateLock(tokenA, { lockPath });

  // B's lock must still be intact, untouched, with B's token -- not deleted
  // out from under it by A's late release.
  const onDiskAfterA = JSON.parse(await readFile(lockPath, "utf8")) as { token: string };
  assert.equal(onDiskAfterA.token, tokenB, "A's late release must not have deleted B's still-live lock");

  // A third caller C, arriving now, must see the lock as busy (held by B) --
  // NOT get to acquire it concurrently with B, which is exactly the bug this
  // regression test guards against.
  const acquiredByC = await acquireGenerateLock({ lockPath, staleMs: 60_000 });
  assert.equal(acquiredByC.state, "busy", "C must not be able to acquire while B still legitimately holds the lock");

  // Clean up: B releases its own lock with its own token, which must succeed.
  await releaseGenerateLock(tokenB, { lockPath });
  await assert.rejects(stat(lockPath), /ENOENT/);
});
