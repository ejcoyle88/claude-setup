---
name: rust-idioms
description: >-
  Idiomatic Rust conventions AND review checks for application/service code on
  the current stable edition: ownership and borrowing, traits and generics,
  iterator combinators over manual loops, the `?` operator, newtypes, and
  clippy/rustfmt discipline. Use whenever writing or reviewing Rust where the
  question is "what's the idiomatic way to express this" — API shape, borrow
  structure, trait design — even if the task doesn't name a specific feature.
---

# Rust idioms

- Lean on **ownership and the type system**: prefer borrows to clones, make
  illegal states unrepresentable with enums/newtypes, and let the compiler prove
  invariants rather than asserting them at runtime.
- **Iterators and combinators** (`map`/`filter`/`collect`/`?`-in-iterators) over
  manual index loops; avoid needless intermediate allocations.
- Prefer `?` and `From`/`Into` conversions over manual `match` on `Result`.
- **Traits and generics** for abstraction; use trait objects (`dyn`) only where
  dynamic dispatch is actually needed. Keep trait bounds minimal and meaningful.
- Derive (`Debug`, `Clone`, `PartialEq`, …) rather than hand-implementing where
  derivation is correct.
- Keep `unsafe` out of application code; if unavoidable, isolate it behind a safe
  API with a `// SAFETY:` comment justifying every invariant.
- Clippy-clean (`-D warnings`) and `rustfmt`-formatted; treat clippy lints as the
  house style.

## Review notes

Flag needless `.clone()` / allocation on hot or common paths, manual loops where
an iterator reads clearer, `match`-on-`Result` where `?` belongs, `unsafe`
without a `SAFETY:` justification, and overly broad trait bounds or `dyn` where a
generic would do. Treat clippy-clean idiomatic code as correct — don't bikeshed.