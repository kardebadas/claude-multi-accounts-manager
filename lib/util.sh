# shellcheck shell=bash
# lib/util.sh — the project's output primitives.
#
# Sourced, never executed: no shebang, not executable, and no
# `set -euo pipefail` — errexit set here would leak into every caller. Safe to
# source more than once: nothing is `readonly`, and the prefix below keeps a
# value the caller already set.
#
# STDOUT BELONGS TO CLAUDE. Every function here writes to stderr only. The
# finished tool `exec`s claude with a byte-empty stdout so that
# `claude-multi work -p "…" | jq` is never corrupted by our own narration.
# A function that returns DATA to its caller (consumed via `$( )`) writes that
# data to stdout and its diagnostics to stderr; this file defines no such
# function — log, warn, die and require_bash4 return no data at all.
#
# ── die vs. warn: the contract later phases must honour ──────────────────────
# `die` is for UNRECOVERABLE conditions only. It terminates the process, so
# every caller above it dies too, and no cleanup or partial rollback runs.
#
# A function that must let its caller CONTINUE never calls `die`. It calls
# `warn` and RETURNS NON-ZERO, leaving the decision to the caller. This is not
# a style preference: a helper that dies on a recoverable condition silently
# converts "one optional step was skipped" into "the whole command aborted
# half-done".
#
# `die` is also wrong inside a `$( )` getter: exit kills only the subshell, and
# the caller carries on with an empty string.

CLAUDE_MULTI_PROG="${CLAUDE_MULTI_PROG:-claude-multi}"

# log <words…> — narrate. stderr, returns 0.
log() {
  printf '%s: %s\n' "$CLAUDE_MULTI_PROG" "$*" >&2
  return 0
}

# warn <words…> — something is off but the caller may continue. stderr,
# returns 0 so it can sit anywhere in a `set -e` script. The *caller* is what
# returns non-zero after warning; see the contract above.
warn() {
  printf '%s: warning: %s\n' "$CLAUDE_MULTI_PROG" "$*" >&2
  return 0
}

# die <words…> — unrecoverable. stderr, then exit 1. Never returns.
die() {
  printf '%s: error: %s\n' "$CLAUDE_MULTI_PROG" "$*" >&2
  exit 1
}

# require_bash4 [major] — 0 if major (default this shell's) is >= 4, else a
# stderr diagnostic and return 1.
#
# The major version is a parameter because BASH_VERSINFO is readonly and cannot
# be faked, so the rejecting branch would otherwise be untestable.
#
# This function must RUN on the bash it rejects: a check written with
# bash-4-only syntax would make sourcing this file a syntax error on bash 3 and
# report nothing at all. Everything here is therefore bash-3 syntax — `case`
# for the numeric guard rather than `[[ =~ ]]`, and `[ -lt ]` rather than
# `(( ))`, which on a non-numeric value aborts a `set -u` caller with a raw
# "unbound variable" instead of a diagnostic.
require_bash4() {
  local major found
  if [ "$#" -gt 0 ]; then
    major="$1"
    found="$1"
  else
    major="${BASH_VERSINFO[0]:-0}"
    found="${BASH_VERSION:-unknown}"
  fi

  # Reject before comparing, and reject on EVERY malformed shape: a version
  # check that ACCEPTS on bad input is worse than no check at all. Empty (an
  # explicit "" must not be defaulted away to this shell's own major), any
  # non-digit (a variable NAME included — `(( ))` would dereference it and
  # accept), and four or more digits, which is past what `[ -lt ]` will parse:
  # an unparsable operand makes `[` print a raw "integer expression expected"
  # and leaves the `if` merely false, so the function would fall through and
  # accept. Refusing fails closed, and no real bash reports a four-digit major.
  case "$major" in
    '' | *[!0-9]* | ????*)
      printf '%s: error: bash 4 or newer is required (unreadable major version [%s])\n' \
        "$CLAUDE_MULTI_PROG" "$major" >&2
      return 1
      ;;
  esac

  if [ "$major" -lt 4 ]; then
    printf '%s: error: bash 4 or newer is required (found %s)\n' \
      "$CLAUDE_MULTI_PROG" "$found" >&2
    return 1
  fi
  return 0
}
