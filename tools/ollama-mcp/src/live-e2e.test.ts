/**
 * Live end-to-end test for an offload tool (`extract`) against a real,
 * reachable Ollama sidecar (bead claude-9sm, flagged as out of scope in
 * health.test.ts's file header when this repo's sandbox had no live
 * sidecar). Unlike health.test.ts and lock.test.ts, which substitute a fake
 * `fetch`/pid to exercise index.ts's own functions in isolation, this test
 * makes NO substitution at all: it spawns the actual built `dist/index.js`
 * entry point as a real child process -- the same way this repo's own
 * `.mcp.json` launches it -- connects a real `@modelcontextprotocol/sdk`
 * `Client` over a real stdio transport, and calls the `extract` tool
 * exactly as a caller would: MCP protocol -> tool handler -> real file read
 * (a small fixture under `test-fixtures/`) -> a real `callOllamaGenerate`
 * HTTP call to the live sidecar at OLLAMA_HOST -> real JSON parsing/schema
 * validation of the model's actual response (`parseAndValidateJson` inside
 * `generateStructured`) -> the compact `{ data, truncated }` result that
 * crosses back over the protocol to this test, which independently
 * re-validates it against the schema via the exported
 * `validateAgainstSchema` rather than only trusting the server's own
 * internal check.
 *
 * Gated behind an explicit opt-in env var, `RUN_LIVE_OLLAMA_TESTS=1` --
 * without it, this test is skipped unconditionally, regardless of whether a
 * sidecar happens to be reachable. This suite's other ~41 tests run against
 * fakes/mocks in well under a second; this one test pays real inference
 * latency (tens of seconds to ~2 minutes, see LIVE_CALL_TIMEOUT_MS's doc
 * comment below) against a live, non-deterministic model, so it must never
 * run as a silent side effect of a normal `npm test` (`tsc && node --test
 * dist`) just because a sidecar happens to be reachable -- including in this
 * dev sandbox, where that's true every day. Set `RUN_LIVE_OLLAMA_TESTS=1` to
 * opt in.
 *
 * Once opted in, reachability is still checked via the already-exported
 * `checkOllamaHealth` (the same reachability probe the `health` tool itself
 * uses) as a secondary safety net, not the sole gate: if the sidecar isn't
 * actually reachable (e.g. opted in locally but the sidecar is temporarily
 * down, or a future CI environment sets the env var without a live sidecar),
 * the test is skipped with a clear, distinct reason via `node:test`'s `skip`
 * option instead of failing opaquely deep inside a spawned child process.
 *
 * The live model's phrasing/exact values are not deterministic in general,
 * so assertions are primarily on shape (a schema-valid object; non-empty
 * strings) rather than exact wording -- except `version`, which is a
 * verbatim copy-out of a literal substring in the fixture (not a
 * summarization/paraphrase task), which a competent small model reproduces
 * reliably and is worth pinning as a stronger signal that extraction (not
 * just "the model returned *some* valid JSON") actually worked.
 *
 * Runs within a budget generously above this module's own GENERATE_TIMEOUT_MS
 * (60s) plus its possible ~30s RETRY_TIMEOUT_MS retry (see
 * `generateStructured`'s doc comment in index.ts) -- LIVE_CALL_TIMEOUT_MS
 * below adds headroom for spawning the child process and completing MCP
 * initialize on top of that combined ~90s worst case, rather than assuming
 * its own conflicting budget.
 */
import assert from "node:assert/strict";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { test, type TestContext } from "node:test";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { CallToolResultSchema, type CallToolResult } from "@modelcontextprotocol/sdk/types.js";
import { checkOllamaHealth } from "./index.js";
import { validateAgainstSchema, type JsonSchema } from "./validate.js";

/** Generous ceiling for the one live `extract` call this file makes: this
 * module's own GENERATE_TIMEOUT_MS (60s) plus a possible RETRY_TIMEOUT_MS
 * retry (~30s) plus headroom for spawning the child process and completing
 * MCP initialize. GENERATE_TIMEOUT_MS/RETRY_TIMEOUT_MS aren't (and don't
 * need to be) exported from index.ts -- this is deliberately a looser
 * ceiling layered on top of that budget, not a competing assumption about
 * it. */
const LIVE_CALL_TIMEOUT_MS = 120_000;

const distDir = path.dirname(fileURLToPath(import.meta.url));
const packageRoot = path.resolve(distDir, "..");
const serverEntry = path.join(distDir, "index.js");

/** Relative to `packageRoot` (this test sets the spawned server's `cwd` to
 * `packageRoot`, so the server's WORKSPACE_ROOT -- which defaults to its own
 * `process.cwd()` -- resolves there too, and this path stays inside it per
 * `resolveWorkspacePath`'s confinement check). A small real fixture, not a
 * large one: this test pays real inference latency/cost every run. */
const FIXTURE_RELATIVE_PATH = "test-fixtures/product-release.txt";

/** Explicit opt-in gate for this entire live e2e test -- see this file's
 * header comment for why reachability alone isn't a sufficient gate. */
const RUN_LIVE_TESTS_ENV_VAR = "RUN_LIVE_OLLAMA_TESTS";
const optedIn = process.env[RUN_LIVE_TESTS_ENV_VAR] === "1";

// Reachability is checked once, up front (top-level await -- this file
// compiles to NodeNext ESM, same as index.ts's own module-level code, which
// supports it) -- but only once opted in, so a normal, non-opted-in test run
// never even makes a network call here. If the sidecar isn't reachable, the
// test below is skipped with a clear, distinct reason via `node:test`'s
// `skip` option, rather than failing with a confusing timeout/connection
// error deep inside a spawned child process.
let skipReason: string | false = optedIn
  ? false
  : `set ${RUN_LIVE_TESTS_ENV_VAR}=1 to opt in to this live e2e test against a real Ollama sidecar -- skipped by ` +
    "default (even when a sidecar happens to be reachable) so `npm test` stays fast and deterministic";

if (optedIn) {
  const health = await checkOllamaHealth();
  if (!health.reachable) {
    skipReason = `ollama sidecar at ${health.host} is not reachable (${health.error ?? "unknown error"}) -- skipping live e2e test`;
  }
}

/** Spawns the real `dist/index.js` MCP server as a child process (via
 * `process.execPath`, not a hardcoded `"node"`, so this works under whatever
 * Node binary is actually running the test), connects a real MCP `Client`
 * over stdio, runs `fn`, and always closes both -- even if `fn` throws, or
 * even if `connect` itself fails -- so neither a failing assertion nor a
 * failed handshake ever leaks the spawned child process.
 *
 * `env` is scoped to an explicit allowlist of just the two variables the
 * spawned server actually needs -- `OLLAMA_HOST`/`OLLAMA_MODEL` -- rather
 * than forwarding this test process's entire environment. Forwarding
 * everything would widen the credential-exposure blast radius for no
 * benefit: `StdioClientTransport` inherits the child's stderr straight
 * through to this test process's own stderr (captured into CI/build logs),
 * so any secret present in the test-runner's env (registry tokens, cloud
 * credentials, CI-injected tokens) would also be present in the spawned
 * child's env -- reachable by anything in `dist/index.js` or its dependency
 * tree that dumps env content to stderr on an unhandled exception, or by a
 * supply-chain compromise anywhere in that dependency tree. Omitting
 * anything beyond these two keys still lets `StdioClientTransport` merge in
 * its own fixed built-in allowlist (HOME/LOGNAME/PATH/SHELL/TERM/USER), so
 * the spawned server still gets a working PATH to exec node and sees the
 * same `OLLAMA_HOST`/`OLLAMA_MODEL` this test's own process already read via
 * `checkOllamaHealth()` above -- without which a caller with a custom
 * OLLAMA_HOST env var could have the reachability probe and the actual
 * spawned server silently target different hosts -- without forwarding
 * anything else.
 *
 * `signal` (the calling test's `TestContext.signal`) is threaded into the
 * MCP `initialize` handshake so a `node:test` timeout firing during connect
 * aborts a hanging/slow handshake promptly, instead of leaving it -- and the
 * child process it already spawned -- to finish or hang unsupervised after
 * the test has already been reported failed. */
async function withLiveClient<T>(signal: AbortSignal, fn: (client: Client) => Promise<T>): Promise<T> {
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [serverEntry],
    cwd: packageRoot,
    // Only the two variables the spawned server actually needs are
    // forwarded (see this function's doc comment above) -- `process.env`'s
    // index signature is `string | undefined` (a key can be declared but
    // unset), so each is included only when actually set, rather than
    // forwarded as literal `"undefined"` or widened away with a cast.
    env: {
      ...(process.env.OLLAMA_HOST !== undefined ? { OLLAMA_HOST: process.env.OLLAMA_HOST } : {}),
      ...(process.env.OLLAMA_MODEL !== undefined ? { OLLAMA_MODEL: process.env.OLLAMA_MODEL } : {}),
    },
  });
  const client = new Client({ name: "ollama-mcp-live-e2e-test", version: "0.0.0" });
  try {
    await client.connect(transport, { signal });
  } catch (error) {
    // connect() failed (child crashed before the handshake completed, a
    // stale/missing dist/, or the handshake itself timed out/was aborted) --
    // Client.connect() assigns its internal transport reference before it
    // awaits transport.start(), so close() below still tears down the
    // spawned child process/stdio pipes correctly even though connect()
    // itself never resolved. Best-effort: a close() failure here is far
    // less actionable than the original connect() error, so it's swallowed
    // rather than masking it.
    await client.close().catch(() => {});
    throw error;
  }
  try {
    return await fn(client);
  } finally {
    await client.close();
  }
}

test(
  "extract (live): full MCP path against the real ollama sidecar returns schema-valid data from a real fixture file",
  { skip: skipReason, timeout: LIVE_CALL_TIMEOUT_MS },
  async (t: TestContext) => {
    const schema: JsonSchema = {
      type: "object",
      properties: {
        version: { type: "string" },
        team: { type: "string" },
      },
      required: ["version", "team"],
    };

    // Passing CallToolResultSchema explicitly asks the client to validate
    // (at runtime) against the plain content-array shape, not the
    // task-based `{ toolResult }` variant callTool's declared return type
    // also technically allows -- this server never returns a task result,
    // so the `as CallToolResult` below just gives that runtime guarantee a
    // matching static type instead of the mixed-with-`unknown` type TS
    // infers for a property that's only on one union branch.
    const result = (await withLiveClient(t.signal, (client) =>
      client.callTool(
        {
          name: "extract",
          arguments: { path: FIXTURE_RELATIVE_PATH, schema },
        },
        CallToolResultSchema,
        // The MCP client's own per-request timeout defaults to
        // DEFAULT_REQUEST_TIMEOUT_MSEC (60s), which is shorter than this
        // server's documented worst case for a single extract call --
        // GENERATE_TIMEOUT_MS (60s) plus a possible RETRY_TIMEOUT_MS retry
        // (~30s) on a malformed first response (see generateStructured's
        // doc comment in index.ts). Without raising it here, the *client*
        // would abort the request on a slow-but-otherwise-healthy retry
        // before the server ever got a chance to respond -- a client-side
        // timeout assumption that conflicts with the server's own, not a
        // real failure. LIVE_CALL_TIMEOUT_MS already accounts for that
        // combined worst case plus spawn/initialize overhead. `signal:
        // t.signal` threads this test's own `node:test` timeout/abort
        // through to the request: on abort, the client-side promise
        // rejects and `withLiveClient`'s `finally` runs `client.close()`,
        // which escalates stdin.end() -> SIGTERM -> SIGKILL against the
        // spawned process -- so the spawned process and the generate lock
        // it holds are cleaned up promptly (a killed pid is detected as
        // dead by `acquireGenerateLock`'s `isPidAlive` check, not the
        // slower staleness timer) rather than lingering unsupervised after
        // the test already reported failed. This signal does NOT reach the
        // tool handlers in index.ts (none of them wire the incoming MCP
        // request's abort signal into `callOllamaGenerate`'s own
        // `AbortController`, which only ever trips on index.ts's own
        // GENERATE_TIMEOUT_MS/RETRY_TIMEOUT_MS), so it does not proactively
        // cancel the outbound `/api/generate` HTTP call or whatever compute
        // the sidecar itself is doing for it -- a dropped TCP connection
        // from a killed process doesn't guarantee the sidecar's
        // single-threaded inference stops promptly, so an immediate re-run
        // after a timeout could still see contention from the abandoned
        // request.
        { timeout: LIVE_CALL_TIMEOUT_MS, signal: t.signal },
      ),
    )) as CallToolResult;

    if (result.isError) {
      // claude-6ll's cross-process generate lock (see acquireGenerateLock /
      // callOllamaGenerate in index.ts) reports this exact wording when
      // another ollama-mcp session on this host is already mid-call against
      // the same sidecar -- a real, previously-measured contention mode
      // (see README's "Concurrent-session contention" section), not a
      // functional failure of the extract tool itself. Skip gracefully
      // rather than asserting failure so an unlucky, contended run doesn't
      // fail for a reason this test isn't meant to verify. Every other
      // error case still falls through to the hard assertion below.
      const contentText = JSON.stringify(result.content);
      if (contentText.includes("is busy serving another generate request")) {
        t.skip(`ollama sidecar's generate lock was held by another session -- skipping: ${contentText}`);
        return;
      }
    }

    assert.equal(
      result.isError,
      undefined,
      `extract tool call reported an error: ${JSON.stringify(result.content)}`,
    );
    assert.equal(result.content.length, 1);
    const [block] = result.content;
    assert.ok(block, "expected at least one content block in the tool result");
    if (block.type !== "text") {
      assert.fail(`expected a text content block, got type '${block.type}'`);
    }

    const parsed = JSON.parse(block.text) as { data: Record<string, unknown>; truncated: boolean };

    // Shape/success assertions -- a live model's phrasing isn't
    // deterministic, so this checks the result actually validates against
    // the schema (re-checked independently here, not just trusted from the
    // server's own internal validation), rather than pinning exact wording.
    const validation = validateAgainstSchema(schema, parsed.data);
    assert.equal(validation.ok, true, validation.ok ? undefined : validation.error);
    assert.equal(typeof parsed.data.version, "string");
    assert.ok((parsed.data.version as string).length > 0);
    assert.equal(typeof parsed.data.team, "string");
    assert.ok((parsed.data.team as string).length > 0);
    assert.equal(parsed.truncated, false, "the fixture is small and must not trip MAX_INPUT_CHARS truncation");

    // `version` is a verbatim copy-out of a literal substring in the
    // fixture (not a summarization/paraphrase task) -- a competent small
    // model reproduces it reliably, so this is a meaningfully stronger
    // check than shape alone without depending on the model's phrasing.
    assert.match(parsed.data.version as string, /3\.2\.0/);
  },
);
