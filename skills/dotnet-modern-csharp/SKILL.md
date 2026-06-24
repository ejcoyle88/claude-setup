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

## Language features

- Records / `readonly record struct` for immutable data; `with` for
  non-destructive mutation.
- Collection expressions (`[..]`, spreads) and `params` collections.
- Pattern matching (list, relational, logical) over branching `if` chains.
- Primary constructors — but note captured parameters are **mutable private
  fields, not readonly**; don't use them where you'd expect record-like immutability.
- `field` keyword and extension members (C# 14) where they cut boilerplate.
- `System.Threading.Lock` over `lock(object)` for new code.
- File-scoped namespaces, global usings, `nullable` enabled, and a warning-clean
  build (treat warnings as errors).

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