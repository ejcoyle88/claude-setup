#!/usr/bin/env bash
#
# git-ro.sh — read-only git wrapper for the review subagents.
#
# THIS FILE IS MEANT TO BE EXECUTED, NOT READ. The three review agents
# (security / performance / quality reviewer) call this instead of raw `git` so
# that their scoped git permission cannot be turned into an arbitrary-file-WRITE
# or -READ primitive (or into code execution) by a prompt-injection hidden in an
# untrusted diff, commit message, or .gitattributes. A raw `Bash(git log:*)`
# grant still allows, e.g.,
#   git log --format=%B -1 HEAD --output=~/.ssh/authorized_keys   (arbitrary write)
#   git diff -O/etc/shadow                                        (arbitrary read)
#   git diff --no-index /etc/shadow /dev/null                     (arbitrary read)
# This wrapper closes those holes with THREE layers:
#
#   1. Subcommand allowlist — only known read-only subcommands may run.
#   2. Safe-flag ALLOWLIST (not a deny-list) — every "-"/"--" argument must be an
#      explicitly-listed read-only display/filter flag, otherwise it is refused.
#      WHY an allowlist and not a deny-list: a deny-list has to enumerate every
#      dangerous spelling, and short-option bundling defeats that — `-zO/etc/shadow`
#      never starts with the denied `-O` prefix, so a prefix matcher waves it
#      through to git's orderfile-read primitive. An allowlist rejects EVERY flag
#      it does not recognise (novel spellings, bundles, `--no-index`, `--output`,
#      `-O`, …) by default, so new dangerous flags are safe-by-default.
#   3. Config-isolation of git's code-execution hooks (see below) — needed even
#      with ZERO attacker CLI flags, because these fire from inherited git config
#      / repo .gitattributes.
#
# Requires: `git` on PATH.
#
# Usage: git-ro.sh <subcommand> [args...]     e.g.  git-ro.sh diff main...HEAD
#
# Anything not permitted is rejected with a clear message and a non-zero exit
# (never silently stripped or passed through).
#
set -euo pipefail

allowed_subcommands="diff status log merge-base rev-parse"

die() {
    printf 'git-ro.sh: %s\n' "$1" >&2
    exit 1
}

# git must be available — fail loudly rather than producing confusing errors.
command -v git >/dev/null 2>&1 || die "git not found on PATH"

# Need at least a subcommand.
[ "$#" -ge 1 ] || die "usage: git-ro.sh <subcommand> [args...] (allowed: ${allowed_subcommands})"

subcommand="$1"
shift

# Subcommand must be explicitly allowlisted — reject, do not pass through.
case " ${allowed_subcommands} " in
    *" ${subcommand} "*) ;;
    *) die "subcommand '${subcommand}' is not allowed (read-only allowlist: ${allowed_subcommands})" ;;
esac

# FINDING 1 fix — safe-flag ALLOWLIST. Walk every remaining argument. A token is
# accepted only if it is (a) a non-dash token (revision, range, or pathspec —
# harmless for read-only viewing), (b) the `--` end-of-options marker (after
# which git treats everything as pathspecs, so no later token can be an option),
# or (c) a flag that EXACTLY matches one of the known read-only display/filter
# flags below. Every other dash-prefixed token — including bundled short options
# like `-zO/etc/shadow`, `--no-index`, `--output`, `-O`, `-o` — falls through to
# the catch-all and is refused. Patterns that end in `[0-9]*` bound their
# argument to digits so they cannot smuggle a file path.
after_ddash=false
for arg in "$@"; do
    if [ "$after_ddash" = true ]; then
        continue   # everything past `--` is a pathspec; git will not parse it as a flag
    fi
    case "$arg" in
        --)
            after_ddash=true
            ;;

        # --- output / patch format (no file I/O) ---
        -p | -u | --patch | --no-patch | -s | \
        -U | --unified | -U[0-9]* | --unified=[0-9]* | \
        --raw | --stat | --stat=* | --numstat | --shortstat | --summary | \
        --name-only | --name-status | --compact-summary | \
        --oneline | --graph | --decorate | --decorate=* | --no-decorate | \
        --abbrev-commit | --no-abbrev-commit | --abbrev | --abbrev=* | \
        --pretty | --pretty=* | --format=* | \
        --word-diff | --word-diff=* | --function-context | -W | \
        --full-index | -R | --patch-with-stat)
            ;;

        # --- colour (display only) ---
        --color | --color=* | --no-color)
            ;;

        # --- rename/copy detection (booleans / numeric thresholds) ---
        -M | -M[0-9]* | -C | -C[0-9]* | \
        --find-renames | --find-renames=* | --find-copies | --find-copies=* | \
        --no-renames | --find-copies-harder)
            ;;

        # --- whitespace / noise filters ---
        -w | -b | --ignore-all-space | --ignore-space-change | \
        --ignore-space-at-eol | --ignore-blank-lines | --ignore-cr-at-eol)
            ;;

        # --- log selection / filtering (no file I/O) ---
        -z | -[0-9]* | -n | -n[0-9]* | --max-count=[0-9]* | --skip | --skip=[0-9]* | \
        --all | --branches | --branches=* | --tags | --tags=* | --remotes | --remotes=* | \
        --first-parent | --merges | --no-merges | --reverse | --no-walk | --no-walk=* | \
        --date=* | --since=* | --after=* | --until=* | --before=* | \
        --author=* | --committer=* | --grep=* | -i | -E | --regexp-ignore-case | \
        --follow | --no-patch)
            ;;

        # --- status / rev-parse display options (no file I/O) ---
        --short | --porcelain | --porcelain=* | --branch | --no-renames | \
        --verify | --quiet | -q | --abbrev-ref | --abbrev-ref=* | \
        --symbolic | --symbolic-full-name | --show-toplevel | \
        --is-inside-work-tree | --is-bare-repository | --show-prefix)
            ;;

        # Any other dash-prefixed token is unknown and refused by default.
        -*)
            die "flag '${arg}' is not on the read-only safe-flag allowlist and is refused"
            ;;

        # Non-dash token: revision, range, or pathspec — safe for read-only view.
        *)
            ;;
    esac
done

# FINDING 2 fix — neutralize git's config-driven code-execution hooks. These
# exec() arbitrary programs on `git diff`/`git log` with NO attacker CLI flags,
# purely from inherited git config or a repo-controlled .gitattributes (common
# with delta / difftastic setups). Only the wrapper controls the pre-subcommand
# position where these overrides are valid, so we always apply them:
#   --no-pager (top-level)      : unconditionally suppress the pager. This is
#                                 STRONGER than `-c core.pager=cat`: the per-command
#                                 keys `pager.diff` / `pager.log` / `pager.status`
#                                 take precedence over core.pager and would still
#                                 exec an attacker-configured pager, but --no-pager
#                                 overrides all of them. -c core.pager=cat is kept
#                                 below for defense-in-depth.
#   -c core.pager=cat          : core.pager is exec'd to page output; force `cat`.
#   -c diff.external=           : diff.external is exec'd as the diff program; empty it.
#   -c interactive.diffFilter=  : exec'd to filter diffs; empty it.
#   -c core.fsmonitor=          : core.fsmonitor is exec'd as a hook to refresh the
#                                 index on `status`/`diff`; empty it so a configured
#                                 fsmonitor program cannot run on a read-only call.
# These `-c key=value` global overrides are accepted before ANY subcommand, so
# they are safe to pass to all five allowed subcommands.
git_config_isolation=(-c core.pager=cat -c diff.external= -c interactive.diffFilter= -c core.fsmonitor=)

# `--no-ext-diff` (ignore diff.external) and `--no-textconv` (ignore textconv
# drivers selected via .gitattributes `diff=<driver>`) are diff-machinery flags:
# valid for `diff` and `log`, but NOT for status/merge-base/rev-parse (passing
# them there would break those subcommands). Apply per-subcommand accordingly.
#
# Safe: "$@" is passed as distinct words, never re-parsed by a shell (no eval).
case "$subcommand" in
    diff | log)
        exec git --no-pager "${git_config_isolation[@]}" "$subcommand" --no-ext-diff --no-textconv "$@"
        ;;
    *)
        exec git --no-pager "${git_config_isolation[@]}" "$subcommand" "$@"
        ;;
esac
