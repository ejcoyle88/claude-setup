/**
 * Unit tests for glob/multi-file support in `summarize_file`/`extract`
 * (bead claude-1nx, a follow-up to claude-r30.4's single-path-only MVP --
 * see index.ts's `isGlobPattern`/`matchGlob`/`processGlobMatches` doc
 * comments). Like `lock.test.ts`/`generate.test.ts`, these exercise the
 * actual production functions -- not a re-implementation of their logic --
 * via the same injectable-`root` pattern `resolveWorkspacePath`/
 * `readFileSlice`/`matchGlob`/`processGlobMatches` all now expose (matching
 * `acquireGenerateLock`'s `lockPath` option), so every test runs against its
 * own disposable temp directory rather than the real WORKSPACE_ROOT.
 *
 * These tests never call Ollama: `processGlobMatches`'s `perFile` callback
 * is a stub here, not `generateStructured` -- the actual `summarize_file`/
 * `extract` glob branches (`summarizeGlob`/`extractGlob` in index.ts) wire
 * that stub-shaped slot to a real `generateStructured` call, and are
 * exercised end-to-end (real Ollama, real MCP transport) only by the
 * separate opt-in `live-e2e.test.ts` suite for the single-path case; adding
 * an equivalent live glob test was judged out of scope for this bead (see
 * its final report).
 */
import assert from "node:assert/strict";
import { mkdir, mkdtemp, realpath, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { test } from "node:test";
import {
  isGlobPattern,
  matchGlob,
  processGlobMatches,
  readFileSlice,
  resolveWorkspacePath,
} from "./index.js";

/** Each test gets its own scratch workspace root under `tmpdir()`, same
 * rationale as `lock.test.ts`'s `scratchLockPath`: never share, or race on,
 * fixtures with another test. Realpath'd up front because
 * `resolveWorkspacePath`'s containment check compares against a
 * `realpath`-resolved candidate -- on a platform where `tmpdir()` itself is
 * a symlink (e.g. macOS's `/tmp` -> `/private/tmp`), an un-resolved root
 * would never equal (or prefix-match) the resolved candidate, failing every
 * legitimate case for a reason that has nothing to do with what's under
 * test. */
async function scratchRoot(): Promise<string> {
  const dir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-glob-test-"));
  return await realpath(dir);
}

test("isGlobPattern: plain paths (no metacharacters) are not glob patterns", () => {
  assert.equal(isGlobPattern("README.md"), false);
  assert.equal(isGlobPattern("src/index.ts"), false);
  assert.equal(isGlobPattern("a/b/c.txt"), false);
  // '{' is deliberately not a trigger -- this matcher doesn't implement
  // brace expansion (see isGlobPattern's doc comment).
  assert.equal(isGlobPattern("weird{file}.txt"), false);
});

test("isGlobPattern: '*', '?', and '[' each mark a path as a glob pattern", () => {
  assert.equal(isGlobPattern("*.ts"), true);
  assert.equal(isGlobPattern("src/**/*.ts"), true);
  assert.equal(isGlobPattern("file?.txt"), true);
  assert.equal(isGlobPattern("[ab].txt"), true);
});

test("resolveWorkspacePath: a plain relative path inside root resolves fine (single-path regression)", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "hello");

  const result = await resolveWorkspacePath("a.txt", root);

  assert.equal(result.ok, true);
  assert.equal(result.ok && result.path, path.join(root, "a.txt"));
});

test("resolveWorkspacePath: '../' traversal outside root is rejected", async () => {
  const root = await scratchRoot();

  const result = await resolveWorkspacePath("../etc/passwd", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /outside the workspace root/);
});

test("resolveWorkspacePath: an absolute path outside root is rejected", async () => {
  const root = await scratchRoot();

  const result = await resolveWorkspacePath("/etc/passwd", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /outside the workspace root/);
});

test("resolveWorkspacePath: a symlink inside root pointing outside it is rejected after following symlinks", async () => {
  const root = await scratchRoot();
  const outsideDir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-glob-test-outside-"));
  const secretFile = path.join(outsideDir, "secret.txt");
  await writeFile(secretFile, "top secret");
  await symlink(secretFile, path.join(root, "link.txt"));

  const result = await resolveWorkspacePath("link.txt", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /outside the workspace root .* after following symlinks/);
});

test("readFileSlice: reads a plain file's content (single-path regression)", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "hello world");

  const result = await readFileSlice("a.txt", undefined, undefined, root);

  assert.equal(result.ok, true);
  assert.equal(result.ok && result.content, "hello world");
  assert.equal(result.ok && result.truncated, false);
});

test("matchGlob: rejects an absolute pattern", async () => {
  const root = await scratchRoot();

  const result = await matchGlob("/etc/*", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /must be relative to the workspace root/);
});

test("matchGlob: reports no matches, rather than an empty success, for a pattern matching nothing", async () => {
  const root = await scratchRoot();

  const result = await matchGlob("*.nope", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /matched no files/);
});

test("matchGlob: '*' matches multiple files directly under root", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "a");
  await writeFile(path.join(root, "b.txt"), "b");
  await writeFile(path.join(root, "c.md"), "c"); // must not match

  const result = await matchGlob("*.txt", root);

  assert.equal(result.ok, true);
  assert.deepEqual(result.ok && result.matches, ["a.txt", "b.txt"]);
});

test("matchGlob: a literal directory segment followed by '*' matches files in a subdirectory", async () => {
  const root = await scratchRoot();
  await mkdir(path.join(root, "sub"));
  await writeFile(path.join(root, "sub", "x.txt"), "x");
  await writeFile(path.join(root, "sub", "y.txt"), "y");
  await writeFile(path.join(root, "top.txt"), "top"); // must not match

  const result = await matchGlob("sub/*.txt", root);

  assert.equal(result.ok, true);
  assert.deepEqual(
    result.ok && result.matches,
    [path.join("sub", "x.txt"), path.join("sub", "y.txt")],
  );
});

test("matchGlob: '**' matches files nested arbitrarily deep, including zero levels", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "top.txt"), "top");
  await mkdir(path.join(root, "a", "b"), { recursive: true });
  await writeFile(path.join(root, "a", "mid.txt"), "mid");
  await writeFile(path.join(root, "a", "b", "deep.txt"), "deep");
  await writeFile(path.join(root, "a", "b", "deep.md"), "not matched");

  const result = await matchGlob("**/*.txt", root);

  assert.equal(result.ok, true);
  assert.deepEqual(
    result.ok && result.matches,
    [path.join("a", "b", "deep.txt"), path.join("a", "mid.txt"), "top.txt"],
  );
});

test("matchGlob: '?' matches exactly one character", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a1.txt"), "1");
  await writeFile(path.join(root, "a22.txt"), "22"); // must not match ('?' is exactly one char)

  const result = await matchGlob("a?.txt", root);

  assert.equal(result.ok, true);
  assert.deepEqual(result.ok && result.matches, ["a1.txt"]);
});

test("matchGlob: '[...]' bracket character classes (including negation) work", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "a");
  await writeFile(path.join(root, "b.txt"), "b");
  await writeFile(path.join(root, "c.txt"), "c");

  const included = await matchGlob("[ab].txt", root);
  assert.equal(included.ok, true);
  assert.deepEqual(included.ok && included.matches, ["a.txt", "b.txt"]);

  const negated = await matchGlob("[!ab].txt", root);
  assert.equal(negated.ok, true);
  assert.deepEqual(negated.ok && negated.matches, ["c.txt"]);
});

test("matchGlob: does not descend into a symlinked directory while walking", async () => {
  const root = await scratchRoot();
  const outsideDir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-glob-test-outside-"));
  await writeFile(path.join(outsideDir, "hidden.txt"), "hidden");
  await symlink(outsideDir, path.join(root, "linked-dir"));

  const result = await matchGlob("**/*.txt", root);

  // The symlinked directory itself is never traversed into, so the file
  // inside it is never even discovered as a candidate.
  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /matched no files/);
});

test("matchGlob: a symlinked FILE matched by a pattern's final segment IS included in the raw match list", async () => {
  const root = await scratchRoot();
  const outsideDir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-glob-test-outside-"));
  const secretFile = path.join(outsideDir, "secret.txt");
  await writeFile(secretFile, "top secret");
  await symlink(secretFile, path.join(root, "link.txt"));

  const result = await matchGlob("*.txt", root);

  // matchGlob only narrows candidates by directory listing -- it is the
  // caller's job (processGlobMatches, via resolveWorkspacePath) to reject
  // this per-file, not matchGlob's -- see its doc comment.
  assert.equal(result.ok, true);
  assert.deepEqual(result.ok && result.matches, ["link.txt"]);
});

test("matchGlob: matching more than MAX_GLOB_MATCHES files is an error, not a silent partial result", async () => {
  const root = await scratchRoot();
  for (let i = 0; i < 25; i++) {
    await writeFile(path.join(root, `f${i}.txt`), String(i));
  }

  const result = await matchGlob("*.txt", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /matched more than \d+ files/);
});

test("matchGlob: a sparse-match '**' pattern over many nested directories aborts with a scan-cap error rather than walking the whole tree", async () => {
  const root = await scratchRoot();
  // Deliberately no file anywhere matches '*.zzz' -- this is the "**\/*.zzz
  // against most of the tree" shape from the bug report: the walk must
  // give up once it's scanned too many directory entries, rather than
  // recursing through every one of these directories to conclude "no
  // matches". 100 top-level dirs x 60 nested dirs each = 6100 total
  // entries, comfortably above the production scan cap.
  const topLevelCount = 100;
  const nestedPerTopLevel = 60;
  for (let i = 0; i < topLevelCount; i++) {
    const topDir = path.join(root, `d${i}`);
    await mkdir(topDir);
    await Promise.all(
      Array.from({ length: nestedPerTopLevel }, (_, j) => mkdir(path.join(topDir, `s${j}`))),
    );
  }

  const result = await matchGlob("**/*.zzz", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /scanned more than \d+ directory entries/);
});

test("matchGlob: a single oversized directory listing trips the scan cap on its own, even though the running total across the whole walk never reaches MAX_GLOB_DIR_ENTRIES_SCANNED", async () => {
  const root = await scratchRoot();
  // A single directory with more entries than MAX_GLOB_DIR_ENTRIES_PER_
  // DIRECTORY (2000), but comfortably fewer than the total-walk cap
  // (MAX_GLOB_DIR_ENTRIES_SCANNED, 5000) -- this is exactly the claude-1nx
  // round-2 review's finding A gap: before the per-directory cap existed, a
  // directory this size would be fully readdir'd (and fully matched/
  // recursed against) before any cap ever fired, since 2500 < 5000. The walk
  // must still abort with the same scan-cap error, tripped by this ONE
  // directory alone.
  const entryCount = 2500;
  await Promise.all(
    Array.from({ length: entryCount }, (_, i) => writeFile(path.join(root, `f${i}.txt`), String(i))),
  );

  const result = await matchGlob("*.zzz", root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /scanned more than \d+ directory entries/);
});

test("matchGlob: never descends into node_modules/.git/dist regardless of pattern", async () => {
  const root = await scratchRoot();
  await mkdir(path.join(root, "node_modules", "pkg"), { recursive: true });
  await writeFile(path.join(root, "node_modules", "pkg", "index.txt"), "must never match");
  await mkdir(path.join(root, ".git", "objects"), { recursive: true });
  await writeFile(path.join(root, ".git", "objects", "blob.txt"), "must never match");
  await mkdir(path.join(root, "dist"), { recursive: true });
  await writeFile(path.join(root, "dist", "out.txt"), "must never match");
  await writeFile(path.join(root, "real.txt"), "must match");

  const result = await matchGlob("**/*.txt", root);

  assert.equal(result.ok, true);
  assert.deepEqual(result.ok && result.matches, ["real.txt"]);
});

test("matchGlob: rejects an oversized pattern rather than processing it", async () => {
  const root = await scratchRoot();
  const oversizedPattern = `*${"a".repeat(300)}`;

  const result = await matchGlob(oversizedPattern, root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /exceeds the maximum length/);
});

test("matchGlob: rejects a segment packed with too many wildcard characters (ReDoS shape) rather than processing it", async () => {
  const root = await scratchRoot();
  const pathologicalPattern = `${"*".repeat(9)}.txt`; // 9 > MAX_GLOB_METACHARACTERS_PER_SEGMENT (8)

  const result = await matchGlob(pathologicalPattern, root);

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /too many wildcard characters/);
});

test("matchGlob: a pathological many-'*'-interleaved-with-a-repeated-literal pattern, matched against a similarly-shaped long non-matching name, resolves quickly rather than catastrophically backtracking (claude-1nx round-2 finding B)", async () => {
  const root = await scratchRoot();
  // Same shape as the CVE-2022-3517 minimatch ReDoS this finding is modeled
  // on: several '*' interleaved with the same literal character repeated,
  // tested against a long name sharing that literal but never ending in the
  // pattern's final literal -- catastrophic (polynomial with a large
  // exponent, one factor of name-length per '*') for a naive backtracking
  // regex, linear for the two-pointer matcher this round of review required
  // (see matchGlobSegment's doc comment). Kept within
  // MAX_GLOB_METACHARACTERS_PER_SEGMENT's cap of 8 (7 '*' here) and within
  // typical filesystem filename-length limits.
  const pathologicalName = `${"a".repeat(200)}z`; // never ends in 'b' -- must NOT match, only after scanning the whole name
  await writeFile(path.join(root, pathologicalName), "content");
  const pattern = "a*a*a*a*a*a*a*b";

  const start = Date.now();
  const result = await matchGlob(pattern, root);
  const elapsedMs = Date.now() - start;

  assert.equal(result.ok, false);
  assert.match(!result.ok ? result.error : "", /matched no files/);
  assert.ok(
    elapsedMs < 1000,
    `expected the linear-time segment matcher to resolve a pathological pattern/name pair quickly, took ${elapsedMs}ms`,
  );
});

test("processGlobMatches: runs perFile for each match and reports a compact per-file result", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "AAA");
  await writeFile(path.join(root, "b.txt"), "BBB");
  const expanded = await matchGlob("*.txt", root);
  assert.equal(expanded.ok, true);
  const matches = expanded.ok ? expanded.matches : [];

  const results = await processGlobMatches(matches, undefined, undefined, undefined, root, async (slice) => ({
    upper: slice.content.toUpperCase(),
  }));

  assert.deepEqual(
    results.map((r) => ({ path: r.path, upper: r.upper })),
    [
      { path: "a.txt", upper: "AAA" },
      { path: "b.txt", upper: "BBB" },
    ],
  );
});

test("processGlobMatches: a matched symlink escaping root is rejected as its OWN {path, error} entry, not silently dropped", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "AAA");
  const outsideDir = await mkdtemp(path.join(tmpdir(), "ollama-mcp-glob-test-outside-"));
  await writeFile(path.join(outsideDir, "secret.txt"), "top secret");
  await symlink(path.join(outsideDir, "secret.txt"), path.join(root, "link.txt"));

  const expanded = await matchGlob("*.txt", root);
  assert.equal(expanded.ok, true);
  const matches = expanded.ok ? expanded.matches : [];
  assert.deepEqual(matches, ["a.txt", "link.txt"]);

  const results = await processGlobMatches(matches, undefined, undefined, undefined, root, async (slice) => ({
    upper: slice.content.toUpperCase(),
  }));

  assert.equal(results.length, 2, "both matches must produce a result -- neither silently skipped");
  const good = results.find((r) => r.path === "a.txt");
  const bad = results.find((r) => r.path === "link.txt");
  assert.ok(good && good.upper === "AAA" && good.error === undefined);
  assert.ok(bad && typeof bad.error === "string");
  assert.match(String(bad?.error), /outside the workspace root .* after following symlinks/);
});

test("processGlobMatches: a perFile that throws/rejects becomes a per-file error entry, not a propagated rejection (doc-comment 'never throws' contract)", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "AAA");
  await writeFile(path.join(root, "b.txt"), "BBB");

  const results = await processGlobMatches(["a.txt", "b.txt"], undefined, undefined, undefined, root, async (
    slice,
  ) => {
    if (slice.content === "AAA") {
      throw new Error("boom");
    }
    return { upper: slice.content.toUpperCase() };
  });

  assert.equal(results.length, 2, "both matches must produce a result -- one throwing must not abort the batch");
  const failed = results.find((r) => r.path === "a.txt");
  const succeeded = results.find((r) => r.path === "b.txt");
  assert.ok(failed && typeof failed.error === "string" && /boom/.test(String(failed.error)));
  assert.ok(succeeded && succeeded.upper === "BBB" && succeeded.error === undefined);
});

test("processGlobMatches: stops (without erroring) once the signal is already aborted", async () => {
  const root = await scratchRoot();
  await writeFile(path.join(root, "a.txt"), "AAA");
  await writeFile(path.join(root, "b.txt"), "BBB");
  const controller = new AbortController();
  controller.abort();

  const results = await processGlobMatches(["a.txt", "b.txt"], undefined, undefined, controller.signal, root, async (
    slice,
  ) => ({ upper: slice.content.toUpperCase() }));

  assert.deepEqual(results, []);
});
