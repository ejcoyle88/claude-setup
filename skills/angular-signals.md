---
name: angular-signals
description: >-
  Angular signals conventions AND review checks: signal / computed / effect /
  linkedSignal / untracked, the resource / httpResource / rxResource async
  primitives, and RxJS interop (toSignal / toObservable). Use whenever building or
  reviewing reactive state in Angular — deriving state, side effects, async data
  loading, or bridging between signals and Observables — even if the task just
  says "make this reactive" or "load this data".
---

# Angular signals

- **`signal(v)`** for writable state (`.set` / `.update`); **`computed(fn)`** for
  derived state — lazy and memoized; **read** as `count()`.
- **`effect(fn)`** is for *side effects* (logging, DOM sync, integrating
  non-reactive APIs), not for deriving state — reach for `computed` there. Effects
  run in an injection context and are cleaned up automatically; note effect timing
  now runs during change detection.
- **`linkedSignal`** for writable state that resets from a source; **`untracked`**
  to read a signal without creating a dependency.
- **Async data** with `resource` / `rxResource` / `httpResource` (stable in v22):
  keep fetching inside the signal graph, exposing `value()` / `isLoading()` /
  `error()` / `hasValue()`. Re-fetches when its computed request changes.
- **RxJS interop**: `toSignal(obs$, { initialValue })` (or `requireSync`) to
  consume a stream as a signal; `toObservable(sig)` to go the other way. Bridge at
  boundaries rather than threading Observables through the UI.

## Review checklist

- `effect()` used to derive state that belongs in a `computed` (harder to reason
  about; risks feedback loops).
- Writing to a signal inside a `computed`, or an `effect` that writes a signal it
  also reads without care (infinite loop risk).
- `toSignal` without handling the initial `undefined` (missing `initialValue` /
  `requireSync`).
- Manual subscription bookkeeping where `httpResource` / `toSignal` would remove
  it (see `angular-rxjs`).