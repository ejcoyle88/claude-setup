---
name: dotnet-dependencies
description: >-
  Dependency conventions AND review checks for .NET: license-awareness for
  once-default libraries that became commercial (MediatR, AutoMapper, Duende),
  Central Package Management, vulnerability/deprecation checks, and finding
  real-time package data via web search, context7, or nuget.org (no NuGet MCP
  is configured). Use whenever adding, updating, replacing,
  or reviewing a NuGet dependency — or judging whether a new package is warranted,
  acceptably licensed, healthy, or safe — even if the task just says "add a
  package for X".
---

# Dependencies

## License-awareness (check before adding these)

Several once-default .NET libraries became commercial. Never add them silently —
flag the license and offer a free alternative:

- **MediatR / AutoMapper** — commercial dual-license (Lucky Penny Software).
  Free only for orgs under ~$5M revenue. Prefer calling handlers/services
  directly, the source-generated `Mediator` (martinothamar), or `Brighter`;
  for mapping, `Mapperly` (source generator) or hand-written mapping. See
  "Old patterns" below for the specific relicensing date and last-free
  version — confirm current terms before relying on them.
- **Duende IdentityServer** — paid for production above the small-org free tier.
  Prefer `OpenIddict` (MIT) or platform identity (Entra ID / OIDC).

If the project already licenses these, use them normally.

## Old patterns (as of 2026-07-03)

- **MediatR / AutoMapper relicensing** — went commercial dual-license in July
  2025; MediatR v12.x was the last fully-permissive line. Licensing terms and
  version lines drift — re-verify via web search or the vendor's site rather
  than trusting this date.

## Hygiene

- **Central Package Management** (`Directory.Packages.props`) for version consistency.
- Keep `dotnet list package --vulnerable` and `--deprecated` clean.
- No NuGet MCP server is configured in this environment. For real-time package
  info, framework-compatible version recommendations, and advisories, use web
  search, `context7` (library docs), or check nuget.org directly — don't rely
  on memory for current versions or advisories.

## Review checklist

- Is a new dependency actually warranted, or does the platform/existing stack
  already cover it?
- License acceptable (watch the commercial-relicensed list above).
- Known CVEs or supply-chain concerns (severity is the security reviewer's call).
- Maintenance health (last release, open critical issues).
- Added outside Central Package Management.