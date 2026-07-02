---
name: angular-components
description: >-
  Modern Angular component conventions AND review checks: standalone components,
  OnPush / zoneless change detection, the new control flow (@if / @for / @switch /
  @defer), signal-based inputs/outputs/model/queries, host bindings, and
  lifecycle. Use whenever building or reviewing an Angular component or template —
  structure, bindings, control flow, change detection, or how a component exposes
  inputs/outputs — even if the task just says "add a component" or "fix this
  template".
---

# Angular components

- **Standalone** components/directives/pipes (default since v17): declare
  dependencies in `imports:`; no NgModules.
- **Change detection**: new projects are **zoneless** (v21+) and new components
  default to **`OnPush`** (v22). Never rely on Zone.js implicit CD — drive updates
  with signals, the `async` pipe, or `markForCheck`. Mutating a field without
  notifying Angular won't render in zoneless.
- **Control flow in templates**: `@if` / `@else if` / `@else`, `@for`, `@switch`,
  and `@defer`. The old `*ngIf` / `*ngFor` / `*ngSwitch` are deprecated.
  - `@for` **requires** `track`; use a stable identity (`track item.id`), not
    `$index`, so the DOM is reused correctly on list changes.
  - `@defer` with `@placeholder` / `@loading` / `@error` and triggers
    (`on viewport`, `on idle`, `on interaction`, `on timer`) to lazy-load heavy or
    below-the-fold content.
- **Signal-based APIs** over decorators: `input()` / `input.required()`,
  `output()`, `model()` (two-way), and signal queries `viewChild()` /
  `viewChildren()` / `contentChild()`. Read signals in templates as `value()`.
- **State**: local UI state as `signal`, derived state as `computed`; keep
  templates cheap (no heavy work in bindings — see `angular-performance`).
- **Lifecycle / DOM**: prefer `afterNextRender` / `afterRenderEffect` for one-off
  DOM work and `effect()` for reactive side effects, over `ngAfterViewInit`
  plumbing.

## Review notes

- Component relies on implicit change detection (mutates state without a signal /
  `async` pipe / `markForCheck`) — will silently not update under zoneless.
- `@for` without a stable `track` (or tracking `$index`).
- Deprecated `*ngIf` / `*ngFor` / `*ngSwitch` in new/edited templates.
- Decorator `@Input()` / `@Output()` where signal `input()` / `output()` fit.
- New component not `OnPush`-compatible without reason.