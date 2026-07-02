---
name: dotnet-modern-csharp
description: >-
  C# 14 / .NET 10 language-feature and async guidance for server-side .NET. Use
  whenever writing or reviewing modern C# — choosing between records, structs,
  primary constructors, pattern matching, collection expressions, the `field`
  keyword, locks, or async constructs (CancellationToken, ValueTask,
  IAsyncEnumerable, Channel). Reach for this any time the question is "what's the
  idiomatic current-platform way to write this", even if the task doesn't name a
  specific feature.
---

# Modern C# (C# 14 / .NET 10)

Reach for current features where they improve clarity, not for their own sake.

**Availability is gated by the project's C# floor** — run the detector in
`dotnet-language-version` first and use only features at or below it. The
`(C# N+)` tags below are the minimum version each feature needs; on an older
floor, use the newest tagged at or below it and skip the rest.

## Language features

- Records / `readonly record struct` for immutable data; `with` for
  non-destructive mutation. (C# 9+; record struct C# 10+)
- Collection expressions (`[..]`, spreads) and `params` collections. (collection
  expressions C# 12+; `params` collections C# 13+)
- Pattern matching (list, relational, logical) over branching `if` chains.
  (relational/logical C# 9+; list patterns C# 11+)
- Primary constructors — but note captured parameters are **mutable private
  fields, not readonly**; don't use them where you'd expect record-like immutability.
  (C# 12+ for classes/structs)
- `field` keyword and extension members where they cut boilerplate. (C# 14+)
- `System.Threading.Lock` over `lock(object)` for new code. (.NET 9+)
- File-scoped namespaces (C# 10+), global usings (C# 10+), `nullable` enabled, and
  a warning-clean build (treat warnings as errors).

## Async

- `ConfigureAwait(false)` only in reusable library code — it's unnecessary in
  ASP.NET Core app code (no SynchronizationContext) and just adds noise.
- Flow `CancellationToken` end to end and honour it in loops and I/O.
- `IAsyncEnumerable<T>` + `await foreach` for streaming; `Channel<T>` for
  producer/consumer; `Parallel.ForEachAsync` for bounded concurrent I/O.
- Avoid `async void` (except event handlers) and sync-over-async
  (`.Result` / `.Wait()`).
- Default to `Task`; use `ValueTask` only on hot paths that often complete
  synchronously.

## Review notes

When reviewing, treat the above as house idiom — flag legacy patterns where a
current feature is clearly better, and flag the primary-constructor mutability
trap and any `async void` / sync-over-async. Don't nitpick style where the
existing choice is reasonable.