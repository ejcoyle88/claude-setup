#!/usr/bin/env node
/**
 * ollama-mcp: stdio MCP server that offloads work to a local Ollama instance.
 *
 * Exposes `ping` (transport smoke test), `health` (reachability check against
 * OLLAMA_HOST), and three reference-based offload tools -- `summarize_file`,
 * `extract`, `classify` (bead claude-r30.4). The offload tools take a file
 * path (never inline bulk text) so the MCP server reads the content itself
 * and only a compact result (a summary string, extracted fields, a label)
 * crosses back into Claude's context -- the file body never does. Paths are
 * confined to WORKSPACE_ROOT (see `resolveWorkspacePath`) -- no absolute
 * path, `../` traversal, or symlink can read a file outside it.
 */
import { createHash, randomUUID } from "node:crypto";
import { createReadStream } from "node:fs";
import { open, readFile, realpath, stat, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import * as path from "node:path";
import * as readline from "node:readline";
import { fileURLToPath } from "node:url";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  makeProgressNotifier,
  NO_OP_PROGRESS_NOTIFIER,
  type ProgressNotifier,
  withPeriodicProgress,
} from "./progress.js";
import { type JsonSchema, parseAndValidateJson } from "./validate.js";

/** Base URL of the Ollama server, e.g. "http://ollama:11434". No trailing slash. */
const OLLAMA_HOST = (process.env.OLLAMA_HOST ?? "http://ollama:11434").replace(/\/+$/, "");

/** Default model for future offload tools. Not used by ping/health, but read
 * here so it's validated at startup and visible in `health`'s response.
 * Must match the OLLAMA_MODEL the ollama sidecar warms on start (see
 * docker-compose.yml's x-ollama-common anchor and
 * .devcontainer/ollama-entrypoint.sh's WARM section, added in claude-r30.2) --
 * pointing this at a model the sidecar hasn't pulled would reintroduce the
 * cold "model not found" failure that bead exists to prevent. */
const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? "llama3.2:3b";

/** Timeout for the health check's reachability probe, in milliseconds. */
const HEALTH_CHECK_TIMEOUT_MS = 3000;

/** Timeout for an actual generation call (summarize/extract/classify), in
 * milliseconds. Generation on a CPU-only 3b model is much slower than the
 * /api/tags probe `health` uses, so this is far more generous. */
const GENERATE_TIMEOUT_MS = 60_000;

/** Timeout for the *retry* generation call `generateStructured` issues
 * after a malformed/invalid first response (see its doc comment), in
 * milliseconds. Deliberately shorter than GENERATE_TIMEOUT_MS: a retry is
 * "resample the dice on the same prompt," not "give the model more thinking
 * time" -- if the model needed unusually long to produce (still-invalid)
 * output the first time, waiting another full GENERATE_TIMEOUT_MS on the
 * retry would let a single tool call take up to ~2x GENERATE_TIMEOUT_MS
 * (~120s) before surfacing an error, with nothing on the caller side raised
 * to match. Halving it bounds the combined worst case at 1.5x
 * GENERATE_TIMEOUT_MS (~90s) instead, closer to the pre-retry ~60s ceiling
 * this bead's retry logic added latency on top of. */
const RETRY_TIMEOUT_MS = Math.round(GENERATE_TIMEOUT_MS / 2);

/** claude-6ll: cross-process advisory lock guarding every outbound
 * `/api/generate` call (see `acquireGenerateLock`/`releaseGenerateLock`
 * below). This repo registers ollama-mcp at *project scope*
 * (`.mcp.json`), so every Claude Code session opened against this repo
 * spawns its OWN `node dist/index.js` process, and all of those independent
 * processes share the same single `OLLAMA_HOST` sidecar with no queue/pool
 * coordination between them -- an in-process semaphore in one process
 * cannot serialize calls another process makes, so this coordinates via a
 * lock FILE (shared filesystem: every ollama-mcp process on this host sees
 * the same `tmpdir()`), not an in-memory data structure.
 *
 * This isn't a wait-in-line queue -- it's fail-fast, on purpose. A real
 * benchmark (`benchmark-concurrency.mjs`, run against this sidecar's
 * CPU-only llama3.2:3b) measured a single uncontended `/api/generate` call
 * at ~35-40s wall time -- already 60-65% of GENERATE_TIMEOUT_MS -- so
 * *waiting* for a prior call to finish before even starting a second one
 * would frequently blow through GENERATE_TIMEOUT_MS on its own, before the
 * second call has done any work. Since there's no slack in the timeout
 * budget to queue politely, a caller that finds the lock already held gets
 * an immediate, clearly-worded "busy, retry shortly" error instead of
 * silently occupying a tool-call slot for up to 60s only to time out anyway
 * -- see README's "Concurrent-session contention" section for the measured
 * numbers this design responds to (2 concurrent calls already produced one
 * hard timeout; 8 concurrent calls produced zero successes).
 */
const GENERATE_LOCK_PATH = path.join(
  tmpdir(),
  `ollama-mcp-generate-${createHash("sha256").update(OLLAMA_HOST).digest("hex").slice(0, 16)}.lock`,
);

/** How old an existing lock file must be before a blocked caller reclaims it
 * instead of reporting "busy" (see `acquireGenerateLock`). Must comfortably
 * exceed the ~1.5x GENERATE_TIMEOUT_MS (~90s) worst case a single
 * *well-behaved* call can legitimately hold the lock (first attempt +
 * retry, see RETRY_TIMEOUT_MS's doc comment) -- otherwise a live, in-flight
 * call's lock could be mistaken for stale and reclaimed out from under it,
 * letting two calls proceed concurrently anyway. Long enough past that
 * worst case to avoid false reclaims, short enough that a genuinely crashed
 * holder (process killed, container restarted mid-call) doesn't wedge every
 * other ollama-mcp process on this host behind a lock nobody will ever
 * release. */
const GENERATE_LOCK_STALE_MS = 3 * 60_000;

/** `token` is a per-acquisition random identity (see `acquireGenerateLock`'s
 * doc comment) -- the caller must pass it back to `releaseGenerateLock` so a
 * late release can verify it still owns the lock before deleting anything
 * (claude-6ll review finding: an unconditional unlink in the release path let
 * a stale-but-still-running holder delete a *different*, legitimately
 * reclaimed lock out from under a new holder -- see releaseGenerateLock's doc
 * comment for the fix). */
type LockAcquireResult =
  | { state: "acquired"; token: string }
  | { state: "unavailable" }
  | { state: "busy"; heldForMs: number };

/** Upper bound, in characters, on the file content sent to Ollama in a single
 * request. This is a crude proxy for tokens (roughly 4 chars/token for
 * English text), not an exact count -- the goal is just to stay well inside
 * a small model's context window (Ollama's own default num_ctx is 2048
 * unless a Modelfile overrides it) after adding prompt instructions and
 * leaving room for the response. Content beyond this is truncated, and
 * truncation is always reported back in the result (see `truncated` /
 * `truncatedChars` fields below) rather than silently dropped -- if a file
 * needs more than this, chunking is out of scope for this bead (see
 * README's Follow-ups).
 */
const MAX_INPUT_CHARS = 12_000;

/** Worst-case bytes-per-character for UTF-8 (a 4-byte sequence encodes a
 * single character). Used to size a bounded read that's guaranteed to cover
 * MAX_INPUT_CHARS worth of decoded content without reading further. */
const MAX_UTF8_BYTES_PER_CHAR = 4;

/** Upper bound, in bytes, on the on-disk size of a file this server will
 * read at all (checked via `fstat` before any read). Well above what
 * MAX_INPUT_CHARS could ever need (12,000 chars is at most ~48KB even at
 * UTF-8's 4-bytes/char worst case) but far below "someone pointed this at a
 * multi-GB file" -- this exists purely to fail fast on a pathological input
 * rather than let `readFileSlice` buffer or line-split something huge. 8MiB
 * gives generous headroom for legitimate targets (large source files, log
 * excerpts) while staying cheap to `stat`/reject. */
const MAX_FILE_SIZE_BYTES = 8 * 1024 * 1024;

/** Root directory that every `path`/`pathOrText` (when `isPath`) argument is
 * confined to -- see `resolveWorkspacePath`. Defaults to this process's cwd,
 * which is the repo root when launched as a stdio MCP server from the
 * devcontainer (matches `.devcontainer/devcontainer.json`'s
 * `workspaceFolder` and the `..:/workspace:cached` bind mount in
 * `.devcontainer/docker-compose.yml`). Override with `WORKSPACE_ROOT` if
 * this server is ever launched from somewhere other than the repo root. */
const WORKSPACE_ROOT = path.resolve(process.env.WORKSPACE_ROOT ?? process.cwd());

const server = new McpServer(
  {
    name: "ollama-mcp",
    version: "0.1.0",
  },
  {
    instructions:
      "Local Ollama offload server. `ping` and `health` are transport/" +
      "reachability checks. `summarize_file`, `extract`, and `classify` " +
      "offload bulk text work to a local Ollama model: they take a file " +
      "path (never inline file content) and return a compact result, so " +
      "large files never enter the caller's context. Prefer these over " +
      "reading a large file directly when only a summary, a few extracted " +
      "fields, or a single label is actually needed.",
  },
);

/** Static payload for the `ping` tool -- a trivial transport reachability
 * check that never contacts Ollama (see `health`/`checkOllamaHealth` for
 * that). Pulled out of the inline handler below and exported so
 * health.test.ts can exercise the actual production logic directly, rather
 * than re-asserting a duplicated literal. */
export function pingResult(): { ok: true } {
  return { ok: true };
}

server.registerTool(
  "ping",
  {
    description:
      "Trivial reachability check for this MCP server itself. Returns a " +
      "static ok — does not contact Ollama. Use `health` to check Ollama.",
    inputSchema: {},
  },
  async () => ({
    content: [{ type: "text", text: JSON.stringify(pingResult()) }],
  }),
);

server.registerTool(
  "health",
  {
    description:
      "Lightweight reachability check against the configured Ollama host " +
      "(OLLAMA_HOST). Never throws: reports reachable=false with an error " +
      "message instead of failing when Ollama is down or unconfigured.",
    inputSchema: {},
  },
  async () => {
    const result = await checkOllamaHealth();
    return {
      content: [{ type: "text", text: JSON.stringify(result, null, 2) }],
      isError: !result.reachable,
    };
  },
);

const lineRangeShape = {
  startLine: z
    .number()
    .int()
    .positive()
    .optional()
    .describe("1-indexed, inclusive. Omit to start at the first line."),
  endLine: z
    .number()
    .int()
    .positive()
    .optional()
    .describe("1-indexed, inclusive. Omit to read to the last line."),
};

server.registerTool(
  "summarize_file",
  {
    description:
      "Summarize a file on disk using the local Ollama model, without the " +
      "file content ever entering the caller's context -- only the summary " +
      "is returned. Pass a file path, never the file's content. Optionally " +
      "narrow with `focus` (what to summarize toward) and/or `startLine`/" +
      "`endLine` (a 1-indexed inclusive slice). Large files are truncated " +
      `to ${MAX_INPUT_CHARS} characters before being sent to the model -- ` +
      "check the `truncated` field in the result.",
    inputSchema: {
      path: z
        .string()
        .describe("Path to the file to summarize (read by this server, not the caller)."),
      focus: z
        .string()
        .optional()
        .describe("Optional steer for the summary, e.g. 'security-relevant changes only'."),
      ...lineRangeShape,
    },
  },
  async ({ path, focus, startLine, endLine }, extra) => {
    const slice = await readFileSlice(path, startLine, endLine);
    if (!slice.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: slice.error }) }], isError: true };
    }

    const prompt =
      "Summarize the following file content in 3-6 sentences, plain prose, " +
      "no preamble." +
      (focus ? ` Focus specifically on: ${focus}.` : "") +
      "\n\n--- FILE CONTENT START ---\n" +
      slice.content +
      "\n--- FILE CONTENT END ---";

    const generated = await generateStructured(
      prompt,
      {
        type: "object",
        properties: { summary: { type: "string" } },
        required: ["summary"],
      },
      makeProgressNotifier(extra),
    );
    if (!generated.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: generated.error }) }], isError: true };
    }

    const summary = generated.value.summary;
    if (typeof summary !== "string") {
      // Should be unreachable -- generateStructured already validated
      // 'summary' is a string via the schema above -- but this is a
      // defensive backstop against that guarantee rather than an `as
      // string` cast, since TS can't itself prove the runtime shape of a
      // value typed only as Record<string, unknown>.
      return {
        content: [
          { type: "text", text: JSON.stringify({ error: "model response missing string 'summary' field" }) },
        ],
        isError: true,
      };
    }

    const result = {
      summary,
      truncated: slice.truncated,
      ...(slice.truncated ? { truncatedChars: slice.truncatedChars } : {}),
    };
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  },
);

server.registerTool(
  "extract",
  {
    description:
      "Extract structured data from a file on disk using the local Ollama " +
      "model, without the file content ever entering the caller's context " +
      "-- only the extracted JSON is returned. Pass a file path, never the " +
      "file's content. `schema` is a JSON-Schema-like object describing " +
      "the fields to extract (e.g. { type: 'object', properties: { title: " +
      "{ type: 'string' } }, required: ['title'] }); it is passed to " +
      "Ollama's structured-output `format` so the model is constrained to " +
      "match it. The response is validated against `schema` (required " +
      "fields present, declared types match) and, if it fails to parse as " +
      "JSON or fails validation, the generation is retried once before " +
      "giving up -- on a small model the output can still fail either way " +
      "even after that; in that case this tool returns isError:true with a " +
      "clear message describing what was wrong, rather than returning " +
      "garbage or a partially-parsed guess silently. " +
      `Large files are truncated to ${MAX_INPUT_CHARS} characters -- check ` +
      "the `truncated` field in the result.",
    inputSchema: {
      path: z
        .string()
        .describe("Path to the file to extract from (read by this server, not the caller)."),
      schema: z
        .unknown()
        .refine((value) => typeof value === "object" && value !== null && !Array.isArray(value), {
          message: "schema must be a JSON object (JSON-Schema-like), e.g. { type: 'object', properties: {...} }",
        })
        .describe("JSON-Schema-like object describing the fields to extract."),
      ...lineRangeShape,
    },
  },
  async ({ path, schema, startLine, endLine }, extra) => {
    const slice = await readFileSlice(path, startLine, endLine);
    if (!slice.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: slice.error }) }], isError: true };
    }

    const prompt =
      "Extract structured data from the following file content, matching " +
      "the required JSON schema exactly. Return only the JSON object, no " +
      "commentary." +
      "\n\n--- FILE CONTENT START ---\n" +
      slice.content +
      "\n--- FILE CONTENT END ---";

    const generated = await generateStructured(prompt, schema as JsonSchema, makeProgressNotifier(extra));
    if (!generated.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: generated.error }) }], isError: true };
    }

    const result = {
      data: generated.value,
      truncated: slice.truncated,
      ...(slice.truncated ? { truncatedChars: slice.truncatedChars } : {}),
    };
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  },
);

server.registerTool(
  "classify",
  {
    description:
      "Classify a short piece of text or a file's content into exactly one " +
      "of `labels`, using the local Ollama model -- only the chosen label " +
      "is returned. Set `isPath: true` to have this server read " +
      "`pathOrText` as a file path from disk (recommended for anything " +
      "beyond a short snippet, so the content never enters the caller's " +
      "context); when `isPath` is false/omitted, `pathOrText` is treated " +
      "as literal text and should stay short -- passing bulk file content " +
      "directly here defeats the point of this server, use `isPath: true` " +
      "instead. `startLine`/`endLine` only apply when `isPath` is true. " +
      `Large files are truncated to ${MAX_INPUT_CHARS} characters -- check ` +
      "the `truncated` field in the result.",
    inputSchema: {
      pathOrText: z.string().describe("A file path (if isPath: true) or a short literal text/snippet."),
      isPath: z
        .boolean()
        .optional()
        .describe("If true, treat pathOrText as a file path and read it from disk. Default false."),
      labels: z
        .array(z.string())
        .min(2)
        .describe("Candidate labels; the model picks exactly one."),
      ...lineRangeShape,
    },
  },
  async ({ pathOrText, isPath, labels, startLine, endLine }, extra) => {
    let content: string;
    let truncated = false;
    let truncatedChars = 0;

    if (isPath) {
      const slice = await readFileSlice(pathOrText, startLine, endLine);
      if (!slice.ok) {
        return { content: [{ type: "text", text: JSON.stringify({ error: slice.error }) }], isError: true };
      }
      content = slice.content;
      truncated = slice.truncated;
      truncatedChars = slice.truncatedChars;
    } else {
      content = pathOrText;
      if (content.length > MAX_INPUT_CHARS) {
        truncated = true;
        truncatedChars = content.length - MAX_INPUT_CHARS;
        content = content.slice(0, MAX_INPUT_CHARS);
      }
    }

    const prompt =
      "Classify the following content into exactly one of these labels: " +
      `${JSON.stringify(labels)}.\n\n--- CONTENT START ---\n${content}\n--- CONTENT END ---`;

    const generated = await generateStructured(
      prompt,
      {
        type: "object",
        properties: { label: { type: "string", enum: labels } },
        required: ["label"],
      },
      makeProgressNotifier(extra),
    );
    if (!generated.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: generated.error }) }], isError: true };
    }

    const label = generated.value.label;
    if (typeof label !== "string" || !labels.includes(label)) {
      // Should be unreachable -- generateStructured already validated
      // 'label' is a string in `labels` via the schema's `enum` above -- but
      // kept as a defensive backstop for the same reason as
      // summarize_file's 'summary' check above.
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({
              error: `model returned an invalid label: ${JSON.stringify(label)}`,
            }),
          },
        ],
        isError: true,
      };
    }

    const result = { label, truncated, ...(truncated ? { truncatedChars } : {}) };
    return { content: [{ type: "text", text: JSON.stringify(result, null, 2) }] };
  },
);

export interface HealthResult {
  reachable: boolean;
  host: string;
  model: string;
  error?: string;
}

/** GETs /api/tags on the configured Ollama host. Degrades gracefully: any
 * network error, non-2xx response, or timeout is reported, never thrown.
 *
 * Exported (bead claude-dha), along with two parameters that default to this
 * module's real behavior and only exist so health.test.ts can exercise this
 * function's actual logic -- not a re-implementation of it -- with a mocked
 * `fetch` and a short timeout instead of the real network and
 * HEALTH_CHECK_TIMEOUT_MS's 3s: `fetchImpl` (defaults to the global `fetch`)
 * and `timeoutMs` (defaults to HEALTH_CHECK_TIMEOUT_MS), matching the same
 * injectable-timeout pattern `callOllamaGenerate` already uses below. Neither
 * parameter changes this function's behavior for its one real caller (the
 * `health` tool handler above), which calls it with no arguments. */
export async function checkOllamaHealth(
  fetchImpl: typeof fetch = fetch,
  timeoutMs: number = HEALTH_CHECK_TIMEOUT_MS,
): Promise<HealthResult> {
  const base: HealthResult = { reachable: false, host: OLLAMA_HOST, model: OLLAMA_MODEL };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(`${OLLAMA_HOST}/api/tags`, { signal: controller.signal });
    if (!response.ok) {
      await response.body?.cancel();
      return { ...base, error: `HTTP ${response.status} ${response.statusText}` };
    }
    // We only need reachability, not the /api/tags body: cancel the stream
    // (releases the socket) instead of buffering/parsing it, same as the
    // non-OK branch above.
    await response.body?.cancel();
    return { ...base, reachable: true };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ...base, error: message };
  } finally {
    clearTimeout(timer);
  }
}

type SliceResult =
  | { ok: true; content: string; truncated: boolean; truncatedChars: number }
  | { ok: false; error: string };

type ResolvedPathResult = { ok: true; path: string } | { ok: false; error: string };

/** Resolves a caller-supplied path against WORKSPACE_ROOT and verifies --
 * after following symlinks -- that it still lands inside WORKSPACE_ROOT.
 * This is the sandboxing boundary for every tool that reads a file from
 * disk: an absolute path (e.g. `/etc/passwd`), a `../` traversal out of the
 * root, or a symlink inside the root that points outside it are all
 * rejected. Never throws -- returns a result so callers can turn this into
 * a normal `isError: true` tool response instead of a thrown exception. */
async function resolveWorkspacePath(input: string): Promise<ResolvedPathResult> {
  // path.resolve processes its arguments right-to-left and stops as soon as
  // an absolute path is constructed, so an absolute `input` here makes
  // WORKSPACE_ROOT irrelevant to the resolution itself (Node's documented
  // behavior) -- that's fine, because the containment check below rejects
  // the result unless it's still inside WORKSPACE_ROOT either way.
  const candidate = path.resolve(WORKSPACE_ROOT, input);
  if (candidate !== WORKSPACE_ROOT && !candidate.startsWith(WORKSPACE_ROOT + path.sep)) {
    return { ok: false, error: `path '${input}' resolves outside the workspace root (${WORKSPACE_ROOT})` };
  }

  let real: string;
  try {
    real = await realpath(candidate);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, error: `failed to resolve '${input}': ${message}` };
  }
  if (real !== WORKSPACE_ROOT && !real.startsWith(WORKSPACE_ROOT + path.sep)) {
    return {
      ok: false,
      error: `path '${input}' resolves outside the workspace root (${WORKSPACE_ROOT}) after following symlinks`,
    };
  }
  return { ok: true, path: real };
}

/** Reads a file from disk (never from a tool argument -- this is the crux of
 * the "reference-based" design: the file body only ever exists inside this
 * process, not in anything the caller sent or anything we send back). The
 * path is first confined to WORKSPACE_ROOT (see `resolveWorkspacePath`) and
 * size-capped (see MAX_FILE_SIZE_BYTES) before any content is read. If
 * `startLine`/`endLine` are given (1-indexed, inclusive), only that line
 * range is streamed off disk -- reading stops at `endLine` rather than
 * buffering the whole file. Otherwise, only enough bytes to cover
 * MAX_INPUT_CHARS after decoding are read. Content beyond MAX_INPUT_CHARS is
 * truncated, reported via `truncated`/`truncatedChars` rather than silently
 * dropped. Never throws -- I/O errors (missing file, permission denied, path
 * is a directory, etc.) are reported as a result, matching the
 * graceful-degradation style of `checkOllamaHealth`. */
async function readFileSlice(inputPath: string, startLine?: number, endLine?: number): Promise<SliceResult> {
  const resolved = await resolveWorkspacePath(inputPath);
  if (!resolved.ok) {
    return { ok: false, error: resolved.error };
  }

  let fileStat;
  try {
    fileStat = await stat(resolved.path);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, error: `failed to read '${inputPath}': ${message}` };
  }
  if (!fileStat.isFile()) {
    return { ok: false, error: `failed to read '${inputPath}': not a regular file` };
  }
  if (fileStat.size > MAX_FILE_SIZE_BYTES) {
    return {
      ok: false,
      error: `failed to read '${inputPath}': file is ${fileStat.size} bytes, exceeds the ${MAX_FILE_SIZE_BYTES}-byte limit for this tool`,
    };
  }

  try {
    if (startLine === undefined && endLine === undefined) {
      return await readBounded(resolved.path, fileStat.size);
    }

    const start = Math.max(1, startLine ?? 1);
    if (endLine !== undefined && start > endLine) {
      return { ok: false, error: `startLine (${start}) is after endLine (${endLine})` };
    }
    return await readLineRange(resolved.path, start, endLine);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return { ok: false, error: `failed to read '${inputPath}': ${message}` };
  }
}

/** UTF-8 sequences are at most `MAX_UTF8_BYTES_PER_CHAR` bytes. Scans
 * backward from `length` (at most `MAX_UTF8_BYTES_PER_CHAR - 1` bytes, since
 * that's the longest possible run of continuation bytes before a lead byte)
 * to find the start of the last character in `buffer[0, length)`, then
 * checks whether that character's full byte sequence actually fits within
 * `length`. If the read stopped mid-character, returns a shorter length that
 * excludes the incomplete trailing sequence -- without this, decoding a
 * buffer that was cut off mid-character silently substitutes the incomplete
 * tail with U+FFFD (`Buffer.toString("utf8")`'s behaviour), which is
 * corrupted content at the truncation boundary, not just an expected
 * truncation artifact. */
function trimIncompleteUtf8Tail(buffer: Buffer, length: number): number {
  if (length === 0) {
    return 0;
  }
  let leadIndex = length - 1;
  let scanned = 0;
  // Continuation bytes match 10xxxxxx (0x80 bit set, 0x40 bit clear).
  while (leadIndex >= 0 && scanned < MAX_UTF8_BYTES_PER_CHAR - 1 && (buffer[leadIndex] & 0xc0) === 0x80) {
    leadIndex--;
    scanned++;
  }
  if (leadIndex < 0) {
    // Nothing but continuation bytes all the way back -- can't tell where
    // the character starts; drop the whole thing rather than guess.
    return 0;
  }
  const leadByte = buffer[leadIndex];
  let seqLen: number;
  if ((leadByte & 0x80) === 0x00) {
    seqLen = 1; // 0xxxxxxx
  } else if ((leadByte & 0xe0) === 0xc0) {
    seqLen = 2; // 110xxxxx
  } else if ((leadByte & 0xf0) === 0xe0) {
    seqLen = 3; // 1110xxxx
  } else if ((leadByte & 0xf8) === 0xf0) {
    seqLen = 4; // 11110xxx
  } else {
    // Not a valid UTF-8 lead byte -- this isn't a truncation artifact we can
    // fix by trimming; leave it as-is for toString to handle.
    return length;
  }
  return leadIndex + seqLen <= length ? length : leadIndex;
}

/** Reads up to enough bytes to cover MAX_INPUT_CHARS after UTF-8 decoding
 * (MAX_UTF8_BYTES_PER_CHAR bytes/char is UTF-8's worst case), instead of
 * always buffering the whole file. `fileSize` is already known to be
 * <= MAX_FILE_SIZE_BYTES by the caller's `stat` check; this bounds the read
 * further, to roughly what MAX_INPUT_CHARS could ever need, for files
 * larger than that. Before decoding, `trimIncompleteUtf8Tail` drops any
 * multi-byte character left incomplete by the byte cap, so decoding only
 * ever sees whole characters (see its doc comment). */
async function readBounded(filePath: string, fileSize: number): Promise<SliceResult> {
  const maxBytes = Math.min(fileSize, MAX_INPUT_CHARS * MAX_UTF8_BYTES_PER_CHAR);
  const handle = await open(filePath, "r");
  try {
    const buffer = Buffer.alloc(maxBytes);
    const { bytesRead } = await handle.read(buffer, 0, maxBytes, 0);
    const safeLength = trimIncompleteUtf8Tail(buffer, bytesRead);
    const raw = buffer.subarray(0, safeLength).toString("utf8");
    const droppedTailBytes = bytesRead - safeLength;

    if (raw.length > MAX_INPUT_CHARS) {
      return {
        ok: true,
        content: raw.slice(0, MAX_INPUT_CHARS),
        truncated: true,
        truncatedChars: raw.length - MAX_INPUT_CHARS,
      };
    }
    if (bytesRead < fileSize || droppedTailBytes > 0) {
      // We stopped short of EOF (the file is larger than our byte cap),
      // and/or dropped an incomplete multi-byte sequence off the read tail --
      // either way there's real content beyond `raw` that was never decoded.
      // Still truncated; report the remaining byte count (including any
      // dropped partial-character bytes) as a lower-bound estimate of
      // truncatedChars rather than an exact character count.
      return { ok: true, content: raw, truncated: true, truncatedChars: fileSize - bytesRead + droppedTailBytes };
    }
    return { ok: true, content: raw, truncated: false, truncatedChars: 0 };
  } finally {
    await handle.close();
  }
}

/** Streams `filePath` line-by-line and collects lines `start`..`endLine`
 * (1-indexed, inclusive), stopping as soon as `endLine` is read, at EOF, or
 * once the collected content already exceeds MAX_INPUT_CHARS -- whichever
 * comes first -- rather than reading/splitting the whole file. That last
 * condition matters because `endLine` is often omitted ("read from line N to
 * the end"): without it, an open-ended range against a large file would
 * accumulate every remaining line in memory before ever reaching the
 * MAX_INPUT_CHARS truncation below, reintroducing the "hold far more than
 * needed" cost this streaming approach exists to avoid. The collected range
 * is then truncated to MAX_INPUT_CHARS same as `readBounded`. */
async function readLineRange(filePath: string, start: number, endLine?: number): Promise<SliceResult> {
  const stream = createReadStream(filePath, { encoding: "utf8" });
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  const collected: string[] = [];
  let lineNo = 0;
  let collectedChars = 0;
  try {
    for await (const line of rl) {
      lineNo++;
      if (lineNo < start) {
        continue;
      }
      if (endLine !== undefined && lineNo > endLine) {
        break;
      }
      collected.push(line);
      collectedChars += line.length;
      if (endLine !== undefined && lineNo === endLine) {
        break;
      }
      if (collectedChars > MAX_INPUT_CHARS) {
        // Already collected more than the final result can ever contain --
        // stop streaming now instead of continuing to `endLine`/EOF. The
        // truncatedChars reported below is computed from what we actually
        // collected, same as the endLine-bounded case, so this is still an
        // accurate (if early-stopped) accounting.
        break;
      }
    }
  } finally {
    rl.close();
    stream.destroy();
  }

  if (collected.length === 0) {
    return {
      ok: false,
      error: `startLine (${start}) is after endLine (${endLine ?? "end of file"}) or past end of file`,
    };
  }

  const content = collected.join("\n");
  if (content.length > MAX_INPUT_CHARS) {
    const truncatedChars = content.length - MAX_INPUT_CHARS;
    return { ok: true, content: content.slice(0, MAX_INPUT_CHARS), truncated: true, truncatedChars };
  }
  return { ok: true, content, truncated: false, truncatedChars: 0 };
}

type GenerateResult = { ok: true; response: string } | { ok: false; error: string };

/** Shape written into the lock file at acquire time and read back by a
 * blocked caller (to judge staleness) or by `releaseGenerateLock` (to verify
 * ownership before deleting). `token` is a fresh `randomUUID()` per
 * acquisition -- see `acquireGenerateLock`/`releaseGenerateLock`'s doc
 * comments for why this exists (claude-6ll review finding: without it,
 * release couldn't tell "my lock" from "someone else's lock that now happens
 * to sit at the same path"). */
interface LockHolder {
  pid?: number;
  acquiredAt?: number;
  token?: string;
}

/** Options accepted by `acquireGenerateLock`/`releaseGenerateLock` purely for
 * lock.test.ts's benefit, matching the same injectable-parameter pattern
 * `checkOllamaHealth` already uses (see its doc comment): `lockPath` and
 * `staleMs` default to this module's real `GENERATE_LOCK_PATH`/
 * `GENERATE_LOCK_STALE_MS`, and `isPidAlive` defaults to a real
 * `process.kill(pid, 0)` liveness check. None of these change
 * `callOllamaGenerate`'s behavior, which calls both functions with no
 * options. */
export interface GenerateLockOptions {
  lockPath?: string;
  staleMs?: number;
  isPidAlive?: (pid: number) => boolean;
}

/** Best-effort liveness check for a pid recorded in a lock file: sends
 * signal 0 (per `process.kill`'s documented meaning -- no actual signal is
 * delivered, only existence/permission is checked). `ESRCH` ("no such
 * process") means the pid is definitely dead -- the recorded holder can
 * never come back and finish releasing its own lock, so its lock should be
 * treated as immediately stale regardless of how recently `acquiredAt`
 * claims it was written (this is the fix for review finding #2: a
 * self-reported timestamp alone can't be trusted to reflect a live holder).
 * Any other error (most commonly `EPERM`, a live process this uid can't
 * signal) is treated as "alive" -- the safer default, since falsely calling
 * a live holder dead would let a second caller reclaim its lock and run
 * concurrently, exactly the bug this whole lock exists to prevent. */
function isPidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error && typeof error === "object" && "code" in error && error.code === "ESRCH") {
      return false;
    }
    return true;
  }
}

/** Reads and loosely parses a lock file's contents, tolerating a
 * missing/corrupt/unreadable file by returning `undefined` rather than
 * throwing -- callers treat `undefined` the same as "indeterminate," which
 * is always judged stale/reclaimable (safer than trusting an age or pid we
 * couldn't actually determine). */
async function readLockHolder(lockPath: string): Promise<LockHolder | undefined> {
  try {
    const raw = JSON.parse(await readFile(lockPath, "utf8")) as Record<string, unknown>;
    return {
      pid: typeof raw.pid === "number" ? raw.pid : undefined,
      acquiredAt: typeof raw.acquiredAt === "number" ? raw.acquiredAt : undefined,
      token: typeof raw.token === "string" ? raw.token : undefined,
    };
  } catch {
    return undefined;
  }
}

/** Attempts to atomically create the lock file via the `wx` open flag (fails
 * with EEXIST if the file already exists) -- the standard dependency-free
 * pattern for a filesystem-based mutex, since file creation with O_EXCL is
 * atomic at the OS level (no separate exists-check-then-create race). The
 * file is created with an explicit `0o600` mode (review finding #2) rather
 * than Node's default (`0o666` minus umask) -- on a host where `tmpdir()` is
 * shared by more than one local uid, a default-mode lock file would be
 * writable/forgeable by any other local process. On success, writes this
 * process's pid, acquisition time, and a fresh per-acquisition `token`
 * (`randomUUID()`) into the file and reports "acquired" with that token --
 * the caller must pass the token back to `releaseGenerateLock` when done.
 *
 * On EEXIST, judges the existing holder stale (and reclaims it: unlink +
 * one retry of the create) if *either*:
 *   - its recorded pid is no longer alive (`isPidAlive`, review finding #2 --
 *     a dead holder can never release its own lock, so age is irrelevant), or
 *   - it's older than `staleMs` (default `GENERATE_LOCK_STALE_MS`) -- the
 *     original crashed-holder heuristic, kept as a fallback for a holder
 *     whose pid is still alive but wedged (e.g. this process is still
 *     running, but its in-flight call has hung well past what a legitimate
 *     call could ever take).
 * Otherwise reports "busy" with how long the current holder has held it
 * (surfaced in the caller-facing error message so a busy response is
 * diagnosable, not just "try again"). Never throws: any unexpected
 * lock-mechanics failure (permissions, a missing/unwritable tmpdir, ...)
 * reports "unavailable" so the caller falls back to today's
 * pre-claude-6ll behavior (proceed without cross-process coordination)
 * rather than making every generate call fail because an ancillary
 * coordination mechanism broke -- this lock is a best-effort mitigation for
 * measured contention, not a correctness boundary this tool depends on to
 * function at all. */
export async function acquireGenerateLock(options: GenerateLockOptions = {}): Promise<LockAcquireResult> {
  const lockPath = options.lockPath ?? GENERATE_LOCK_PATH;
  const staleMs = options.staleMs ?? GENERATE_LOCK_STALE_MS;
  const pidAlive = options.isPidAlive ?? isPidAlive;

  const tryCreate = async (): Promise<
    { result: "acquired"; token: string } | { result: "exists" } | { result: "unavailable" }
  > => {
    const token = randomUUID();
    try {
      const handle = await open(lockPath, "wx", 0o600);
      try {
        await handle.writeFile(JSON.stringify({ pid: process.pid, acquiredAt: Date.now(), token }));
      } finally {
        await handle.close();
      }
      return { result: "acquired", token };
    } catch (error) {
      if (error && typeof error === "object" && "code" in error && error.code === "EEXIST") {
        return { result: "exists" };
      }
      console.error(`ollama-mcp: could not acquire generate lock (${lockPath}), proceeding without it:`, error);
      return { result: "unavailable" };
    }
  };

  const first = await tryCreate();
  if (first.result !== "exists") {
    return first.result === "acquired" ? { state: "acquired", token: first.token } : { state: "unavailable" };
  }

  const holder = await readLockHolder(lockPath);
  const holderAlive = holder?.pid === undefined ? true : pidAlive(holder.pid);
  const heldForMs = holder?.acquiredAt === undefined ? Number.POSITIVE_INFINITY : Date.now() - holder.acquiredAt;
  const isStale = !holderAlive || heldForMs > staleMs;

  if (!isStale) {
    return { state: "busy", heldForMs };
  }

  // Stale -- reclaim it. Best-effort: re-read the file immediately before
  // unlinking and only proceed if it's either gone already or still the same
  // holder (by token) we just judged stale -- this narrows (without fully
  // closing) the window where another process reclaimed the exact same
  // stale lock a moment ago and this call would otherwise unlink *that*
  // fresh, legitimate lock instead of the one it actually judged stale.
  // Either way, one more create attempt decides the outcome; if that retry
  // still finds it occupied (another process reclaimed and re-acquired
  // first), report "busy" rather than looping further -- bounded to a single
  // reclaim attempt per call, same fail-fast philosophy as the rest of this
  // lock.
  try {
    const current = await readLockHolder(lockPath);
    if (!current || current.token === holder?.token) {
      await unlink(lockPath);
    }
    // else: someone else already reclaimed this exact lock since we judged
    // it stale -- leave their fresh lock alone and let the retry below
    // report "busy" against it.
  } catch {
    // Already gone / lost the race -- fall through to the retry below.
  }
  const retry = await tryCreate();
  if (retry.result === "acquired") {
    return { state: "acquired", token: retry.token };
  }
  if (retry.result === "unavailable") {
    return { state: "unavailable" };
  }
  return { state: "busy", heldForMs: 0 };
}

/** Releases a lock previously acquired by `acquireGenerateLock` (only ever
 * called when that returned `{ state: "acquired", token }` -- never for
 * "unavailable", which never created the file, or "busy", which never held
 * it). `token` must be the exact value `acquireGenerateLock` returned for
 * this acquisition.
 *
 * Before deleting anything, reads the file back and only unlinks it if its
 * recorded `token` still matches this call's own `token` -- if the file is
 * missing (e.g. reclaimed by another process as stale while this call was
 * still finishing, an edge case bounded by `staleMs`) or its token belongs to
 * a *different* acquisition, this is a no-op. This is the fix for review
 * finding #1 (critical): the previous unconditional `unlink` deleted
 * whatever currently sat at the lock path with no ownership check, so a
 * holder whose call ran past `GENERATE_LOCK_STALE_MS` (without crashing --
 * e.g. slow under memory pressure) could have its lock reclaimed by a second
 * caller, finish, and then delete *that second caller's* still-live lock in
 * its own `finally`, letting a third caller acquire immediately and run
 * concurrently with the second -- silently defeating the mutual exclusion
 * this lock exists to provide. Comparing tokens instead of blindly unlinking
 * closes that hole: a late release from a reclaimed-out holder now correctly
 * recognizes it no longer owns the lock and leaves the current legitimate
 * holder's file untouched. */
export async function releaseGenerateLock(token: string, options: GenerateLockOptions = {}): Promise<void> {
  const lockPath = options.lockPath ?? GENERATE_LOCK_PATH;
  try {
    const holder = await readLockHolder(lockPath);
    if (!holder || holder.token !== token) {
      // Missing (already gone), or present but owned by a different
      // acquisition (reclaimed out from under us) -- nothing of ours to
      // remove either way. Silently skip rather than unlink a lock we don't
      // currently own.
      return;
    }
    await unlink(lockPath);
  } catch (error) {
    console.error(`ollama-mcp: failed to release generate lock (${lockPath}), leaving it in place:`, error);
  }
}

/** POSTs a single non-streaming prompt to /api/generate, optionally
 * constraining the output with Ollama's structured-output `format` field
 * (either the literal string "json" or a JSON-Schema-like object -- see
 * https://ollama.com/blog/structured-outputs). Never throws: network
 * errors, non-2xx responses, and timeouts are all reported as a result,
 * same pattern as `checkOllamaHealth`. `timeoutMs` defaults to
 * GENERATE_TIMEOUT_MS but can be overridden -- `generateStructured` passes
 * a shorter RETRY_TIMEOUT_MS for its retry call (see that constant's doc
 * comment for why).
 *
 * claude-6ll: every call first goes through `acquireGenerateLock` -- a
 * cross-process, fail-fast serialization point (see its doc comment and
 * GENERATE_LOCK_PATH's for why this exists and why it fails fast instead of
 * queueing). A caller that finds the sidecar already busy gets an immediate,
 * clearly-worded error here and never even issues the HTTP request -- it
 * does NOT wait, since the measured single-call latency on this sidecar
 * (~35-40s) leaves too little of GENERATE_TIMEOUT_MS's budget to wait
 * through another full call first. Note this only serializes calls this
 * lock actually knows about: an abandoned call (client gave up at
 * GENERATE_TIMEOUT_MS but Ollama may still be processing it server-side
 * after this releases the lock) can still leave a brief window where a
 * freshly-acquiring caller's request lands on a still-busy sidecar anyway --
 * a residual gap this fail-fast design doesn't fully close, documented in
 * README's "Concurrent-session contention" section. */
async function callOllamaGenerate(
  prompt: string,
  format?: "json" | Record<string, unknown>,
  timeoutMs: number = GENERATE_TIMEOUT_MS,
): Promise<GenerateResult> {
  const lock = await acquireGenerateLock();
  if (lock.state === "busy") {
    const heldForDescription = Number.isFinite(lock.heldForMs) ? `${Math.round(lock.heldForMs / 1000)}s` : "an indeterminate time";
    return {
      ok: false,
      error:
        "ollama sidecar is busy serving another generate request from a different ollama-mcp session on this " +
        `host (held for ~${heldForDescription}). This CPU-only, single-instance sidecar was measured to fail ` +
        "concurrent /api/generate calls rather than queue them gracefully within the timeout budget (see " +
        "README's \"Concurrent-session contention\" section) -- retry shortly once the other session's call " +
        "finishes.",
    };
  }

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(`${OLLAMA_HOST}/api/generate`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: OLLAMA_MODEL,
        prompt,
        stream: false,
        ...(format !== undefined ? { format } : {}),
      }),
      signal: controller.signal,
    });
    if (!response.ok) {
      const body = await response.text().catch(() => "");
      return { ok: false, error: `HTTP ${response.status} ${response.statusText}${body ? `: ${body}` : ""}` };
    }
    const body = (await response.json()) as { response?: unknown };
    if (typeof body.response !== "string") {
      return { ok: false, error: "Ollama response missing string 'response' field" };
    }
    return { ok: true, response: body.response };
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const timedOut = error instanceof Error && error.name === "AbortError";
    return { ok: false, error: timedOut ? `timed out after ${timeoutMs}ms` : message };
  } finally {
    clearTimeout(timer);
    if (lock.state === "acquired") {
      await releaseGenerateLock(lock.token);
    }
  }
}

type StructuredGenerateResult = { ok: true; value: Record<string, unknown> } | { ok: false; error: string };

/**
 * Issues `prompt` to Ollama with `schema` as the structured-output `format`
 * constraint, then parses and validates the response against `schema` (see
 * `parseAndValidateJson`/`validateAgainstSchema` in `validate.ts`) -- not
 * just "is it JSON, is it an object" as the pre-claude-r30.5
 * `parseJsonObject` did. Small CPU-only models don't reliably honor `format`
 * even when it's passed (this bead's premise): if the first response fails
 * to parse or fails validation, this re-issues the *identical* prompt
 * exactly once and validates that response the same way -- a second sample
 * from the same model on the same input often succeeds where the first
 * didn't. If the retry also fails, this returns `ok: false` describing what
 * was wrong with the last attempt; it never returns a best-guess or
 * partially-parsed value (claude-r30.5's acceptance criterion: malformed
 * model output must surface as an error, not be passed through as a
 * result). Shared by `summarize_file`, `extract`, and `classify` so this
 * retry+validate behavior isn't duplicated three times.
 *
 * A network/timeout failure from `callOllamaGenerate` itself (as opposed to
 * a malformed *response*) is NOT retried here -- that's a different failure
 * mode (Ollama may be down or overloaded, not just having produced bad
 * output), and retrying a genuinely unreachable/overloaded Ollama on every
 * call isn't worth it for this bead's scope. The retry call itself also
 * uses a shorter RETRY_TIMEOUT_MS rather than the first attempt's full
 * GENERATE_TIMEOUT_MS -- see that constant's doc comment for why (bounding
 * the combined worst-case latency of a single tool call).
 *
 * `notify` (bead claude-lp5) is invoked periodically -- see
 * `withPeriodicProgress`/`PROGRESS_INTERVAL_MS` in `progress.ts` -- while
 * each of `callOllamaGenerate`'s two calls (the first attempt and the
 * retry) is in flight, so a compliant MCP client that requested progress
 * notifications keeps getting its timeout clock reset across the combined
 * ~90s worst case, instead of only finding out the call finished (or hit
 * the server's own timeout) at the very end. Defaults to
 * `NO_OP_PROGRESS_NOTIFIER` so this is safe to call without one (e.g. from
 * a test) -- callers in this file always pass a real notifier built via
 * `makeProgressNotifier`, which itself is a no-op unless the caller's
 * request carried a `progressToken`.
 */
async function generateStructured(
  prompt: string,
  schema: JsonSchema,
  notify: ProgressNotifier = NO_OP_PROGRESS_NOTIFIER,
): Promise<StructuredGenerateResult> {
  const first = await withPeriodicProgress(callOllamaGenerate(prompt, schema), notify);
  if (!first.ok) {
    return { ok: false, error: first.error };
  }
  const firstResult = parseAndValidateJson(first.response, schema);
  if (firstResult.ok) {
    return firstResult;
  }

  const retry = await withPeriodicProgress(callOllamaGenerate(prompt, schema, RETRY_TIMEOUT_MS), notify);
  if (!retry.ok) {
    return {
      ok: false,
      error: `retry after malformed response failed: ${retry.error} (first attempt was invalid: ${firstResult.error})`,
    };
  }
  const retryResult = parseAndValidateJson(retry.response, schema);
  if (!retryResult.ok) {
    return {
      ok: false,
      error: `model response was still invalid after one retry: ${retryResult.error} (first attempt was also invalid: ${firstResult.error})`,
    };
  }
  return retryResult;
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("ollama-mcp running on stdio");
}

// Only start the stdio server when this module is the process entry point
// (`node dist/index.js`, matching package.json's `start` script), not when
// it's merely `import`ed -- e.g. by health.test.ts (bead claude-dha), which
// needs `checkOllamaHealth`/`pingResult` without also connecting a real
// StdioServerTransport (which would hang the test runner listening on
// stdin). `process.argv[1]` is the entry script's path; comparing it against
// this module's own resolved path is the standard ESM equivalent of
// CommonJS's `require.main === module`.
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error("ollama-mcp fatal error:", error);
    process.exit(1);
  });
}
