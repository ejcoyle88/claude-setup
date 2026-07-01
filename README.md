# Claude Code Configuration

A shareable, version-controlled set of Claude Code customizations — subagents, skills, slash commands, hooks, a status line, and shared settings. An installer symlinks each piece into your `~/.claude` directory and merges the shared settings into your local `settings.json`, so the whole configuration can live in one repo and be kept in sync across machines.

## What's in here

| Path | Purpose |
| --- | --- |
| `agents/` | Subagent definitions — specialist builders and code reviewers |
| `skills/` | Skills carrying language conventions and review checklists |
| `commands/` | Slash commands that orchestrate the agents |
| `hooks/` | Hook scripts run by the Claude Code harness |
| `settings.shared.json` | Shared settings merged into your local `settings.json` |
| `statusline-command.sh` | Custom status line renderer |
| `install.sh` | Idempotent installer (symlinks + settings merge) |
| `tests/` | Test suite for the installer |

## Installation

Requires [`jq`](https://stedolan.github.io/jq/).

```bash
./install.sh
```

The installer is idempotent and non-destructive:

- **Symlinks** every entry under `skills/`, `agents/`, `commands/`, and `hooks/`, plus `statusline-command.sh`, into the matching location in `~/.claude`. If a real file already exists at the target, it is backed up (`<name>.backup-<timestamp>`) before the link is created.
- **Merges** `settings.shared.json` into `~/.claude/settings.json` (shared values take precedence), rewriting the file only when the result actually changes.
- **Prunes** stale symlinks that point back into this repo but whose source has been deleted or renamed.

Override the install target with the `CLAUDE_DIR` environment variable (defaults to `$HOME/.claude`):

```bash
CLAUDE_DIR=/some/other/.claude ./install.sh
```

## Agents

**Builders** (`model: sonnet`, carry the `developer-workflow` skill):

- **`angular-developer`** — Angular v22 web apps and SPAs: signals, standalone components, the new control flow, RxJS interop, routing, forms, HttpClient, a11y, testing.
- **`csharp-developer`** — server-side .NET 10 / C# 14: ASP.NET Core APIs, DI, async pipelines, Dapper, durable workflows, caching, observability.
- **`rust-developer`** — application and service Rust (2024 edition): async services on Tokio, CLIs, workers, network clients, typed error handling.

**Reviewers** (read-only, return structured findings for the `/review` orchestrator):

- **`quality-reviewer`** (`haiku`) — correctness, error handling, concurrency, maintainability, tests, docs.
- **`performance-reviewer`** (`sonnet`) — algorithmic cost, data access, allocations, contention, caching.
- **`security-reviewer`** (`sonnet`) — vulnerabilities in a diff.

## Skills

Each skill bundles the idiomatic conventions **and** the corresponding review checklist for one area, so builders and reviewers judge against the same source of truth.

- **Angular** — `angular-signals`, `angular-components`, `angular-forms`, `angular-http`, `angular-rxjs`, `angular-di-routing`, `angular-performance`, `angular-a11y`, `angular-testing`, `angular-dependencies`.
- **.NET** — `dotnet-architecture`, `dotnet-aspnetcore-apis`, `dotnet-modern-csharp`, `dotnet-data-access`, `dotnet-caching`, `dotnet-cloud-native`, `dotnet-temporal`, `dotnet-performance`, `dotnet-testing`, `dotnet-dependencies`.
- **Rust** — `rust-idioms`, `rust-async-tokio`, `rust-error-handling`, `rust-testing`, `rust-dependencies`.
- **Shared** — `developer-workflow` (the establish-context-then-edit loop the language builders share) and `systematic-debugging` (a hypothesis-driven debugging discipline, with supporting notes and helper scripts).

## Commands

- **`/build-next [bead-id]`** — takes the next backlog task end to end: clarifies up front, implements with a language specialist, then runs up to two specialist review cycles. Completes one task.
- **`/review [base-ref] [--suggestions] [--praise]`** — orchestrates a code review, inline for small changes or fanned out to the specialist reviewers for large ones, and reports findings by severity. Read-only.

## Hooks

- **`hooks/lsp-first-guard.py`** — an LSP-first guard wired to two harness events:
  - On **`SessionStart`** it injects a "semantic-tools-first" policy into the model's context, nudging it toward LSP-backed symbol tools (Serena, rust-analyzer, csharp-lsp) over grep.
  - On **`PreToolUse(Grep)`** it denies a Grep only when the pattern is a bare identifier *and* the search is scoped to a language with an LSP (Rust, C#, TypeScript), pointing at the semantic tools instead. Free-text searches, unknown languages, and non-code files pass through untouched.

  Add languages by editing the `LANGUAGES` map at the top of the script.

## Status line

`statusline-command.sh` renders `user@host:cwd`, then the model name, the current git branch, and color-coded context-window usage (green < 50%, yellow 50–80%, red > 80%).

## Settings

`settings.shared.json` holds the portion of `~/.claude/settings.json` meant to be shared: a Bash/MCP permission allowlist, the default model, the hook wiring for the LSP guard, the status line command, enabled plugins and marketplaces, and editor/theme preferences. The installer merges it over your existing local settings rather than overwriting them.

## Testing

```bash
tests/test_install.sh
```

The suite runs `install.sh` against a temporary `CLAUDE_DIR` and asserts its symlinking, backup, merge, and pruning behavior.
