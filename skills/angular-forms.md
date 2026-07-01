---
name: angular-forms
description: >-
  Angular forms conventions AND review checks: strictly-typed reactive forms
  (FormGroup / FormControl / nonNullable FormBuilder), Signal Forms (stable in
  v22), synchronous and async validators, and form state handling. Use whenever
  building or reviewing an Angular form — controls, validation, submission, or
  reacting to value/status changes — even if the task just says "add a form" or
  "validate this field".
---

# Angular forms

- **Reactive forms, strictly typed** — build with the `nonNullable` `FormBuilder`
  so controls aren't implicitly nullable; type the model. Avoid template-driven
  forms for anything non-trivial.
- **Signal Forms** (stable in v22) are the signal-native successor, replacing the
  `valueChanges` subscription pattern with signal-based state. Check which the
  project uses; prefer Signal Forms for new work on v22, reactive forms otherwise —
  don't mix styles within one form.
- **Validation**: composable sync validators and async validators (return
  Observable/Promise of errors); surface messages from control state
  (`touched`/`dirty`/`errors`), don't hand-roll parallel error tracking.
- **State**: when reading `valueChanges` / `statusChanges` on reactive forms,
  manage the subscription (`takeUntilDestroyed` or `async` pipe — see
  `angular-rxjs`), or prefer signal-based state.

## Review checklist

- Untyped / implicitly-nullable controls (not using the `nonNullable` builder).
- Template-driven forms where a typed reactive/signal form belongs.
- Missing or client-only validation on inputs that matter.
- `valueChanges` subscribed without teardown (leak).
- Mixed reactive + signal form styles in one form.