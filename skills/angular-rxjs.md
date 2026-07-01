---
name: angular-rxjs
description: >-
  RxJS conventions AND review checks for Angular: when to use Observables vs
  signals, subscription and memory-leak management (async pipe, takeUntilDestroyed,
  DestroyRef), choosing the right flattening operator (switchMap / mergeMap /
  concatMap / exhaustMap), and error handling. Use whenever building or reviewing
  Angular code with Observables, `.subscribe`, RxJS operators, or Subjects — even
  if the task just says "handle this stream" or "subscribe to this".
---

# RxJS in Angular

- **Signals for synchronous UI state; RxJS for streams and coordination** —
  events, websockets, debounced input, multicasting, complex async. Convert to a
  signal at the UI boundary (`toSignal`) rather than threading Observables through
  the template.
- **Never leak a subscription.** Prefer the `async` pipe (auto-unsubscribes) or
  `takeUntilDestroyed()` (with the injected `DestroyRef`) over manual `.subscribe`
  with hand-rolled teardown.
- **Flattening operators carry semantics** — `switchMap` (cancel the previous, for
  latest-wins like typeahead), `concatMap` (queue in order), `mergeMap` (concurrent),
  `exhaustMap` (ignore new while busy, for submit buttons). Choosing wrong is a bug.
- **Error handling**: place `catchError` so a stream recovers instead of dying;
  map to a typed/user-facing error. Consider `retry` with backoff for transient I/O.
- **Encapsulate Subjects** — expose `subject.asObservable()`, not the Subject.

## Review checklist

- Manual `.subscribe(...)` without `takeUntilDestroyed` / `async` pipe / explicit
  unsubscribe — a memory leak. (warning→critical on hot components)
- Wrong flattening operator (e.g. `mergeMap` for cancelable search → should be
  `switchMap`; missing `exhaustMap` on a submit).
- Nested `subscribe` calls where operators should compose.
- Missing `catchError`, so one error kills the stream.
- A public `Subject` handed out instead of an Observable.