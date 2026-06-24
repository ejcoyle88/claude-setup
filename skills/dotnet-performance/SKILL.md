---
name: dotnet-performance
description: >-
  Performance conventions AND review checks for .NET: measure-first discipline
  with BenchmarkDotNet, hot-path techniques (Span/Memory, ArrayPool, stackalloc),
  and AOT/trimming for fast-start services. Use whenever optimizing or reviewing
  for efficiency — judging allocations, algorithmic cost, or hot-path work, or
  deciding whether an optimization is warranted — even if the task just says
  "make this faster" or "is this efficient?". Pairs with the performance reviewer.
---

# Performance (measure first)

- **Benchmark with BenchmarkDotNet before optimizing** — don't micro-optimize on
  speculation. Where a claim really needs measurement, recommend a benchmark or
  profiler rather than asserting a number.
- `Span<T>` / `Memory<T>`, `ArrayPool<T>`, `stackalloc` on **proven** hot paths only.
- AOT / trimming for fast-start services — verify dependencies are
  trim-compatible first (see `dotnet-cloud-native` for container builds).

## Review checklist

Judge impact under realistic load, not micro-optimizations:

- **Algorithmic cost** — needless quadratic-or-worse work, repeated work in loops,
  work that scales with input where it needn't.
- **Data access** — N+1 queries, query shapes implying a missing index,
  over-fetching, chatty/unbatched I/O (overlaps `dotnet-data-access`).
- **Allocations & memory** — unnecessary hot-path allocations, oversized buffers,
  retained references / unbounded growth, avoidable boxing.
- **Resource use** — leaked connections/handles/streams, pool misuse, missing
  disposal on hot paths.
- **Concurrency cost** — lock contention, false sharing, thread-pool starvation,
  sync-over-async blocking throughput (the *bug* side is the quality reviewer's).
- **Caching** — expensive repeated work that should be cached (see `dotnet-caching`).