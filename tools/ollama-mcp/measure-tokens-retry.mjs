// Companion to measure-tokens.mjs: re-runs the two calls that hit a live
// "model runner has unexpectedly stopped" HTTP 500 from Ollama during the
// first pass (Task A's summarize_file(tools/run-overnight.sh) and Task C's
// extract(.beads/issues.jsonl line 1)), to see whether they succeed once the
// runner has recovered (real retry/failure-overhead data for claude-r30.7's
// write-up).
//
// Caveat: this reproduces the *first* HTTP 500 retry for each call, but not
// Task A's specific "attempt 2" finding documented in token-savings.md (the
// 119.2s GENERATE_TIMEOUT_MS-adjacent timeout) -- that was an ad hoc re-run
// observed live in the original session, not a deterministic outcome this
// script can guarantee reproducing on a subsequent run, since Ollama's
// runner-recovery timing and whether a given retry hits a timeout vs a clean
// success both depend on live sidecar state at run time.
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import path from "node:path";

const REPO_ROOT = "/workspace";
const OLLAMA_HOST = process.env.OLLAMA_HOST ?? "http://ollama:11434";
const OLLAMA_MODEL = process.env.OLLAMA_MODEL ?? "llama3.2:3b";

async function main() {
  const transport = new StdioClientTransport({
    command: "node",
    args: [path.join(REPO_ROOT, "tools/ollama-mcp/dist/index.js")],
    cwd: REPO_ROOT,
    env: { OLLAMA_HOST, OLLAMA_MODEL, WORKSPACE_ROOT: REPO_ROOT, PATH: process.env.PATH },
  });
  const client = new Client({ name: "measure-tokens-retry", version: "0.0.0" });
  await client.connect(transport);

  const calls = [
    {
      label: "RETRY summarize_file(tools/run-overnight.sh) [large file, expect truncation]",
      name: "summarize_file",
      args: { path: "tools/run-overnight.sh" },
    },
    {
      label: "RETRY extract(.beads/issues.jsonl line 1)",
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
  ];

  // See measure-tokens.mjs for why this is try/finally rather than a bare
  // sequential await client.close(): a thrown/timed-out callTool would
  // otherwise skip close() and leak the spawned dist/index.js child process.
  try {
    for (const call of calls) {
      const t0 = Date.now();
      const res = await client.callTool({ name: call.name, arguments: call.args }, undefined, { timeout: 180_000 });
      const wallMs = Date.now() - t0;
      const resultText = res.content?.[0]?.text ?? "";
      console.error(`[retry] ${call.label} -> isError=${res.isError ?? false} wallMs=${wallMs}`);
      console.error(`[retry-result] ${resultText}`);
    }
  } finally {
    await client.close();
  }
}

main().catch((err) => {
  console.error("FATAL", err);
  process.exit(1);
});
