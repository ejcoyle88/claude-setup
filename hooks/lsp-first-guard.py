#!/usr/bin/env python3
"""
LSP-first guard for Claude Code.

Two behaviours, dispatched on the hook event read from stdin:

  • SessionStart    -> prints the semantic-tools-first policy. For SessionStart,
                       stdout (on exit 0) is injected into the model's context,
                       so the policy is re-asserted every session (fights drift).

  • PreToolUse(Grep) -> when a Grep is clearly a *symbol* search in a language
                       that has an LSP, deny it and point at the semantic tools
                       instead. Everything else — free-text searches, non-code
                       files, unknown language — is allowed untouched.

The deny is deliberately conservative: it fires only when the pattern is a bare
identifier AND the search is scoped (via ripgrep `type`, a `glob`, or the `path`)
to a language in LANGUAGES below. That keeps real text search working while
catching the "should've used the LSP" cases.

Edit LANGUAGES to add languages or point at your own LSP-backed tools. Invoked as
`python3 <this file>`, so no executable bit is required.
"""

import json
import re
import sys

# ── Config: language -> how to recognise it, and what to use instead ─────────
# `types`: ripgrep --type aliases that identify the language.
# `exts` : file extensions (matched against glob/path/pattern).
# `tools`: the semantic tools to recommend in the deny message.
LANGUAGES = {
    "Rust": {
        "types": {"rust", "rs"},
        "exts": {".rs"},
        "tools": "rust-analyzer / Serena symbol tools "
                 "(find_symbol, find_referencing_symbols, get_symbols_overview)",
    },
    "C# / .NET": {
        "types": {"cs", "csharp", "c#"},
        "exts": {".cs"},
        "tools": "csharp-lsp / Serena symbol tools "
                 "(find_symbol, find_referencing_symbols, get_symbols_overview)",
    },
    "TypeScript": {
        "types": {"ts", "typescript", "tsx"},
        "exts": {".ts", ".tsx"},
        "tools": "typescript-language-server / Serena symbol tools",
    },
    # Add more as you add language specialists, e.g.:
}

POLICY = (
    "Semantic-tools-first policy for this repo. To find, understand, or edit "
    "CODE SYMBOLS (types, functions, methods, references, call sites), prefer "
    "the LSP-backed tools over grep / glob / whole-file reads:\n"
    "  - Cross-language: Serena (get_symbols_overview, find_symbol, "
    "find_referencing_symbols, replace_symbol_body, insert_*_symbol).\n"
    "  - Rust: rust-analyzer.    - C#/.NET: csharp-lsp.\n"
    "Use Grep/Glob only for non-code text (config, SQL, comments, prose) or as a "
    "fallback when the LSP genuinely returns nothing. For raw text *inside* code, "
    "use Serena's search_for_pattern rather than Grep. A PreToolUse guard "
    "enforces this on code-scoped symbol searches."
)

# A single bare identifier (>= 2 chars): the signature of a symbol lookup.
IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{1,}$")
# Characters that mark a pattern as regex / multi-word free text, not a symbol.
FREE_TEXT_CHARS = set(" \t|().*+?[]{}^$\\/\"'")


def detect_language(tool_input):
    """Return a LANGUAGES key if the grep is scoped to a known code language."""
    type_ = str(tool_input.get("type") or "").lower()
    scoped = " ".join(
        str(tool_input.get(k, "")) for k in ("glob", "path", "pattern")
    ).lower()
    for lang, cfg in LANGUAGES.items():
        if type_ in cfg["types"]:
            return lang
        if any(ext in scoped for ext in cfg["exts"]):
            return lang
    return None


def looks_like_symbol(pattern):
    """True for a bare identifier; False for regex / phrase / free-text searches."""
    if not pattern or any(c in FREE_TEXT_CHARS for c in pattern):
        return False
    return bool(IDENTIFIER.match(pattern))


def main():
    try:
        event = json.load(sys.stdin)
    except Exception:
        sys.exit(0)  # never break the session on a parse error

    name = event.get("hook_event_name", "")

    if name == "SessionStart":
        print(POLICY)  # injected as context for SessionStart
        sys.exit(0)

    if name == "PreToolUse" and event.get("tool_name") == "Grep":
        tool_input = event.get("tool_input", {}) or {}
        lang = detect_language(tool_input)
        pattern = tool_input.get("pattern", "")
        if lang and looks_like_symbol(pattern):
            cfg = LANGUAGES[lang]
            reason = (
                f"This is a {lang} symbol search ('{pattern}'). Use {cfg['tools']} "
                f"instead of grep — they resolve definitions and references "
                f"precisely and far more cheaply than scanning text. For raw text "
                f"inside {lang} code, use Serena's search_for_pattern. Grep stays "
                f"available for non-code text and as a fallback if the LSP returns "
                f"nothing."
            )
            print(json.dumps({
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }))
            sys.exit(0)

    sys.exit(0)  # default: allow / no-op


if __name__ == "__main__":
    main()