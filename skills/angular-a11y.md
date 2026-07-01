---
name: angular-a11y
description: >-
  Angular accessibility conventions AND review checks: semantic HTML first, correct
  ARIA, the CDK a11y utilities (LiveAnnouncer, FocusMonitor, focus trap), keyboard
  operability, focus management on navigation/dialogs, and accessible forms. Use
  whenever building or reviewing any Angular UI — a component, template, dialog,
  menu, or form — since accessibility applies to all of it, even if the task
  doesn't mention it.
---

# Angular accessibility

- **Semantic HTML first** — real `<button>`, `<a>`, `<label>`, headings, and
  landmarks. Reach for ARIA only to fill genuine gaps; don't add redundant or
  invalid roles.
- **Keyboard operability** — every interactive element must be reachable and
  usable by keyboard, with a visible focus indicator. Custom widgets need the
  expected key handling (Enter/Space/arrows/Escape).
- **CDK a11y** (`@angular/cdk/a11y`): `LiveAnnouncer` to announce dynamic changes,
  `cdkTrapFocus` for dialogs/menus, `FocusMonitor` and `cdkFocusInitial` for focus
  management, `A11yModule` utilities. The Angular Aria package (dev preview) gives
  headless accessible primitives.
- **Focus management** — move focus sensibly on route changes, dialog open/close,
  and async content insertion; return focus to the trigger on close.
- **Forms** — every control has an associated `<label>`; validation errors are
  programmatically associated and announced.
- **Images/media** — meaningful `alt`; decorative images marked empty `alt`.

## Review checklist

- Interactive element not keyboard-operable, or `<div>`/`<span>` used where a
  `<button>`/`<a>` belongs.
- Missing/incorrect labels on form controls; errors not associated/announced.
- ARIA misuse — redundant roles, invalid attributes, or ARIA compensating for
  non-semantic markup.
- Dynamic content changes not announced (`LiveAnnouncer`); focus not managed on
  dialog/route changes.
- Images without appropriate `alt`.