// One-off measurement script for claude-r30.7: drives the *real* ollama-mcp
// stdio server (via the actual MCP client SDK, exactly as Claude Code would)
// against real repo files, and separately calls Ollama's own /api/generate
// with an equivalent prompt to capture Ollama's own reported token counts
// (prompt_eval_count/eval_count) for the "after" side of the write-up.
// Not part of the server; ad hoc, throwaway-but-kept for reproducibility.
// Run from repo root: node tools/ollama-mcp/measure-tokens.mjs
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { readFile } from "node:fs/promises";
import path from "node:path";

const REPO_ROOT = "/workspace";
const OLLAMA_HOST = process.env.OLLAMA_HOST ?? "http://ollama:11434";
const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? "llama3.2:3b";
// Duplicated from src/index.ts's MAX_INPUT_CHARS (not imported): this script
// is plain ESM run directly via `node` against the checked-in .mjs file, not
// through the TS build, and src/index.ts only exists compiled at
// dist/index.js (no separate constants module to import from without
// pulling in the rest of the server's module graph). If src/index.ts's
// MAX_INPUT_CHARS ever changes, this literal must be updated to match, or
// this script's own "truncated"/"before" numbers (computed independently in
// sliceForDirect below) will silently desync from the real server behavior.
const MAX_INPUT_CHARS = 12_000;

function charsToTokensEstimate(chars) {
  return Math.round(chars / 4);
}

// Default of 60_000 mirrors src/index.ts's GENERATE_TIMEOUT_MS (also
// duplicated, not imported -- see the MAX_INPUT_CHARS comment above for why).
// Keep in sync with that constant if it changes.
async function directOllamaGenerate(prompt, format, timeoutMs = 60_000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  const t0 = Date.now();
  try {
    const res = await fetch(`${OLLAMA_HOST}/api/generate`, {
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
    const body = await res.json();
    return {
      ok: res.ok,
      status: res.status,
      wallMs: Date.now() - t0,
      response: body.response,
      prompt_eval_count: body.prompt_eval_count,
      eval_count: body.eval_count,
      total_duration_ms: body.total_duration ? Math.round(body.total_duration / 1e6) : undefined,
    };
  } finally {
    clearTimeout(timer);
  }
}

async function main() {
  const results = { mcp: [], direct: [] };

  // --- 1. Real MCP round trip, exactly as Claude Code would drive it ---
  const transport = new StdioClientTransport({
    command: "node",
    args: [path.join(REPO_ROOT, "tools/ollama-mcp/dist/index.js")],
    cwd: REPO_ROOT,
    env: { OLLAMA_HOST, OLLAMA_MODEL, WORKSPACE_ROOT: REPO_ROOT, PATH: process.env.PATH },
  });
  const client = new Client({ name: "measure-tokens", version: "0.0.0" });
  await client.connect(transport);

  const calls = [
    {
      label: "summarize_file(tools/run-overnight.sh) [large file, expect truncation]",
      name: "summarize_file",
      args: { path: "tools/run-overnight.sh" },
    },
    {
      label: "summarize_file(commands/analyze-telemetry.md) [small file, no truncation]",
      name: "summarize_file",
      args: { path: "commands/analyze-telemetry.md" },
    },
    {
      label: "extract(.beads/issues.jsonl line 1) [structured extraction from prose]",
      name: "extract",
      args: {
        path: ".beads/issues.jsonl",
        startLine: 1,
        endLine: 1,
        schema: {
          type: "object",
          properties: {
            id: { type: "string" },
            title: { type: "string" },
            priority: { type: "integer" },
            status: { type: "string", enum: ["open", "in_progress", "closed"] },
            files_mentioned: { type: "array", items: { type: "string" } },
          },
          required: ["id", "title", "priority", "status", "files_mentioned"],
        },
      },
    },
    {
      label: "classify(.beads/issues.jsonl line 1) [label from fixed set]",
      name: "classify",
      args: {
        pathOrText: ".beads/issues.jsonl",
        isPath: true,
        startLine: 1,
        endLine: 1,
        labels: ["security hardening", "new feature", "test coverage", "documentation", "bug fix"],
      },
    },
  ];

  // The calls loop (and client.close()) are wrapped in try/finally rather
  // than left as sequential statements: a client-side timeout or a thrown
  // MCP error (both observed live in this session -- see token-savings.md's
  // "Reliability" section) would otherwise skip client.close() entirely,
  // leaking the spawned `node dist/index.js` stdio child process. This
  // script is kept as a reusable harness, not a one-off, so it must tear
  // down its transport on every exit path, not just the happy path.
  try {
    for (const call of calls) {
      const argsChars = JSON.stringify(call.args).length;
      const t0 = Date.now();
      // Client-side request timeout deliberately set well above the server's
      // documented ~90s worst case (60s first attempt + 30s retry) -- see
      // README's "Progress notifications during generation" section, which
      // flags the SDK client default (60s) as a real risk of firing before the
      // server's own isError:true degradation gets a chance. Confirmed here:
      // the default 60s timeout fired on the very first real call.
      const res = await client.callTool({ name: call.name, arguments: call.args }, undefined, { timeout: 180_000 });
      const wallMs = Date.now() - t0;
      const resultText = res.content?.[0]?.text ?? "";
      results.mcp.push({
        label: call.label,
        tool: call.name,
        isError: res.isError ?? false,
        wallMs,
        argChars: argsChars,
        argTokensEst: charsToTokensEstimate(argsChars),
        resultChars: resultText.length,
        resultTokensEst: charsToTokensEstimate(resultText.length),
        result: resultText,
      });
      console.error(`[mcp] ${call.label} -> isError=${res.isError ?? false} wallMs=${wallMs} resultChars=${resultText.length}`);
      console.error(`[mcp-result] ${resultText}`);
    }
  } finally {
    await client.close();
  }

  // --- 2. Direct Ollama calls mirroring the server's own prompt construction,
  // to capture Ollama's real prompt_eval_count/eval_count (its own tokenizer,
  // not a chars/4 estimate) for the files above. ---
  async function sliceForDirect(relPath) {
    const full = await readFile(path.join(REPO_ROOT, relPath), "utf8");
    const truncated = full.length > MAX_INPUT_CHARS;
    return { content: truncated ? full.slice(0, MAX_INPUT_CHARS) : full, truncated, rawChars: full.length };
  }

  const runOvernight = await sliceForDirect("tools/run-overnight.sh");
  const telemetryDoc = await sliceForDirect("commands/analyze-telemetry.md");

  const directCalls = [
    {
      label: "direct /api/generate summarize prompt (run-overnight.sh, truncated to 12000 chars)",
      prompt:
        "Summarize the following file content in 3-6 sentences, plain prose, no preamble.\n\n--- FILE CONTENT START ---\n" +
        runOvernight.content +
        "\n--- FILE CONTENT END ---",
      format: { type: "object", properties: { summary: { type: "string" } }, required: ["summary"] },
      rawChars: runOvernight.rawChars,
      truncated: runOvernight.truncated,
    },
    {
      label: "direct /api/generate summarize prompt (analyze-telemetry.md, full file)",
      prompt:
        "Summarize the following file content in 3-6 sentences, plain prose, no preamble.\n\n--- FILE CONTENT START ---\n" +
        telemetryDoc.content +
        "\n--- FILE CONTENT END ---",
      format: { type: "object", properties: { summary: { type: "string" } }, required: ["summary"] },
      rawChars: telemetryDoc.rawChars,
      truncated: telemetryDoc.truncated,
    },
  ];

  for (const dc of directCalls) {
    try {
      const r = await directOllamaGenerate(dc.prompt, dc.format, 180_000);
      results.direct.push({
        label: dc.label,
        rawFileChars: dc.rawChars,
        truncated: dc.truncated,
        promptChars: dc.prompt.length,
        ...r,
      });
      console.error(
        `[direct] ${dc.label} -> ok=${r.ok} status=${r.status} wallMs=${r.wallMs} prompt_eval_count=${r.prompt_eval_count} eval_count=${r.eval_count} response=${JSON.stringify(r.response)}`,
      );
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      results.direct.push({ label: dc.label, rawFileChars: dc.rawChars, truncated: dc.truncated, promptChars: dc.prompt.length, ok: false, error: message });
      console.error(`[direct] ${dc.label} -> THREW ${message}`);
    }
  }

  console.log(JSON.stringify(results, null, 2));
}

main().catch((err) => {
  console.error("FATAL", err);
  process.exit(1);
});
