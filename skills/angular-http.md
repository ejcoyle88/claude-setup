---
name: angular-http
description: >-
  Angular HttpClient conventions AND review checks: provideHttpClient(withFetch()),
  typed requests/responses, functional interceptors (auth, retry, error, XSRF),
  httpResource for signal-graph fetching, and safe URL/param construction. Use
  whenever building or reviewing HTTP calls in Angular — a service that talks to an
  API, an interceptor, error handling, or auth headers — even if the task just
  says "call this endpoint" or "add an interceptor".
---

# Angular HttpClient

- Provide with **`provideHttpClient(withFetch())`**; type responses (`get<T>()`).
- **Functional interceptors** (`HttpInterceptorFn`) for cross-cutting concerns —
  auth headers, retries, error normalization, logging — registered via
  `withInterceptors([...])`. Don't attach auth per call.
- **XSRF**: keep `withXsrfConfiguration` (or the default) in place for
  cookie-based auth.
- **`httpResource`** to fetch inside the signal graph (loading/error/value
  signals) when the result drives the UI (see `angular-signals`); plain
  `HttpClient` + RxJS for imperative flows.
- **Safe params**: build query params with `HttpParams` (it encodes) — never
  string-concatenate untrusted input into a URL.
- **Errors**: handle with `catchError`, map to typed/user-facing errors; don't
  swallow.

## Review checklist (security-sensitive — defer severity to the security reviewer)

- Untrusted input concatenated into a URL/path instead of `HttpParams` / encoding.
- Auth token in a query string, or credentials/PII logged.
- Missing or disabled XSRF protection on cookie-authenticated requests.
- Auth attached ad-hoc per request instead of via an interceptor (easy to miss a call).
- Responses used untyped (`any`) / no error handling.