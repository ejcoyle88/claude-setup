#!/usr/bin/env python3
"""
reviewer-bash-guard.py — PreToolUse Bash allowlist for the review subagents.

WHY THIS EXISTS (bead claude-6gf.9): a subagent's `tools:` frontmatter is NOT an
independent restrictive scope. Empirically, the session-level permission grants in
settings.shared.json (notably `Bash(bash:*)` and raw `Bash(git ...:*)`) leak into
the reviewer subagents and are auto-approved there — so scoping a reviewer to
`tools: Bash(~/.claude/scripts/git-ro.sh:*)` does NOT actually stop it from running
`bash -c '...'`, raw `git`, or a chained `git-ro.sh diff HEAD; echo pwned`. That
made bead claude-6gf.8's git-ro.sh wrapper moot on its own.

Claude Code has no per-agent allow-narrowing and no per-agent `permissions.deny`.
The one documented mechanism that can restrict a subagent MORE than its session is
a PreToolUse hook that exits non-zero: a blocking hook is evaluated BEFORE the
permission allow/deny rules, so it overrides the broad session allow grants.

This hook enforces an ALLOWLIST (safe-by-default): a reviewer's Bash command is
permitted ONLY if it is a single, clean invocation of the git-ro.sh wrapper with no
shell metacharacters that could chain, redirect, substitute, or background another
command. Everything else — raw bash, raw git, subshells, `;`/`&&`/`|`, redirects,
command substitution, env-assignment prefixes — is refused. New dangerous spellings
are refused by default because they simply are not the wrapper.

Wire it into a reviewer agent's frontmatter:

    hooks:
      PreToolUse:
        - matcher: Bash
          hooks:
            - type: command
              command: python3 "$HOME/.claude/scripts/reviewer-bash-guard.py"

Contract: read the PreToolUse JSON on stdin. Exit 0 to allow. Exit 2 (with a
reason on stderr) to BLOCK — this is the exit code Claude Code treats as a hard
block that takes precedence over allow rules.
"""
import json
import os
import sys


def block(reason: str) -> "NoReturn":  # noqa: F821
    # Exit code 2 => hard block, evaluated before permission allow rules.
    sys.stderr.write("reviewer-bash-guard: BLOCKED — " + reason + "\n")
    sys.exit(2)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        # Fail CLOSED: if we cannot parse the request, do not allow it through.
        block("could not parse PreToolUse payload")

    # Fail CLOSED on any unexpected top-level shape (null, list, string, number):
    # otherwise data.get(...) below raises AttributeError -> uncaught -> exit 1,
    # and exit 1 is NOT a block (only exit 2 is), which would silently disable
    # this guard and let the broad session Bash grant through.
    if not isinstance(data, dict):
        block("PreToolUse payload was not a JSON object")

    # Only guard Bash. Any other tool the reviewer is allowed (Read/Grep/Glob)
    # is not our concern here.
    if data.get("tool_name") != "Bash":
        sys.exit(0)

    # Fail CLOSED if tool_input is missing or not an object. A `.get(key, {})`
    # default only applies when the key is ABSENT — a present-but-null tool_input
    # returns None (not the {} default), so validate the type explicitly.
    tool_input = data.get("tool_input")
    if not isinstance(tool_input, dict):
        block("Bash tool_input was missing or not an object")

    command = tool_input.get("command", "")
    if not isinstance(command, str) or not command.strip():
        block("empty or non-string Bash command")

    stripped = command.strip()

    # 1) Reject any shell metacharacter that enables chaining, redirection,
    #    command substitution, subshells, or backgrounding. This is what stops
    #    `git-ro.sh diff HEAD; echo pwned` and friends.
    #    DELIBERATELY STRICT / safe-by-default: this is a blind substring scan, not
    #    a shell-aware parse, so a literal `(`/`)`/`|` inside a quoted git argument
    #    (e.g. `log --pretty=format:'%h (%an)'`) is also rejected. That is an
    #    accepted false-positive: the reviewers only ever call
    #    `diff <base>...HEAD` / `status` / `log` / `merge-base` / `rev-parse`, none
    #    of which need these characters. We do NOT loosen this with shlex-style
    #    parsing, because parsing an attacker-influenced command string to decide
    #    which metacharacters are "really" syntax is exactly the class of
    #    complexity that reintroduces bypasses.
    forbidden = [";", "|", "&", "<", ">", "`", "$(", "${", "(", ")", "\n", "\r"]
    for tok in forbidden:
        if tok in command:
            block("shell metacharacter %r is not permitted; only a single, "
                  "un-chained git-ro.sh invocation is allowed" % tok)

    # 2) The command must START with the git-ro.sh wrapper — no leading env
    #    assignments (LD_PRELOAD=... foo), no `command`/`exec` wrappers, no other
    #    program. Accept the tilde, $HOME, and absolute spellings of the path.
    wrapper_forms = [
        "~/.claude/scripts/git-ro.sh",
        "$HOME/.claude/scripts/git-ro.sh",
        os.path.expanduser("~/.claude/scripts/git-ro.sh"),
    ]
    if not any(stripped == form or stripped.startswith(form + " ")
               for form in wrapper_forms):
        block("command must be a direct call to ~/.claude/scripts/git-ro.sh "
              "(got: %r)" % stripped[:120])

    # Clean single git-ro.sh invocation — allow it. git-ro.sh does its own
    # read-only subcommand/flag allowlisting from here.
    sys.exit(0)


if __name__ == "__main__":
    # Fail CLOSED on ANY unforeseen error path: block() raises SystemExit(2),
    # which is NOT caught here (SystemExit is not a subclass of Exception), so an
    # intentional block still propagates. Any other exception is turned into a
    # block rather than an exit-1 that would silently disable the guard.
    try:
        main()
    except Exception as exc:  # noqa: BLE001 — deliberate catch-all, fail closed
        block("internal guard error: %r" % exc)
