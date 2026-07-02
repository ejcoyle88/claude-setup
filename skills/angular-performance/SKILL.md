---
name: angular-performance
description: >-
  Angular performance conventions AND review checks: OnPush/zoneless change
  detection, @defer for lazy loading, @for track for DOM reuse, bundle budgets,
  SSR with incremental hydration, NgOptimizedImage, and lazy routes. Use whenever
  optimizing or reviewing an Angular app for speed, bundle size, or Core Web
  Vitals, or judging whether a rendering pattern will scale — even if the task
  just says "make this faster" or "why is this slow?". Pairs with the performance
  reviewer.
---

# Angular performance (measure first)

- **OnPush + zoneless + signals** is the rendering model: fine-grained,
  signal-driven updates instead of app-wide checks. Signals don't make heavy
  computation free — keep `computed`/`effect` cheap and memoized.
- **`@defer`** (triggers: `on viewport` / `on idle` / `on interaction` / `on timer`)
  to lazy-load heavy or below-the-fold components; pair with SSR **incremental
  hydration** so deferred blocks hydrate on demand.
- **`@for` with a stable `track`** so the DOM is reused instead of rebuilt on list
  changes (tracking `$index` defeats this).
- **Lazy routes** (`loadComponent` / `loadChildren`) and **bundle budgets** in
  `angular.json` — keep initial bundles within budget.
- **`NgOptimizedImage`** for images (lazy loading, sizing, priority hints).
- **Bridge RxJS → signals at the UI boundary** so stream churn doesn't drive
  render.
- Profile with the Angular DevTools profiler / Lighthouse / a bundle analyzer
  before optimizing.

## Review checklist

- New/edited component not `OnPush` (or relying on Zone.js implicit CD).
- `@for` tracking `$index` (or no `track`) on a list that mutates.
- Heavy synchronous work in a template binding, `computed`, or `effect`.
- Heavy/below-the-fold content not behind `@defer`.
- Feature area eagerly loaded; initial bundle over budget.
- Images without `NgOptimizedImage`; missing SSR/hydration where it would help LCP.