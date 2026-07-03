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
import { createReadStream } from "node:fs";
import { open, realpath, stat } from "node:fs/promises";
import * as path from "node:path";
import * as readline from "node:readline";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

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

server.registerTool(
  "ping",
  {
    description:
      "Trivial reachability check for this MCP server itself. Returns a " +
      "static ok — does not contact Ollama. Use `health` to check Ollama.",
    inputSchema: {},
  },
  async () => ({
    content: [{ type: "text", text: JSON.stringify({ ok: true }) }],
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
  async ({ path, focus, startLine, endLine }) => {
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

    const generated = await callOllamaGenerate(prompt, {
      type: "object",
      properties: { summary: { type: "string" } },
      required: ["summary"],
    });
    if (!generated.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: generated.error }) }], isError: true };
    }

    const parsed = parseJsonObject(generated.response);
    if (!parsed.ok) {
      return {
        content: [{ type: "text", text: JSON.stringify({ error: parsed.error }) }],
        isError: true,
      };
    }

    const summary = parsed.value.summary;
    if (typeof summary !== "string") {
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
      "match it. This is best-effort: on a small model the output can " +
      "still fail to match `schema` or fail to parse as JSON at all -- in " +
      "either case this tool returns isError:true with a clear message " +
      "rather than returning garbage silently. (Schema validation + " +
      "retry-on-malformed-JSON is tracked separately as claude-r30.5.) " +
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
  async ({ path, schema, startLine, endLine }) => {
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

    const generated = await callOllamaGenerate(prompt, schema as Record<string, unknown>);
    if (!generated.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: generated.error }) }], isError: true };
    }

    const parsed = parseJsonObject(generated.response);
    if (!parsed.ok) {
      return {
        content: [{ type: "text", text: JSON.stringify({ error: parsed.error }) }],
        isError: true,
      };
    }

    const result = {
      data: parsed.value,
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
  async ({ pathOrText, isPath, labels, startLine, endLine }) => {
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

    const generated = await callOllamaGenerate(prompt, {
      type: "object",
      properties: { label: { type: "string", enum: labels } },
      required: ["label"],
    });
    if (!generated.ok) {
      return { content: [{ type: "text", text: JSON.stringify({ error: generated.error }) }], isError: true };
    }

    const parsed = parseJsonObject(generated.response);
    if (!parsed.ok) {
      return {
        content: [{ type: "text", text: JSON.stringify({ error: parsed.error }) }],
        isError: true,
      };
    }

    const label = parsed.value.label;
    if (typeof label !== "string" || !labels.includes(label)) {
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

interface HealthResult {
  reachable: boolean;
  host: string;
  model: string;
  error?: string;
}

/** GETs /api/tags on the configured Ollama host. Degrades gracefully: any
 * network error, non-2xx response, or timeout is reported, never thrown. */
async function checkOllamaHealth(): Promise<HealthResult> {
  const base: HealthResult = { reachable: false, host: OLLAMA_HOST, model: OLLAMA_MODEL };
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), HEALTH_CHECK_TIMEOUT_MS);
  try {
    const response = await fetch(`${OLLAMA_HOST}/api/tags`, { signal: controller.signal });
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

/** POSTs a single non-streaming prompt to /api/generate, optionally
 * constraining the output with Ollama's structured-output `format` field
 * (either the literal string "json" or a JSON-Schema-like object -- see
 * https://ollama.com/blog/structured-outputs). Never throws: network
 * errors, non-2xx responses, and timeouts are all reported as a result,
 * same pattern as `checkOllamaHealth`. */
async function callOllamaGenerate(
  prompt: string,
  format?: "json" | Record<string, unknown>,
): Promise<GenerateResult> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), GENERATE_TIMEOUT_MS);
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
    return { ok: false, error: timedOut ? `timed out after ${GENERATE_TIMEOUT_MS}ms` : message };
  } finally {
    clearTimeout(timer);
  }
}

type ParseResult = { ok: true; value: Record<string, unknown> } | { ok: false; error: string };

/** Parses a model's raw text response as a JSON object. Best-effort per this
 * bead's scope (claude-r30.5 tracks schema validation + retry-on-malformed):
 * this only guards against non-JSON or non-object output, returning a clear
 * error instead of passing garbage through as if it were valid structured
 * data. */
function parseJsonObject(text: string): ParseResult {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return { ok: false, error: `model did not return valid JSON: ${truncateForError(text)}` };
  }
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    return { ok: false, error: `model returned JSON that is not an object: ${truncateForError(text)}` };
  }
  return { ok: true, value: value as Record<string, unknown> };
}

/** Caps an error-message excerpt of a (potentially large, malformed) model
 * response so a bad response can't itself blow up the result size. */
function truncateForError(text: string): string {
  const limit = 200;
  return text.length > limit ? `${text.slice(0, limit)}...` : text;
}

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("ollama-mcp running on stdio");
}

main().catch((error) => {
  console.error("ollama-mcp fatal error:", error);
  process.exit(1);
});
