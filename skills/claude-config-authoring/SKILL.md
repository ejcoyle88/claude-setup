---
name: claude-config-authoring
description: >-
  Authoring conventions AND review checks for Claude Code configuration:
  subagent definitions, skills (SKILL.md), slash commands, hooks, settings.json,
  and CLAUDE.md. Use whenever writing, editing, or reviewing any file under
  ~/.claude/ or a repo's .claude/ — agents, skills, commands, hook scripts, tool
  allowlists, MCP wiring — even if the task just says "improve this agent" or
  "add a skill". Carries the known footguns; check them before shipping.
---

# Claude Code config authoring

## Where content belongs (token cost is the organizing principle)

- **Agent body**: identity, scope, terse house defaults, a skill index, the
  stack-specific quality gate. It reloads on every invocation — keep it lean.
- **Skill**: deep, situational content loaded on description match. Shared
  standards get a `## Review checklist` so builders and reviewers use one text.
- **`~/.claude/CLAUDE.md`**: one-line, always-relevant standing conventions
  (e.g. "reusable scripts go in ~/.claude/scripts/"). Not skills — a rule that
  must apply on every task can't rely on description matching.
- **Hook**: deterministic enforcement. When "the model usually follows it" isn't
  good enough (tool-selection bias, drift), a hook beats any instruction.
- **Command**: orchestration and repeatable flows the *user* invokes; owns loop
  control, routing, and AskUserQuestion.

## Descriptions are the routing mechanism

An agent's `description` decides delegation; a skill's decides loading. Write
them trigger-oriented: what it covers, concrete phrases that should invoke it,
and what it does NOT cover. Err pushy — under-triggering is the common failure.
Don't change an agent's description when adding capability; capability isn't a
delegation trigger.

## Known footguns (check every one on review)

- **Omitted `tools:`** in a subagent silently grants the full toolset including
  MCP. Always write an explicit allowlist; MCP tools must be named
  (`mcp__<server>__*`, exact server key from `claude mcp list`).
- **`AskUserQuestion` doesn't work inside subagents** — agents must return a
  `NEEDS-INPUT` block for the orchestrator instead. Any subagent prompt telling
  it to "ask the user" is a bug.
- **Only the final message returns** from a subagent. Anything the next hop
  needs (ids, file lists, findings) must be in the return contract, and the
  orchestrator must pass context forward explicitly.
- **`$CLAUDE_PROJECT_DIR` is the project root**, not `~/.claude` — global hooks
  and scripts reference `$HOME/.claude/...` (quoted paths need `$HOME`, not `~`).
- **Version-sensitive claims drift**: frontmatter fields, hook schemas, model
  defaults, and feature availability change between Claude Code releases —
  verify against the live docs, don't trust memory.
- **Loops live in the orchestrator**: keep "run N times" / conditional-cycle
  logic in the command (main session), never inside a subagent.

## Hooks

- Read the event JSON from stdin; dispatch on `hook_event_name`. `PreToolUse`
  responds with `hookSpecificOutput.permissionDecision` (`deny`/`ask`/`allow`)
  plus a reason; `SessionStart` stdout is injected as context.
- Exit 0 on any parse error — an *observational* hook must never break the
  session. **Exception: security-boundary hooks fail closed** — a guard whose job
  is to block unsafe calls (e.g. `reviewer-bash-guard.py`) must treat an
  unparseable payload as a denial (exit 2), never let it through. Pick the
  failure mode from the hook's purpose, and say which in a comment.
- Keep triggers minimal (`matcher` scoped to the specific tool) and denials
  conservative: under-block, and always name the alternative in the reason.
- Ship smoke tests: representative payloads piped on stdin with expected output,
  runnable in one bash block.

## Review checklist

- Frontmatter invalid or missing required fields; `tools:` omitted entirely.
- Broad grants without cause: bare `Bash` where scoped `Bash(cmd:*)` works; a
  wildcard MCP grant on an agent that uses one tool.
- `AskUserQuestion` (or "ask the user") inside a subagent definition or the
  prompt an orchestrator sends one.
- Duplicated conventions across agents that belong in one shared skill
  (single-source-of-truth violation); always-on rules parked in a skill instead
  of CLAUDE.md.
- Agent body carrying deep domain content that belongs in a skill (token bloat).
- Vague descriptions that won't trigger ("helps with code"), or a description
  changed as a side effect of a capability change.
- Hook without smoke tests, without the exit-0-on-error guard, or with an
  over-broad matcher/deny.
- Hard-coded `$CLAUDE_PROJECT_DIR` in global config; `~` inside quoted paths.