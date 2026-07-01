---
name: angular-testing
description: >-
  Angular testing conventions AND review checks: Vitest (the default runner since
  v21), TestBed, CDK component harnesses, Angular Testing Library, mocking HTTP,
  and zoneless test patterns. Use whenever writing or reviewing Angular tests,
  deciding how to test a component/service, or judging whether new behaviour is
  covered — even if the task just says "add tests" or "is this tested?".
---

# Angular testing

- **Vitest** is the default runner for new projects (v21+); Karma/Jasmine are
  legacy — flag new tests still written for Karma.
- **TestBed** for components/services; **CDK component harnesses** to drive
  Material/CDK components without reaching into internals; **Angular Testing
  Library** for user-centric queries.
- **Zoneless tests**: prefer `await fixture.whenStable()` over
  `fixture.detectChanges()`; add `provideZonelessChangeDetection()` to match
  production behaviour. TestBed enforces OnPush compatibility and throws
  `ExpressionChangedAfterItHasBeenCheckedError` when state changes without a
  notification — fix the component (signals / `markForCheck`), don't paper over it.
- **HTTP**: use `provideHttpClientTesting` and assert on requests; never hit the
  network.
- **Coverage is a diagnostic, not a target** — cover behaviour, edge cases, and
  failure modes, not a percentage.

## Review checklist

- New behaviour, edge cases, and error paths meaningfully covered.
- Tests query the DOM / use harnesses and assert **behaviour**, not internal
  fields or private methods.
- New tests still on Karma/Jasmine instead of Vitest.
- `fixture.detectChanges()` where `await fixture.whenStable()` fits a zoneless
  component; an `ExpressionChanged...` error masked instead of fixed.
- Real HTTP instead of `provideHttpClientTesting`.