#!/usr/bin/env node
/**
 * ollama-mcp: stdio MCP server that offloads work to a local Ollama instance.
 *
 * Scaffold only (bead claude-r30.3): exposes `ping` (transport smoke test) and
 * `health` (reachability check against OLLAMA_HOST). Reference-based offload
 * tools (summarize_file, extract, classify) land in a later bead
 * (claude-r30.4) and will operate on file paths/globs so bulk text never
 * enters Claude's context.
 */
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

const server = new McpServer(
  {
    name: "ollama-mcp",
    version: "0.1.0",
  },
  {
    instructions:
      "Local Ollama offload server (scaffold). Currently exposes only " +
      "`ping` (transport check) and `health` (Ollama reachability check). " +
      "Offload tools that summarize/extract/classify from file paths are " +
      "not implemented yet.",
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

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("ollama-mcp running on stdio");
}

main().catch((error) => {
  console.error("ollama-mcp fatal error:", error);
  process.exit(1);
});
