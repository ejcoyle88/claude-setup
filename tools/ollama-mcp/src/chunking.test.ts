/**
 * Unit tests for the map-reduce chunking `summarize_file`/`extract`/
 * `classify` use on oversized input (bead claude-xg9, a follow-up to
 * claude-r30.4's original hard-truncation-only MVP -- see MAX_INPUT_CHARS's
 * doc comment in index.ts). Like `generate.test.ts`/`glob.test.ts`, these
 * exercise the actual production functions -- not a re-implementation of
 * their logic -- via the same injectable `fetchImpl`/`lockOptions`/`root`
 * patterns already established in this file, so nothing here touches a real
 * Ollama sidecar or the real, shared `GENERATE_LOCK_PATH`.
 *
 * Three things are covered:
 *  1. `splitIntoChunks` -- the UTF-16-surrogate-safe chunk splitter, both a
 *     plain even split and the surrogate-pair boundary safety it exists for.
 *  2. The chunk-count/chunk-cap fallback at the read layer (`readFileSlice`)
 *     -- content that fits within MAX_CHUNKABLE_CHARS comes back whole for
 *     chunking; content beyond it falls back to the pre-chunking hard
 *     truncation at MAX_INPUT_CHARS.
 *  3. The map-reduce/merge policies themselves -- `summarizeContent`
 *     (map+reduce into one final summary), `extractContent` +
 *     `mergeExtractedChunks` (map+merge: array union, first-non-null
 *     scalar), and `classifyContent` + `majorityLabel` (sample+vote).
 */
import assert from "node:assert/strict";
import { mkdtemp, realpath, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import {
  classifyContent,
  extractContent,
  LOCK_BUSY_RETRY_DELAY_MS,
  majorityLabel,
  MAX_CHUNK_COUNT,
  MAX_CHUNKABLE_CHARS,
  MAX_INPUT_CHARS,
  mergeExtractedChunks,
  readFileSlice,
  splitIntoChunks,
  summarizeContent,
} from "./index.js";
import type { JsonSchema } from "./validate.js";

/** Same rationale as glob.test.ts's identically-named helper: every test
 * gets its own disposable, realpath'd scratch workspace root. */
async function scratchRoot(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-chunking-test-"));
  return await realpath(dir);
}

/** Each test gets its own scratch lock file, same rationale as
 * generate.test.ts's/lock.test.ts's identically-named helper: never share,
 * or race on, the real GENERATE_LOCK_PATH a live process might be holding. */
async function scratchLockPath(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-chunking-test-lock-"));
  return path.join(dir, "generate.lock");
}

/** Directly writes a lock file's contents, bypassing `acquireGenerateLock`
 * entirely -- same helper/rationale as lock.test.ts's identically-named
 * function: used here to put the lock into a "held by someone else" busy
 * state on demand, simulating a different `ollama-mcp` session's in-flight
 * call. `pid: process.pid` is deliberate -- it's a real, currently-alive
 * pid (this test process's own), so `acquireGenerateLock`'s pid-liveness
 * check treats the lock as legitimately held rather than reclaimable. */
async function writeLockFile(lockPath: string, acquiredAt: number = Date.now()): Promise<void> {
  await writeFile(lockPath, JSON.stringify({ pid: process.pid, acquiredAt, token: "other-session-token" }));
}

/** A `fetch` stand-in that resolves each successive call with the next
 * entry of `responses` (a queue, not a fixed value -- unlike
 * generate.test.ts's `fakeFetchResolving`), so a test can script a distinct
 * model response per chunk/reduce call and assert on call order/count.
 * Also records every outbound request's `prompt` (parsed from the request
 * body) in `prompts`, and the exact `format` (the structured-output schema
 * sent to Ollama) in `formats`, in call order, so a test can inspect exactly
 * what was sent to Ollama for a given call (e.g. the reduce step's prompt,
 * or whether a per-chunk map call's `format` still carries `required` --
 * bead claude-d8u). */
function fakeFetchSequence(responses: string[]): {
  fetchImpl: typeof fetch;
  callCount: { count: number };
  prompts: string[];
  formats: unknown[];
} {
  const callCount = { count: 0 };
  const prompts: string[] = [];
  const formats: unknown[] = [];
  const queue = [...responses];
  const fetchImpl = (async (_url: string, init?: RequestInit) => {
    const text = queue.shift();
    assert.ok(text !== undefined, `fakeFetchSequence: more calls made (${callCount.count + 1}) than responses queued (${responses.length})`);
    callCount.count++;
    if (typeof init?.body === "string") {
      const parsed = JSON.parse(init.body) as { prompt?: unknown; format?: unknown };
      prompts.push(typeof parsed.prompt === "string" ? parsed.prompt : "");
      formats.push(parsed.format);
    }
    return {
      ok: true,
      status: 200,
      statusText: "OK",
      json: async () => ({ response: text }),
      text: async () => "",
    } as unknown as Response;
  }) as typeof fetch;
  return { fetchImpl, callCount, prompts, formats };
}

// --- splitIntoChunks --------------------------------------------------

test("splitIntoChunks: splits evenly-sized content into ceil(length/chunkSize) chunks", () => {
  const content = "a".repeat(25);
  const chunks = splitIntoChunks(content, 10);
  assert.deepEqual(
    chunks.map((chunk) => chunk.length),
    [10, 10, 5],
  );
  assert.equal(chunks.join(""), content);
});

test("splitIntoChunks: content exactly a multiple of chunkSize produces no trailing empty chunk", () => {
  const content = "a".repeat(20);
  const chunks = splitIntoChunks(content, 10);
  assert.deepEqual(
    chunks.map((chunk) => chunk.length),
    [10, 10],
  );
});

test("splitIntoChunks: content shorter than chunkSize is returned as a single chunk", () => {
  const chunks = splitIntoChunks("hello", 100);
  assert.deepEqual(chunks, ["hello"]);
});

test("splitIntoChunks: empty content produces no chunks", () => {
  assert.deepEqual(splitIntoChunks("", 10), []);
});

test("splitIntoChunks: never splits a surrogate pair across a chunk boundary", () => {
  // U+1F600 ("😀") as its two UTF-16 code units -- a naive
  // content.slice(i, i + chunkSize) walk would split these across two
  // chunks whenever the pair straddles a chunkSize-aligned boundary.
  const emoji = "😀";
  const content = "x".repeat(9) + emoji + "y".repeat(9);
  const chunks = splitIntoChunks(content, 10);

  assert.equal(chunks.join(""), content, "chunks must reassemble to the original content exactly");
  for (const chunk of chunks) {
    if (chunk.length === 0) {
      continue;
    }
    const lastCode = chunk.charCodeAt(chunk.length - 1);
    assert.ok(
      lastCode < 0xd800 || lastCode > 0xdbff,
      `no chunk may end on a lone high surrogate: ${JSON.stringify(chunk)}`,
    );
  }
  assert.ok(
    chunks.some((chunk) => chunk.includes(emoji)),
    "the surrogate pair must appear intact together within a single chunk",
  );
});

// --- chunk-count cap fallback at the read layer ------------------------

test("readFileSlice: content within MAX_CHUNKABLE_CHARS but over MAX_INPUT_CHARS is returned whole, untruncated", async () => {
  const root = await scratchRoot();
  const content = "a".repeat(MAX_INPUT_CHARS + 500);
  await writeFile(path.join(root, "big.txt"), content);

  const result = await readFileSlice("big.txt", undefined, undefined, root);

  assert.equal(result.ok, true);
  assert.ok(result.ok);
  if (result.ok) {
    assert.equal(result.content.length, content.length);
    assert.equal(result.truncated, false);
    assert.equal(result.truncatedChars, 0);
  }
});

test("readFileSlice: content exactly at MAX_CHUNKABLE_CHARS is returned whole, untruncated", async () => {
  const root = await scratchRoot();
  const content = "a".repeat(MAX_CHUNKABLE_CHARS);
  await writeFile(path.join(root, "exact.txt"), content);

  const result = await readFileSlice("exact.txt", undefined, undefined, root);

  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.content.length, MAX_CHUNKABLE_CHARS);
    assert.equal(result.truncated, false);
  }
});

test("readFileSlice: content beyond MAX_CHUNKABLE_CHARS falls back to the pre-chunking hard truncation at MAX_INPUT_CHARS", async () => {
  const root = await scratchRoot();
  const extra = 1000;
  const content = "a".repeat(MAX_CHUNKABLE_CHARS + extra);
  await writeFile(path.join(root, "huge.txt"), content);

  const result = await readFileSlice("huge.txt", undefined, undefined, root);

  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.content.length, MAX_INPUT_CHARS, "must fall back to the same MAX_INPUT_CHARS cap as before chunking existed");
    assert.equal(result.truncated, true);
    assert.equal(result.truncatedChars, content.length - MAX_INPUT_CHARS);
  }
});

test("readFileSlice: whole file read to true EOF with a corrupt/incomplete UTF-8 tail is returned whole, not hard-truncated to MAX_INPUT_CHARS", async () => {
  const root = await scratchRoot();
  // Well within MAX_CHUNKABLE_CHARS, so this content is squarely within the
  // "return it whole for chunking" contract -- the only wrinkle is the
  // file's own true EOF ending mid multi-byte-character (0xe2 alone is a
  // truncated 3-byte UTF-8 lead byte with no continuation bytes), which
  // trimIncompleteUtf8Tail correctly drops. Since bytesRead === fileSize
  // here (the whole file was read), that dropped byte is not evidence of an
  // unread remainder and must not trigger applyChunkCapFallback's hard
  // truncation down to MAX_INPUT_CHARS.
  const content = "a".repeat(35_000);
  const bytes = Buffer.concat([Buffer.from(content, "utf8"), Buffer.from([0xe2])]);
  await writeFile(path.join(root, "corrupt-tail.txt"), bytes);

  const result = await readFileSlice("corrupt-tail.txt", undefined, undefined, root);

  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.content, content, "the whole file's real content must come back intact, not chopped to MAX_INPUT_CHARS");
    assert.equal(result.truncated, true);
    assert.equal(result.truncatedChars, 1, "truncatedChars must reflect only the dropped corrupt tail byte, not raw.length - MAX_INPUT_CHARS");
  }
});

// The "beyond MAX_CHUNKABLE_CHARS falls back to the pre-chunking hard
// truncation" test above (bytesRead < fileSize, a genuinely unread
// remainder) already covers -- and, per this run, still passes -- the
// case this fix must not regress: only the bytesRead === fileSize +
// droppedTailBytes > 0 case above changes behavior.

// --- summarizeContent (map-reduce) --------------------------------------

test("summarizeContent: content within one chunk makes exactly one generate call, chunked:false", async () => {
  const lockPath = await scratchLockPath();
  const { fetchImpl, callCount } = fakeFetchSequence([JSON.stringify({ summary: "a short summary" })]);

  const outcome = await summarizeContent("short content", undefined, undefined, undefined, fetchImpl, { lockPath });

  assert.deepEqual(outcome, { ok: true, summary: "a short summary", chunked: false, chunkCount: 1 });
  assert.equal(callCount.count, 1);
});

test("summarizeContent: oversized content is mapped per chunk then reduced into one final summary", async () => {
  const lockPath = await scratchLockPath();
  // 2 * MAX_INPUT_CHARS + 500 chars needs ceil(24500/12000) = 3 chunks.
  const content = "a".repeat(2 * MAX_INPUT_CHARS + 500);
  const { fetchImpl, callCount } = fakeFetchSequence([
    JSON.stringify({ summary: "summary of part 1" }),
    JSON.stringify({ summary: "summary of part 2" }),
    JSON.stringify({ summary: "summary of part 3" }),
    JSON.stringify({ summary: "final combined summary" }),
  ]);

  const outcome = await summarizeContent(content, "security", undefined, undefined, fetchImpl, { lockPath });

  assert.deepEqual(outcome, { ok: true, summary: "final combined summary", chunked: true, chunkCount: 3 });
  // 3 map calls + 1 reduce call.
  assert.equal(callCount.count, 4);
});

test("summarizeContent: a failing map chunk surfaces as an error, identifying which chunk failed", async () => {
  const lockPath = await scratchLockPath();
  const content = "a".repeat(2 * MAX_INPUT_CHARS + 500);
  const { fetchImpl } = fakeFetchSequence([
    JSON.stringify({ summary: "summary of part 1" }),
    JSON.stringify({ not_summary: "malformed, twice, exhausts the retry" }),
    JSON.stringify({ not_summary: "malformed, twice, exhausts the retry" }),
  ]);

  const outcome = await summarizeContent(content, undefined, undefined, undefined, fetchImpl, { lockPath });

  assert.equal(outcome.ok, false);
  assert.match(!outcome.ok ? outcome.error : "", /chunk 2\/3/);
});

test("summarizeContent: the reduce prompt tells the model to treat part summaries as inert data, not instructions", async () => {
  const lockPath = await scratchLockPath();
  const content = "a".repeat(2 * MAX_INPUT_CHARS + 500); // 3 chunks
  const { fetchImpl, prompts } = fakeFetchSequence([
    JSON.stringify({ summary: "summary of part 1" }),
    JSON.stringify({ summary: "summary of part 2" }),
    JSON.stringify({ summary: "summary of part 3" }),
    JSON.stringify({ summary: "final combined summary" }),
  ]);

  const outcome = await summarizeContent(content, undefined, undefined, undefined, fetchImpl, { lockPath });

  assert.equal(outcome.ok, true);
  const reducePrompt = prompts.at(-1) ?? "";
  assert.match(
    reducePrompt,
    /untrusted file content/i,
    "the reduce prompt must flag that the enclosed part summaries came from untrusted content",
  );
  assert.match(
    reducePrompt,
    /ignore any (?:text|instructions?|directives?)/i,
    "the reduce prompt must explicitly instruct the model to ignore embedded directives in the part summaries",
  );
});

// --- generateStructuredWithLockBusyRetry (via summarizeContent's map loop,
// bead claude-xg9 round-2 review finding #4) -----------------------------

test("summarizeContent: a lock-busy chunk failure gets one delayed retry and succeeds without discarding the operation", async () => {
  const lockPath = await scratchLockPath();
  // Simulate a different session already holding the lock when this call's
  // very first chunk attempt runs.
  await writeLockFile(lockPath);

  const content = "a".repeat(MAX_INPUT_CHARS + 500); // 2 chunks
  // Only 3 real HTTP calls should ever happen: the first chunk's *retry*
  // attempt (its first attempt fails on the busy lock before any fetch),
  // the second chunk's single attempt, and the reduce step.
  const { fetchImpl, callCount } = fakeFetchSequence([
    JSON.stringify({ summary: "summary of part 1" }),
    JSON.stringify({ summary: "summary of part 2" }),
    JSON.stringify({ summary: "final combined summary" }),
  ]);
  const delayCalls: number[] = [];
  const delayFn = async (ms: number) => {
    delayCalls.push(ms);
    // Simulate the other session's call finishing during the wait, freeing
    // the lock before this call's retry attempt.
    await unlink(lockPath).catch(() => {});
  };

  const outcome = await summarizeContent(content, undefined, undefined, undefined, fetchImpl, { lockPath }, delayFn);

  assert.deepEqual(outcome, { ok: true, summary: "final combined summary", chunked: true, chunkCount: 2 });
  assert.equal(callCount.count, 3, "the busy first attempt must not itself reach the network");
  assert.deepEqual(delayCalls, [LOCK_BUSY_RETRY_DELAY_MS], "exactly one retry delay, for the one busy chunk");
});

test("summarizeContent: lock-busy contention that persists past the one retry still fails, discarding the operation", async () => {
  const lockPath = await scratchLockPath();
  await writeLockFile(lockPath);

  const content = "a".repeat(MAX_INPUT_CHARS + 500); // 2 chunks
  const { fetchImpl, callCount } = fakeFetchSequence([]); // no call should ever reach the network
  const delayCalls: number[] = [];
  const delayFn = async (ms: number) => {
    delayCalls.push(ms);
    // Lock file deliberately left in place -- contention never clears.
  };

  const outcome = await summarizeContent(content, undefined, undefined, undefined, fetchImpl, { lockPath }, delayFn);

  assert.equal(outcome.ok, false);
  assert.match(!outcome.ok ? outcome.error : "", /chunk 1\/2.*retry after lock contention failed/s);
  assert.equal(callCount.count, 0, "a persistently busy lock must never reach the network at all");
  assert.deepEqual(delayCalls, [LOCK_BUSY_RETRY_DELAY_MS]);
});

test("summarizeContent: a non-lock-busy chunk failure is not retried by the lock-busy retry layer", async () => {
  const lockPath = await scratchLockPath();
  const content = "a".repeat(2 * MAX_INPUT_CHARS + 500); // 3 chunks
  const { fetchImpl } = fakeFetchSequence([
    JSON.stringify({ summary: "summary of part 1" }),
    JSON.stringify({ not_summary: "malformed, twice, exhausts generateStructured's own retry" }),
    JSON.stringify({ not_summary: "malformed, twice, exhausts generateStructured's own retry" }),
  ]);
  let delayCalls = 0;
  const delayFn = async () => {
    delayCalls++;
  };

  const outcome = await summarizeContent(content, undefined, undefined, undefined, fetchImpl, { lockPath }, delayFn);

  assert.equal(outcome.ok, false);
  assert.match(!outcome.ok ? outcome.error : "", /chunk 2\/3/);
  assert.equal(delayCalls, 0, "a malformed-response failure is unrelated to lock contention and must not trigger the lock-busy delay/retry");
});

// --- extractContent + mergeExtractedChunks -------------------------------

const tagsAndTitleSchema: JsonSchema = {
  type: "object",
  properties: {
    tags: { type: "array", items: { type: "string" } },
    title: { type: "string" },
  },
};

test("extractContent: content within one chunk makes exactly one generate call, chunked:false", async () => {
  const lockPath = await scratchLockPath();
  const { fetchImpl, callCount } = fakeFetchSequence([JSON.stringify({ tags: ["a"], title: "T" })]);

  const outcome = await extractContent("short content", tagsAndTitleSchema, undefined, undefined, fetchImpl, {
    lockPath,
  });

  assert.deepEqual(outcome, { ok: true, data: { tags: ["a"], title: "T" }, chunked: false, chunkCount: 1 });
  assert.equal(callCount.count, 1);
});

test("extractContent: oversized content is mapped per chunk then merged (array union, first non-null scalar)", async () => {
  const lockPath = await scratchLockPath();
  const content = "a".repeat(MAX_INPUT_CHARS + 500); // 2 chunks
  const { fetchImpl, callCount } = fakeFetchSequence([
    JSON.stringify({ tags: ["a", "b"], title: "Title From Chunk 1" }),
    // Chunk 2's response omits `title` entirely (not required by the
    // schema) -- simulating a chunk whose excerpt never mentioned it -- and
    // contributes an overlapping + a new tag.
    JSON.stringify({ tags: ["b", "c"] }),
  ]);

  const outcome = await extractContent(content, tagsAndTitleSchema, undefined, undefined, fetchImpl, { lockPath });

  assert.equal(outcome.ok, true);
  assert.equal(callCount.count, 2, "extract's merge step is local, not an extra generate call");
  if (outcome.ok) {
    assert.equal(outcome.chunked, true);
    assert.equal(outcome.chunkCount, 2);
    assert.deepEqual(outcome.data.tags, ["a", "b", "c"], "array fields union in chunk order with duplicates removed");
    assert.equal(outcome.data.title, "Title From Chunk 1", "the first chunk with a non-null scalar value wins");
  }
});

test("extractContent: a required field missing from one chunk's data does not force that chunk to hallucinate, and a later chunk's real value survives the merge", async () => {
  const lockPath = await scratchLockPath();
  const content = "a".repeat(MAX_INPUT_CHARS + 500); // 2 chunks
  const requiredTotalPriceSchema: JsonSchema = {
    type: "object",
    properties: {
      title: { type: "string" },
      total_price: { type: "number" },
    },
    required: ["total_price"],
  };
  const { fetchImpl, callCount, formats } = fakeFetchSequence([
    // Chunk 1's excerpt never mentions the total -- omits the schema's
    // `required` field entirely, which would fail validation if the
    // per-chunk map call still enforced `required` (the bug this bead
    // fixes).
    JSON.stringify({ title: "Invoice" }),
    // Chunk 2's excerpt is where the real total actually lives.
    JSON.stringify({ total_price: 42 }),
  ]);

  const outcome = await extractContent(content, requiredTotalPriceSchema, undefined, undefined, fetchImpl, {
    lockPath,
  });

  assert.equal(callCount.count, 2, "extract's merge step is local, not an extra generate call");
  for (const format of formats) {
    assert.ok(
      typeof format === "object" && format !== null && !("required" in format),
      "per-chunk map calls must not send `required` as part of the structured-output format",
    );
  }
  assert.deepEqual(outcome, {
    ok: true,
    data: { title: "Invoice", total_price: 42 },
    chunked: true,
    chunkCount: 2,
  });
});

test("extractContent: the final merged result is still validated against the caller's full schema, erroring if no chunk ever supplied a required field's value", async () => {
  const lockPath = await scratchLockPath();
  const content = "a".repeat(MAX_INPUT_CHARS + 500); // 2 chunks
  const requiredTotalPriceSchema: JsonSchema = {
    type: "object",
    properties: {
      title: { type: "string" },
      total_price: { type: "number" },
    },
    required: ["total_price"],
  };
  const { fetchImpl } = fakeFetchSequence([
    // Neither chunk's excerpt ever mentions the total -- the merged result
    // genuinely lacks the required field's data, which should still be
    // reported as an error rather than silently returned.
    JSON.stringify({ title: "Invoice part 1" }),
    JSON.stringify({ title: "Invoice part 2" }),
  ]);

  const outcome = await extractContent(content, requiredTotalPriceSchema, undefined, undefined, fetchImpl, {
    lockPath,
  });

  assert.equal(outcome.ok, false);
  assert.match(!outcome.ok ? outcome.error : "", /total_price/);
});

test("mergeExtractedChunks: nested object fields are merged recursively per sub-field", () => {
  const schema: JsonSchema = {
    type: "object",
    properties: {
      meta: {
        type: "object",
        properties: {
          author: { type: "string" },
          reviewers: { type: "array", items: { type: "string" } },
        },
      },
    },
  };
  const merged = mergeExtractedChunks(schema, [
    { meta: { reviewers: ["alice"] } },
    { meta: { author: "bob", reviewers: ["carol"] } },
  ]);

  assert.deepEqual(merged, { meta: { author: "bob", reviewers: ["alice", "carol"] } });
});

test("mergeExtractedChunks: an object-shaped field with no declared sub-schema still merges generically", () => {
  // Exercises the schema.properties-absent-but-values-look-like-objects
  // fallback branch of mergeExtractedValue -- this is the exact shape that
  // previously tripped a TypeScript control-flow-narrowing quirk (fixed by
  // computing `objects` before the `looksLikeObjectSchema` check instead of
  // calling `present.every(isObjectValue)` inline), so this is as much a
  // regression test for that as it is a merge-policy test.
  const schema: JsonSchema = {}; // no `type`, no `properties` at all
  const merged = mergeExtractedChunks(schema, [{ a: 1 }, { b: 2 }, { a: 1, b: 3 }]);
  // "first non-null wins" per top-level key, since this schema-less shape
  // isn't recognized as declaring an array for either field.
  assert.deepEqual(merged, { a: 1, b: 2 });
});

test("mergeExtractedChunks: a field entirely absent from every chunk is omitted, not set to null/undefined", () => {
  const merged = mergeExtractedChunks(tagsAndTitleSchema, [{ tags: ["x"] }, { tags: ["y"] }]);
  assert.deepEqual(merged, { tags: ["x", "y"] });
  assert.ok(!("title" in merged));
});

// --- classifyContent + majorityLabel -------------------------------------

test("majorityLabel: the label with the most votes wins", () => {
  assert.equal(majorityLabel(["a", "b", "a", "c", "a"]), "a");
});

test("majorityLabel: a tie goes to whichever tied label's vote count reached the winning total first", () => {
  // "a" reaches a count of 2 at index 1; "b" doesn't reach 2 until index 3 --
  // "a" wins the tie by getting there first, matching majorityLabel's
  // single left-to-right pass (see its doc comment).
  assert.equal(majorityLabel(["a", "a", "b", "b"]), "a");
});

test("classifyContent: content within one chunk makes exactly one generate call, chunked:false", async () => {
  const lockPath = await scratchLockPath();
  const { fetchImpl, callCount } = fakeFetchSequence([JSON.stringify({ label: "dog" })]);

  const outcome = await classifyContent("short content", ["dog", "cat"], undefined, undefined, fetchImpl, {
    lockPath,
  });

  assert.deepEqual(outcome, { ok: true, label: "dog", chunked: false, chunkCount: 1 });
  assert.equal(callCount.count, 1);
});

test("classifyContent: oversized content samples a bounded subset of chunks and majority-votes the label", async () => {
  const lockPath = await scratchLockPath();
  // 4 * MAX_INPUT_CHARS + 500 chars needs ceil(48500/12000) = 5 chunks --
  // more than CLASSIFY_MAX_SAMPLED_CHUNKS(3), so classifyContent must sample
  // rather than classify all 5.
  const content = "a".repeat(4 * MAX_INPUT_CHARS + 500);
  const { fetchImpl, callCount } = fakeFetchSequence([
    JSON.stringify({ label: "dog" }),
    JSON.stringify({ label: "cat" }),
    JSON.stringify({ label: "dog" }),
  ]);

  const outcome = await classifyContent(content, ["dog", "cat"], undefined, undefined, fetchImpl, { lockPath });

  assert.equal(outcome.ok, true);
  if (outcome.ok) {
    assert.equal(outcome.chunked, true);
    assert.equal(outcome.label, "dog");
    assert.equal(outcome.chunkCount, 3, "must sample a small fixed number of chunks, not all 5");
  }
  assert.equal(callCount.count, 3, "must not classify more than the sampled subset");
});

test("classifyContent: a model response with a label outside the allowed set is reported as an error", async () => {
  const lockPath = await scratchLockPath();
  // `generateStructured`'s own schema validation rejects an out-of-enum
  // label and retries once (see its doc comment) -- both the first attempt
  // and the retry return an equally invalid label here, so this exercises
  // the "still invalid after one retry" -> isError path, not
  // classifyContent's own (normally unreachable) defensive re-check.
  const { fetchImpl, callCount } = fakeFetchSequence([
    JSON.stringify({ label: "not-a-real-label" }),
    JSON.stringify({ label: "still-not-a-real-label" }),
  ]);

  const outcome = await classifyContent("short content", ["dog", "cat"], undefined, undefined, fetchImpl, {
    lockPath,
  });

  assert.equal(outcome.ok, false);
  assert.equal(callCount.count, 2, "an invalid response must be retried exactly once before giving up");
});

test("MAX_CHUNK_COUNT: an oversized fixture used above stays within the documented chunk cap", () => {
  // Sanity check on the fixtures used by the map-reduce tests above, so a
  // future change to MAX_CHUNK_COUNT/MAX_INPUT_CHARS can't silently make
  // those tests exercise a different (and untested) number of chunks than
  // their assertions assume.
  assert.ok(3 <= MAX_CHUNK_COUNT, "the 3-chunk summarize/extract fixture must fit within MAX_CHUNK_COUNT");
});
