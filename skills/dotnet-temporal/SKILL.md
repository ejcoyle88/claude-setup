---
name: dotnet-temporal
description: >-
  Durable-workflow conventions for .NET using Temporal (the Temporalio SDK):
  when to use it, the determinism rules for workflow code, idempotent activities
  with timeouts/retries, hosting/OTel integration, testing with time-skipping,
  and the native-Rust-core deployment caveats. Use whenever building or reviewing
  long-running / multi-step / saga / scheduled / human-in-the-loop orchestration,
  or any Temporal workflow or activity — even if the task just says "this needs
  to survive restarts" or "retry this step".
---

# Durable workflows (Temporal)

- Use **Temporal** (the `Temporalio` .NET SDK, GA) for long-running, durable,
  fault-tolerant orchestration — multi-step processes, sagas, scheduled or
  human-in-the-loop flows, and anything that must survive process restarts. Do
  not hand-roll durable state machines or cron-driven step runners for these.
- Keep workflow code **deterministic**: no direct I/O, `DateTime.Now`, RNG,
  `Task.Delay`, or threading inside workflow methods. Use the `Workflow.*` APIs
  (timers, delays, side effects) and push every side effect into **activities**.
- Make activities **idempotent** and give them explicit timeouts and retry
  policies; let Temporal own the retries rather than coding your own backoff.
- Integrate via `Temporalio.Extensions.Hosting` (DI + worker generic host) and
  trace via `Temporalio.Extensions.OpenTelemetry` (feeds the OTel pipeline).
- Test workflows and activities with `Temporalio.Testing` (`WorkflowEnvironment`
  with time-skipping, `ActivityEnvironment`).
- The SDK core is a native Rust library: only specific RIDs are supported, and
  some containers (Alpine/musl, Windows Nano Server) need extra care with the
  native dependency.

## Review notes

The high-value flags here are **determinism violations** inside workflow methods
(`DateTime.Now`, RNG, direct I/O, `Task.Delay`, threading) — these are correctness
bugs, not style. Also flag non-idempotent activities, activities without explicit
timeouts/retries, and hand-rolled backoff that duplicates Temporal's.