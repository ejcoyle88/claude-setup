# Copilot instructions for this repository

> **Read this before reviewing.** This repo is **Claude Code configuration**, not a
> conventional application. Most files are Markdown prompts or JSON/shell config that
> Claude Code (Anthropic's agentic CLI) loads at runtime. Several things that look like
> mistakes are correct and intentional. Please do not flag the items called out below.

## What this repository is

A shareable, version-controlled set of Claude Code customizations — subagents (`agents/`),
skills (`skills/`), slash commands (`commands/`), hooks (`hooks/`), a status line, and
shared settings (`settings.shared.json`). `install.sh` symlinks each piece into a user's
`~/.claude` directory and merges the shared settings into their local `settings.json`.

Implication for review: the `.md` files here are **not documentation** — they are
executable prompts and declarative config consumed by the Claude Code harness. Judge them
against Claude Code's formats (below), not against general "good README/Markdown" style.
Do not rewrite an agent/skill/command prompt toward generic prose; the second-person
imperative voice ("You are a reviewer…", "Do X, never Y") is the required format.

## Model names and IDs are current and correct — do NOT "fix" them

Your training data likely predates these releases. The following are **real, current**
Anthropic model names and identifiers. Do **not** flag them as typos, hallucinations, or
invalid, and do **not** suggest "correcting" them to older names (e.g. `claude-3-5-sonnet`):

- Families/names: **Claude 5 family**, **Opus 4.8**, **Sonnet 5**, **Haiku 4.5**, **Fable 5**.
- Model IDs: `claude-opus-4-8`, `claude-sonnet-5`, `claude-haiku-4-5-20251001`, `claude-fable-5`.
- Short aliases used in frontmatter/settings: `opus`, `sonnet`, `haiku` — these are valid
  Claude Code model shorthands.
- The `[1m]` suffix (e.g. `opus[1m]`, `claude-opus-4-8[1m]`) selects the 1M-token context
  variant. It is intentional syntax, not a stray token or typo.

## File formats you'll see (and must not "correct")

### Agents (`agents/*.md`), skills (`skills/**/SKILL.md`), commands (`commands/*.md`)

Each begins with a **YAML frontmatter block** delimited by `---`. Valid, expected fields:

- Agents: `name`, `description`, `tools`, `model`.
- Commands: `description`, `argument-hint`, `allowed-tools`, `model`.
- Skills: `name`, `description` (in a file that **must** be named `SKILL.md`).

Do not flag these fields as unknown, and do not require additional fields. `description`
values are often long, multi-line YAML block scalars (`>-`); that is valid YAML.

### Tool / permission syntax

`tools:` and `allowed-tools:` list Claude Code tool names, some with a **permission-scope
glob** in parentheses. These are all valid and intentional — not malformed function calls
or unbalanced parens:

- Bare tools: `Read`, `Grep`, `Glob`, `Bash`, `Task`, `WebSearch`.
- Scoped Bash: `Bash(git diff:*)`, `Bash(git status:*)`, `Bash(dotnet test:*)`. The `:*`
  is a prefix wildcard for allowed command arguments.
- MCP tools: `mcp__serena__get_symbols_overview`, `mcp__context7__*`. The double-underscore
  naming is the required MCP convention — do not flag as a typo or suggest single underscores.

### Slash-command directives (`commands/*.md`)

Inside command prompts these tokens are **Claude Code template syntax**, not shell/JS bugs:

- `$ARGUMENTS` — placeholder for the command's arguments.
- `` !`some command` `` — inline bash the harness runs, substituting the output.
- `@path/to/file` — a file reference the harness expands.

### `settings.shared.json`

This is a partial `~/.claude/settings.json` merged over the user's local settings. Notes for review:

- The `permissions.allow` array contains Claude Code permission strings, e.g.
  `Bash(git add:*)`. Some entries look odd but are deliberate: `Bash(fi)`, `Bash(done)`,
  `Bash(do test:*)` allowlist shell-loop keywords/fragments so multi-line scripts don't
  re-prompt. Do not flag these as mistakes.
- `hooks` keys are Claude Code lifecycle events: `SessionStart`, `PreToolUse`, `PreCompact`,
  `Notification`, `Stop`. Empty `hooks: []` arrays are intentional placeholders.
- `model: "opus[1m]"` — see the model section above; not a typo.

### Hooks (`hooks/*.py`)

Hook scripts read a JSON event on stdin and may print JSON to stdout to influence the
harness (e.g. deny a tool call). Exit codes and stdout shape follow the Claude Code hooks
contract; judge them against that, not against a generic CLI convention.

## Where normal review rigor DOES apply

Please review these as you normally would:

- **`install.sh`** and **`tests/test_install.sh`** — real Bash. Correctness, quoting,
  portability (they target both GNU and BSD `stat`), idempotency, and safe symlink/backup
  handling all matter here.
- **`hooks/*.py`** — real Python logic worth checking for bugs.
- **`.github/workflows/*.yml`** — CI correctness.
- **JSON validity** of `settings.shared.json` (well-formedness, duplicate keys), and
  **YAML validity** of frontmatter blocks.

## Summary

Focus review on the shell, Python, YAML/JSON *mechanics*. Treat Claude Code model names,
frontmatter schemas, tool/permission globs, MCP tool names, slash-command directives, and
hook event names as a known, correct domain vocabulary — not as errors to fix.
