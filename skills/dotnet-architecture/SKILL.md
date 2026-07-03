---
name: dotnet-architecture
description: >-
  Structural conventions for server-side .NET services: vertical-slice vs layered
  organisation, the repository + unit-of-work pattern, the Result pattern for
  expected failures, the Options pattern, and domain events / transactional
  outbox. Use whenever building or reviewing how a feature, service, or handler
  is *structured* — how failures are modelled, how config is bound, how side
  effects are made reliable — even if the task just says "add an endpoint" or
  "wire up this service".
---

# Architecture (choose the simplest fit)

- **Vertical slice** for feature-oriented APIs; clean/layered only when the
  domain is genuinely complex. Don't impose ceremony a CRUD service doesn't need.
- **Repository pattern is the default here.** Because data access is hand-written
  Dapper SQL (see `dotnet-data-access`), there is no `DbContext` providing
  Unit-of-Work or repository semantics for free — so encapsulate SQL behind
  repository interfaces (`IOrderRepository`) that return domain types, keeping raw
  SQL out of handlers and services. Define repositories per aggregate with
  intention-revealing methods (`GetActiveByTenantAsync`), not a leaky generic
  `IRepository<T>`. Manage transactions explicitly via an `IUnitOfWork` wrapping
  an `IDbTransaction` (or `TransactionScope`), since Dapper tracks no changes.
- **Result pattern** for expected failures instead of exceptions. Pick one
  approach per codebase and don't mix: a small custom `Result<T>` record,
  `ErrorOr`, `OneOf`, or `FluentResults` (best when accumulating multiple errors).
- **Options pattern** (`IOptions<T>` / `IOptionsSnapshot<T>`) with `ValidateOnStart`.
- **Domain events / transactional outbox** for reliable side effects.

## Review checklist

- Raw SQL leaking into handlers/services.
- Generic `IRepository<T>` used where an intention-revealing repository belongs.
- Exceptions used for expected / control-flow failures.
- Options bound without validation (missing `ValidateOnStart`).

Treat the house choices above as correct — don't flag adherence to them.