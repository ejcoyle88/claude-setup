---
name: developer-workflow
description: >-
  Shared working scaffolding for the language-specialist developer subagents
  (csharp-developer, rust-developer, and any future <lang>-developer): the
  establish-context-then-edit workflow, Serena symbol-aware navigation, the
  orchestrator escalation protocol, the quality gate, and the return contract.
  Preloaded into each developer via its `skills:` frontmatter. Keep
  language-specific rules OUT of here — those live in the language's own skills.
---

# Developer workflow (shared)

This is the common operating procedure for every language-specialist developer.
Your language body adds the house defaults, the skill index, and the concrete
quality-gate commands for your stack; everything below is shared.

## When invoked

1. Establish context first — read **symbols, not whole files** (see Semantic
   code tools). Check the build/manifest files (solution, project, package, or
   manifest) for the target language version, lint/warning settings, and the
   dependencies already in use.
2. Match existing conventions and libraries before introducing new ones. Don't
   add a dependency the project doesn't already use without flagging it.
3. Work test-first: write a failing test, make it pass, refactor with tests
   green. Run the test suite to confirm red → green at each step.
4. Report back per the Return contract.

## Semantic code tools (Serena MCP)

When `mcp__serena__*` tools are available, prefer them over reading whole files
or grepping when navigating and editing *existing* code — they're symbol-aware,
more precise, and far more token-efficient. They add little value when writing
new code from scratch; use normal file tools there.

- `get_symbols_overview` to map a file's or directory's types and members.
- `find_symbol` by name path to read only the symbol you need.
- `find_referencing_symbols` before changing a signature or behaviour — impact
  analysis, not a grep.
- `replace_symbol_body` / `insert_before_symbol` / `insert_after_symbol` for
  symbol-level edits; `rename_symbol` where the language server supports it.
- Use plain `Read` / `Grep` / `Glob` for non-code files and text/filename search.
- Symbol-tool quality depends on a healthy language server for *this* language;
  if results look empty or stale, fall back to `Read` / `Grep` rather than guessing.

## Escalation (when you can't reach the user)

If you're running under an orchestrator (e.g. `/build-next`) you cannot prompt
the user directly. On a blocking unknown, do **not** guess: stop and return a
`NEEDS-INPUT` block with the question, the context behind it, and your
recommended answer. The orchestrator will get an answer and re-invoke you.

## Quality gate (before reporting done)

- Build clean with warnings treated as errors; the project's formatter/linter
  satisfied.
- All tests green; new behaviour meaningfully covered (don't chase a percentage).
- Dependencies clean of known vulnerabilities and deprecations; versions pinned
  per the project's convention.
- Public APIs documented where it adds value.

Your language body lists the concrete command for each of these.

## Return contract

Hand back a short, scannable report for the main session: summary of changes,
test results, new or changed dependencies with license notes, and recommended
follow-ups.