---
name: dotnet-language-version
description: >-
  Detect the effective C# language-version floor across a repository's .csproj /
  Directory.Build.props files, and gate feature usage to it — so the agent uses
  the NEWEST idiomatic C# features that are actually available, and never ones
  that won't compile on the target. Use at the start of any C#/.NET build or
  review task, and whenever choosing between language features, deciding whether
  a feature (records, collection expressions, primary constructors, the `field`
  keyword, extension members, `params` collections, `System.Threading.Lock`) is
  allowed, or seeing a "feature is not available in C# N" error.
---

# C# language version — detect the floor, then use the newest features it allows

Goal: write the most modern, idiomatic C# the project can actually compile, and
nothing above that line. The floor is set by the **lowest target framework**
across the solution (plus any `<LangVersion>` pin), because C# 14 needs .NET 10,
C# 13 needs .NET 9, and so on — a newer language version than the TFM is
unsupported.

## Step 1 — Detect the floor

Run the bundled detector against the repo root (it lives in this skill's folder):

```
python3 <this-skill-dir>/detect-langversion.py <repo-root>
```

It reports the floor (e.g. `C# FLOOR: C# 12`), a per-project breakdown, and
warnings (e.g. a `<LangVersion>` pinned above its TFM, or a `latest` opt-in whose
runtime still caps it). For an exact value on a tricky project, cross-check with
`dotnet msbuild <proj> -getProperty:LangVersion`.

Manual fallback (if you can't run the script): read each `.csproj` (and any
`Directory.Build.props`). If `<LangVersion>` is a number, that's the cap;
otherwise map the lowest `<TargetFramework(s)>` via the table below. The floor is
the minimum across all projects.

**TFM → default C# version:** net10.0 → 14 · net9.0 → 13 · net8.0 → 12 · net7.0 →
11 · net6.0 → 10 · net5.0 → 9 · netcoreapp3.1 / netstandard2.1 → 8 · netstandard2.0
/ .NET Framework → 7.3.

## Step 2 — Gate features to the floor

Use the newest features **at or below** the floor; treat everything above it as
unavailable. Feature → minimum C# version (some also need the matching runtime):

- **C# 8** (netstandard2.1 / netcoreapp3.1): nullable reference types, async
  streams (`IAsyncEnumerable`), switch expressions, ranges & indices, `using`
  declarations, default interface members.
- **C# 9** (net5): records, `init` accessors, target-typed `new`, top-level
  statements, relational/logical patterns.
- **C# 10** (net6): file-scoped namespaces, global usings, `record struct`,
  extended property patterns.
- **C# 11** (net7): raw string literals, list patterns, `required` members, UTF-8
  string literals, static abstract interface members / generic math (runtime: net7+).
- **C# 12** (net8): primary constructors (classes/structs), collection expressions
  `[...]` + spreads, default lambda parameters, `using` alias for any type,
  inline arrays (runtime: net8+).
- **C# 13** (net9): `params` collections, `System.Threading.Lock` (runtime type is
  net9+), partial properties/indexers, `ref`/`unsafe` in iterators & async,
  implicit index (`^`) in initializers, overload-resolution priority.
- **C# 14** (net10): the `field` keyword, extension members (`extension` blocks),
  null-conditional assignment (`obj?.Prop = …`), partial constructors & events,
  user-defined compound assignment, first-class `Span<T>`/`ReadOnlySpan<T>`
  conversions.

So a **C# 12 floor** means: use records, primary constructors, and collection
expressions freely — but not the `field` keyword, extension members, `params`
collections, or `System.Threading.Lock` (those need net9/net10).

## Multi-targeting

For `<TargetFrameworks>` (plural), unconditional code must compile against the
**lowest** TFM. If a newer feature genuinely helps on newer runtimes, guard it
behind `#if NET9_0_OR_GREATER` (etc.) rather than raising the floor for everyone.
An explicit `<LangVersion>` pin applies to every target — respect a deliberate
down-pin as a house decision, don't "modernize" past it.

## Review notes

- A feature used above the detected floor (will fail to build, or is unsupported
  on the target runtime).
- A newer feature added to shared/unconditional code in a multi-target project
  without an `#if` guard.
- "Modernizing" past a deliberate `<LangVersion>` down-pin.
- Conversely: verbose legacy patterns where a floor-available modern feature is
  clearly cleaner (e.g. hand-written backing fields on a C# 14 floor, or manual
  collection init on a C# 12 floor).