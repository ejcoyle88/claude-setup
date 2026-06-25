---
name: rust-async-tokio
description: >-
  Async Rust conventions AND review checks with Tokio: the runtime model,
  spawning and structured concurrency, `select!`, channels (mpsc/oneshot/
  broadcast), cancellation/`CancellationToken`, and the cardinal rule of never
  blocking the executor. Use whenever building or reviewing async Rust — any
  `async fn`, `.await`, `tokio::spawn`, task, channel, or anything touching the
  runtime — even if the task just says "make this concurrent" or "call this API".
---

# Async Rust (Tokio)

- **Tokio** is the runtime. Use `#[tokio::main]` / a built runtime at the edges;
  keep library code runtime-agnostic where practical.
- **Never block the executor.** No synchronous file/network I/O, long CPU work,
  `std::thread::sleep`, or blocking locks held across `.await`. Push blocking or
  CPU-bound work to `tokio::task::spawn_blocking` (or `rayon` for parallel CPU).
- **Structured concurrency**: prefer scoped patterns and `JoinSet` over fire-and-
  forget `spawn`; make sure spawned tasks are awaited or deliberately detached.
- **Cancellation**: propagate it — thread a `CancellationToken` (or select against
  a shutdown signal) so tasks stop cleanly; don't rely on drop alone for shutdown.
- **Channels**: `mpsc` for work queues, `oneshot` for request/response, `broadcast`
  for fan-out. Bound channels to apply backpressure rather than growing unbounded.
- **`select!`**: ensure branches are cancellation-safe; be wary of losing a
  message when a branch is dropped mid-poll.
- Hold `std::sync::Mutex` only for trivial, non-`await` critical sections; use
  `tokio::sync::Mutex` when the guard must be held across `.await`.

## Review checklist

- Blocking call (sync I/O, `std::thread::sleep`, heavy CPU, blocking lock across
  `.await`) on an async task — stalls the runtime. (critical)
- Spawned task never awaited/joined and not deliberately detached (lost work,
  lost errors).
- Unbounded channel where backpressure is needed (unbounded growth — coordinate
  with the performance reviewer).
- Missing cancellation/shutdown path; tasks that can't be stopped cleanly.
- `select!` branch that isn't cancellation-safe or can drop an in-flight message.
- `std::sync::Mutex` guard held across an `.await`.