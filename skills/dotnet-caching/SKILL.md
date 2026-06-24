---
name: dotnet-caching
description: >-
  Caching conventions AND review checks for .NET: when to use FusionCache (hybrid
  L1+L2 with backplane) versus plain IMemoryCache, fail-safe / stampede
  protection / timeouts / eager refresh, serializer choice, and staleness/growth
  risks. Use whenever building or reviewing anything that caches — adding a cache,
  tuning entry options, or judging whether cached data can go stale or grow
  unbounded — even if the task just says "cache this" or "speed up this lookup".
---

# Caching

- Default to **FusionCache** (`ZiggyCreatures.FusionCache`) when caching needs to
  be production-grade: a hybrid L1 (in-memory) + optional L2 (Redis via any
  `IDistributedCache`) with a backplane for multi-node coherence.
- Lean on its resiliency features rather than re-implementing them: fail-safe
  (serve stale data when the factory fails), cache stampede protection,
  soft/hard factory timeouts, eager refresh, and auto-recovery.
- Use `GetOrSetAsync` with per-entry options; choose an L2 serializer
  (System.Text.Json by default, MessagePack/MemoryPack for large or
  high-throughput payloads). FusionCache exposes OpenTelemetry instrumentation —
  wire it into the OTel pipeline (`dotnet-cloud-native`).
- It can register as Microsoft's `HybridCache` via `.AsHybridCache()` for
  vendor-neutral library code.
- **Don't reach for it on a single-pod, low-traffic path** — plain `IMemoryCache`
  is the right call there. The L1 + L2 + backplane machinery isn't free.

## Review checklist

- Cache key collisions or keys that don't capture all inputs (returns wrong data).
- Unbounded growth: no size limit / eviction on an in-memory cache.
- Staleness risk: cached data that must be fresh, with no invalidation or sensible TTL.
- Multi-node coherence assumed without a backplane.
- FusionCache machinery on a single-pod, low-traffic path where `IMemoryCache`
  would do (over-engineering / cost).