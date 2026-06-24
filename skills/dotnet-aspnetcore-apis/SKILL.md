---
name: dotnet-aspnetcore-apis
description: >-
  ASP.NET Core HTTP API conventions for .NET 10: minimal APIs vs controllers,
  API versioning, Problem Details error handling, authentication/authorization,
  System.Text.Json on hot paths, source-generated logging, and output
  caching/rate limiting. Use whenever building or reviewing an HTTP endpoint,
  route group, middleware, model binding, error response shape, or auth policy —
  even if the task just says "add an endpoint" or "return a 400 here".
---

# ASP.NET Core APIs

- **Minimal APIs** with route groups + endpoint filters for services; controllers
  are fine for large or complex surfaces.
- **API versioning** via `Asp.Versioning.*`.
- **Errors as Problem Details** (`application/problem+json`) through a global
  `IExceptionHandler` — not ad-hoc error shapes per endpoint.
- **AuthN/AuthZ: never roll your own.** ASP.NET Core Identity for local accounts,
  OIDC / Entra ID for enterprise, OpenIddict for self-issued tokens. Authorize
  with **policies**, not scattered role checks.
- **`System.Text.Json`** with a source-generated `JsonSerializerContext` on hot paths.
- **Source-generated logging** (`[LoggerMessage]`) over interpolated log calls.
- **Output caching** and **rate limiting** middleware where they earn their place.

## Review notes

Flag missing/incorrect authorization on an endpoint, hand-rolled auth, error
responses that bypass Problem Details, and reflection-based JSON on a hot path
where a source-generated context belongs. Missing authz and any secret/PII in a
response are security findings — defer those to the security reviewer's severity.