/**
 * Progress-notification plumbing for long-running Ollama generation calls
 * (bead claude-lp5, a follow-up to claude-r30.5's `generateStructured`
 * retry). `generateStructured`'s first attempt (GENERATE_TIMEOUT_MS, 60s)
 * plus its retry (RETRY_TIMEOUT_MS, 30s) can together take up to ~90s before
 * a tool call returns `isError:true` -- if the live MCP client's own
 * tool-call timeout is at/near 60s, it could fire a hard transport-level
 * timeout first. Per the MCP spec, a server MAY send `notifications/progress`
 * for a request while it's in flight, but only if the *caller* opted in by
 * attaching a `progressToken` to that request's `_meta` ("the receiver is
 * not obligated to provide these notifications" absent one) -- a compliant
 * client that requested progress notifications is expected to reset its own
 * timeout clock on each one it receives. This module is a pure, testable
 * extraction of that logic; it never changes a tool call's actual
 * success/error/timeout outcome, only emits extra out-of-band notifications
 * alongside it.
 */
import type { RequestHandlerExtra } from "@modelcontextprotocol/sdk/shared/protocol.js";
import type { ServerNotification, ServerRequest } from "@modelcontextprotocol/sdk/types.js";

/** Interval, in milliseconds, between progress notifications sent while a
 * generation call is in flight. Deliberately well under both
 * GENERATE_TIMEOUT_MS (60s) and RETRY_TIMEOUT_MS (30s) in index.ts, so a
 * compliant client's timeout clock gets reset multiple times over even the
 * shorter of the two, not just once near the end. */
export const PROGRESS_INTERVAL_MS = 12_000;

/** Callback invoked periodically while an operation wrapped by
 * `withPeriodicProgress` is pending. `elapsedMs` is the time since the
 * operation started, as of this invocation. Implementations must not throw
 * -- see `makeProgressNotifier`'s use of `.catch(() => {})` for the one
 * built-in implementation this module provides. */
export type ProgressNotifier = (elapsedMs: number) => void;

/** A `ProgressNotifier` that does nothing -- used whenever the caller of a
 * tool did not request progress notifications (no `progressToken`), so no
 * notification is ever sent to a client that didn't opt in. */
export const NO_OP_PROGRESS_NOTIFIER: ProgressNotifier = () => {};

/**
 * Runs `notify` every `intervalMs` while `operation` is pending, and clears
 * the timer the instant `operation` settles -- whether it resolves,
 * rejects, or (as `callOllamaGenerate` does internally) resolves with an
 * `ok: false` timeout result. Mirrors the `AbortController`/`setTimeout`/
 * `finally` cleanup pattern already used by `callOllamaGenerate`/
 * `checkOllamaHealth` in `index.ts`, just for a repeating interval instead
 * of a single one-shot timeout, so there is never a dangling timer left
 * running past the operation's own lifetime on any exit path.
 *
 * This is a pure side observer: it never alters, delays, retries, or
 * swallows `operation`'s own resolution or rejection -- whatever
 * `operation` would have resolved/rejected to on its own, this returns (or
 * rethrows) unchanged.
 */
export async function withPeriodicProgress<T>(
  operation: Promise<T>,
  notify: ProgressNotifier,
  intervalMs: number = PROGRESS_INTERVAL_MS,
): Promise<T> {
  const start = Date.now();
  const timer = setInterval(() => notify(Date.now() - start), intervalMs);
  try {
    return await operation;
  } finally {
    clearInterval(timer);
  }
}

/** Minimal shape this module needs from a tool handler's `extra` argument --
 * a structural subset of the MCP SDK's own
 * `RequestHandlerExtra<ServerRequest, ServerNotification>` (the exact type
 * `McpServer.registerTool`'s handler callback receives as its second
 * argument, per `@modelcontextprotocol/sdk/server/mcp.js`'s `ToolCallback`),
 * restricted to the two fields this module actually reads: the incoming
 * request's `_meta` (which carries any `progressToken` the caller opted in
 * with) and `sendNotification` (used to emit `notifications/progress`).
 * Picking from the real SDK type -- rather than hand-rolling an equivalent
 * shape -- means a real `extra` argument is guaranteed structurally
 * assignable here, and a future SDK change to either field's type is
 * caught by the compiler instead of silently drifting. */
export type ProgressCapableExtra = Pick<
  RequestHandlerExtra<ServerRequest, ServerNotification>,
  "_meta" | "sendNotification"
>;

/**
 * Builds a `ProgressNotifier` for a single tool invocation from its
 * `extra` handler argument. Returns `NO_OP_PROGRESS_NOTIFIER` when the
 * incoming request carried no `progressToken` -- the MCP spec makes
 * progress notifications opt-in per request, so a server must never send
 * one to a client that didn't ask for it. When a token is present, each
 * call sends a `notifications/progress` notification carrying that same
 * token (required so the client can associate it with the right request),
 * a monotonically increasing `progress` value, and a human-readable
 * `message` noting elapsed time.
 *
 * `sendNotification` is best-effort here: a failed send (e.g. the
 * transport closed) must never affect the tool call's actual result, so
 * any rejection is swallowed -- same "never throw for a side channel"
 * style as `checkOllamaHealth`'s own error handling. The call itself is
 * also wrapped in `try`/`catch`: this runs inside `withPeriodicProgress`'s
 * `setInterval` callback, a call stack separate from the `try`/`finally`
 * around the underlying operation, so a *synchronous* throw here (e.g.
 * from a transport shim or test double whose `sendNotification` isn't a
 * true `async function`) would otherwise be an uncaught exception that
 * could crash the whole stdio server process instead of just this side
 * channel.
 */
export function makeProgressNotifier(extra: ProgressCapableExtra): ProgressNotifier {
  const progressToken = extra._meta?.progressToken;
  if (progressToken === undefined) {
    return NO_OP_PROGRESS_NOTIFIER;
  }

  let progress = 0;
  return (elapsedMs: number) => {
    progress += 1;
    try {
      extra
        .sendNotification({
          method: "notifications/progress",
          params: {
            progressToken,
            progress,
            message: `Ollama generation in progress (~${Math.round(elapsedMs / 1000)}s elapsed)...`,
          },
        })
        .catch(() => {
          // Best-effort side channel -- never let a failed notification send
          // affect the tool call itself.
        });
    } catch {
      // Same "never throw for a side channel" contract, but for a
      // synchronous throw from sendNotification itself rather than an
      // async rejection -- see the doc comment above.
    }
  };
}
