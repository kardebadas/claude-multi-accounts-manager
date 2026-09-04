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

# ── confirm: yes/no prompting that must survive having no terminal ───────────
# Two functions, split so the accept/reject table is testable without faking a
# terminal:
#   _confirm_reply <reply> <default>   pure parser, no I/O at all
#   confirm <prompt> [default]         renders the prompt, reads the answer
# Both return 0 for yes and 1 for no. Neither returns data, so neither writes
# to stdout: the prompt, the hint and every notice go to stderr, and stdout
# stays byte-empty so `claude-multi work -p "…" | jq` is never corrupted.
#
# ── what the answer is when nobody answers ───────────────────────────────────
# Three cases, and later phases depend on all three:
#
#   * No terminal on stdin (a pipe, a redirect, cron, a test): confirm takes
#     the caller's default WITHOUT READING A BYTE OF STDIN and says so on
#     stderr. Not reading is the whole point — that stdin may be claude's own
#     input, so a prompt that helped itself to a line would corrupt the process
#     we are about to exec, and piped data must never be able to answer a
#     question on the operator's behalf.
#   * EOF at the prompt (Ctrl-D on a real terminal): the same branch as an
#     empty line, i.e. the caller's default. EOF IS NOT CONSENT — it can only
#     ever produce "yes" for a caller that explicitly asked for a Y default.
#   * Default omitted, empty, or anything other than Y/y: N. Silence is never
#     consent, and neither is a default the caller got wrong; a bad default
#     fails closed.
#
# A TYPED answer may be y, Y, yes or YES; everything else — n, no, "yep", a
# stray space — is no. A yes/no gate that guesses is a gate that consents by
# accident, so there is no re-prompt loop: an unrecognised answer is simply no,
# and the caller can ask again if it wants to.
#
# The DEFAULT, by contrast, is Y/y and nothing else, because the hint the
# operator saw and the answer actually taken are decided by the same test —
# they cannot drift apart and show [Y/n] while assuming N.
#
# ── what this is not ─────────────────────────────────────────────────────────
# confirm is for ordinary yes/no questions ("launch claude in 'work' now to log
# in? [Y/n]"). It is NOT THE DELETION GATE. An irreversible removal must make
# the operator retype the account name — the typed-name confirmation on the
# delete path — because a single keystroke is far too cheap for an `rm -rf`,
# and because the non-TTY branch above deliberately answers with no human
# present. Never front an irreversible action with confirm alone.
_confirm_reply() {
  local reply default
  reply="${1-}"
  default="${2-}"

  if [ -z "$reply" ]; then
    case "$default" in
      [Yy]) return 0 ;;
      *) return 1 ;;
    esac
  fi

  case "$reply" in
    [Yy] | [Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

# confirm <prompt> [default]  — default is Y or N (N when omitted). 0 = yes.
#
# Every branch hands the verdict to _confirm_reply through an explicit
# if/else rather than `return $?`: under a caller's errexit, a bare
# `_confirm_reply …` that returns 1 would abort the caller before this function
# could turn it into its own return value.
confirm() {
  local prompt default hint reply
  prompt="${1-}"
  default="${2-}"
  hint="[y/N]"
  reply=""

  # Normalise first, so the notices below report what will actually happen.
  case "$default" in
    [Yy]) default="Y"; hint="[Y/n]" ;;
    *) default="N" ;;
  esac

  if [ ! -t 0 ]; then
    printf '%s: %s %s (no terminal; assuming %s)\n' \
      "$CLAUDE_MULTI_PROG" "$prompt" "$hint" "$default" >&2
    if _confirm_reply "" "$default"; then return 0; else return 1; fi
  fi

  printf '%s: %s %s ' "$CLAUDE_MULTI_PROG" "$prompt" "$hint" >&2
  if ! IFS= read -r reply; then
    # Close the prompt line the terminal left open, then say what happened:
    # a default taken in silence is indistinguishable from an answered
    # question.
    printf '\n' >&2
    warn "no answer (EOF); assuming $default"
    if _confirm_reply "" "$default"; then return 0; else return 1; fi
  fi

  if _confirm_reply "$reply" "$default"; then return 0; else return 1; fi
}
