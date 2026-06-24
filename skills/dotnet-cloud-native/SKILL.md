---
name: dotnet-cloud-native
description: >-
  Cloud-native conventions for .NET services: .NET Aspire for local orchestration
  and dependency wiring, OpenTelemetry for traces/metrics/logs, resilience via
  Microsoft.Extensions.Http.Resilience / Polly v8, Kubernetes health checks, and
  container builds. Use whenever building or reviewing service composition, HTTP
  client resilience (retry/circuit-breaker/timeout/hedging), telemetry/observability
  wiring, health endpoints, or Dockerfiles — even if the task just says "call this
  service" or "add a health check".
---

# Cloud-native

- **.NET Aspire** for local orchestration, service discovery, and wiring of
  dependencies (DBs, caches, brokers). Use its integrations rather than
  hand-rolling connection setup — this is the default composition story.
- **OpenTelemetry** for traces, metrics, and logs, exported via OTLP. Don't
  invent bespoke telemetry.
- **Resilience** via `Microsoft.Extensions.Http.Resilience`
  (`AddStandardResilienceHandler`) / Polly v8 strategies — retry, circuit
  breaker, timeout, hedging. The old `Microsoft.Extensions.Http.Polly` is
  deprecated.
- **Health checks** (`/health/live`, `/health/ready`) wired to Kubernetes probes.
- **Containers**: multi-stage builds, non-root user, trimming/AOT where compatible
  (verify trim-compatibility first — see `dotnet-performance`).
- **Dapr** only where a project already commits to it.

## Review notes

Flag outbound HTTP with no resilience handler, bespoke telemetry where OTel
exists, the deprecated `Http.Polly` package, missing/incorrect health probes, and
containers running as root.