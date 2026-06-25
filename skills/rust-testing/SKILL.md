---
name: rust-testing
description: >-
  Testing conventions AND review checks for Rust: unit tests in `#[cfg(test)]`
  modules vs integration tests in `tests/`, `#[tokio::test]` for async, mocking
  (mockall / trait fakes), property testing (proptest/quickcheck), doctests, and
  coverage philosophy. Use whenever writing or reviewing Rust tests, deciding how
  to test a change, or judging whether new behaviour is covered — even if the
  task just says "add tests" or "is this tested?".
---

# Testing (Rust)

- **Unit tests** in a `#[cfg(test)] mod tests` next to the code; **integration
  tests** in `tests/` exercising the public API as a consumer would.
- **Async**: `#[tokio::test]` (use `flavor = "multi_thread"` when the test needs
  real parallelism). Don't `block_on` inside an already-async test.
- **Mocking**: prefer designing against traits and passing in fakes; reach for
  `mockall` when a generated mock genuinely earns its keep. Keep tests
  deterministic — no real network/clock/filesystem unless that's the point.
- **Property tests** (`proptest` / `quickcheck`) for logic with a large input
  space — parsers, encoders, invariants — over hand-picked examples alone.
- **Doctests**: examples in `///` docs are tests; keep them runnable (`cargo test
  --doc`).
- **Coverage is a diagnostic, not a target** (`cargo llvm-cov` if you measure it).
  Chase meaningful behavioural coverage; never write filler tests to hit a number.

## Review checklist

- New behaviour, edge cases, and failure modes meaningfully covered (flag notably
  untested changed code — don't chase a percentage).
- Tests assert **behaviour, not implementation**; deterministic; no hidden
  reliance on real network/clock/filesystem.
- Async tested with `#[tokio::test]`, not by `block_on` inside an async context.
- Logic with a wide input space relies only on a couple of examples where a
  property test would catch more.
- Public-API behaviour changed but only covered by unit tests, not an integration
  test in `tests/`.