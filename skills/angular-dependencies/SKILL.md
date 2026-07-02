---
name: angular-dependencies
description: >-
  Angular dependency conventions AND review checks: npm package management,
  keeping @angular/* packages version-aligned, upgrading with `ng update` and
  running migration schematics, `npm audit` and licensing, and using the Angular
  CLI MCP server. Use whenever adding, updating, or reviewing an npm dependency in
  an Angular project — or judging whether one is warranted, safe, or version-
  compatible — even if the task just says "add a library for X" or "upgrade Angular".
---

# Angular dependencies

- Keep all **`@angular/*` packages on the same major version**; a mismatch breaks
  the build in subtle ways.
- **Upgrade with `ng update @angular/core @angular/cli`** rather than editing
  `package.json` by hand — it runs the migration schematics for that version jump.
  Run the modernization schematics when adopting new APIs: `@angular/core:control-flow`,
  `:inject`, `:signal-input-migration`, `:signal-queries-migration`, `:output-migration`,
  and the standalone migration.
- **Audit & licensing**: keep `npm audit` clean; check a new dependency's license
  and maintenance health; commit the lockfile.
- Before adding a UI/util library, check the **Angular CDK** and framework
  built-ins first — a lot (a11y, overlay, drag-drop, virtual scroll) is already there.
- Use the **Angular CLI MCP server** (`ng mcp`) for project-aware help and
  migration tooling (e.g. the OnPush/zoneless migration) instead of guessing.

## Review checklist

- `@angular/*` packages on mismatched versions.
- A new dependency that isn't warranted, or duplicates CDK / framework built-ins.
- Known CVEs (`npm audit`) or an unacceptable license (severity for advisories is
  the security reviewer's call).
- `package.json` bumped without running `ng update` migration schematics.
- Missing/uncommitted lockfile.