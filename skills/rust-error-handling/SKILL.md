---
name: rust-error-handling
description: >-
  Error-handling conventions AND review checks for Rust: typed errors with
  `thiserror` in libraries, `anyhow` with context in binaries, `Result` and the
  `?` operator, error context, and avoiding panics on reachable paths. Use
  whenever building or reviewing how Rust code models, propagates, or recovers
  from failure — error enums, `?` usage, `unwrap`/`expect`, `panic!`, fallible
  conversions — even if the task just says "handle this error" or "return a Result".
---

# Error handling (Rust)

- **Libraries** define their own error type(s) with `thiserror` — one enum per
  meaningful failure surface, `#[from]` for upstream conversions, messages via
  `#[error("…")]`. Don't leak `anyhow::Error` across a library's public API.
- **Binaries / application edges** use `anyhow` (or `eyre`): `anyhow::Result`,
  `.context("…")` / `.with_context(|| …)` to add a breadcrumb at each layer.
- Propagate with `?`; reserve `match` for cases you actually handle differently.
- **No `unwrap()` / `expect()` on a reachable error path.** They're acceptable
  only where the invariant is genuinely guaranteed (e.g. a checked-once static) —
  and even then prefer `expect("why this can't fail")` over `unwrap()`.
- `panic!` is for unrecoverable programmer errors, not control flow or input
  validation. Validate input into a typed error instead.
- Preserve the source chain (`#[source]` / `#[from]`); don't stringify an error
  and discard its cause.

## Review checklist

- `unwrap()` / `expect()` / `panic!` on a path reachable from untrusted input or
  normal operation (critical — it's a crash).
- `?` discarding useful context where a `.context(...)` would aid debugging.
- Library exposing `anyhow::Error` (or `Box<dyn Error>`) in its public API instead
  of a typed error.
- Error converted to `String` early, losing the source chain.
- Distinct failure modes collapsed into one opaque error that callers can't match on.