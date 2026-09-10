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
# Four cases, and later phases depend on all four:
#
#   * No terminal for the exchange — stdin is not a tty, or stderr is not one:
#     confirm takes the caller's default WITHOUT READING A BYTE OF STDIN and
#     says so on stderr. BOTH CHANNELS MUST BE USABLE, because the answer is
#     read from stdin and the question is shown on stderr (stdout belongs to
#     claude); with either one redirected there is no exchange to have, and
#     `claude-multi … 2>log` would otherwise print an invisible prompt into the
#     log and then sit there looking hung. Not reading is the other half of the
#     point: that stdin may be claude's own input, so a prompt that helped
#     itself to a line would corrupt the process we are about to exec, and
#     piped data must never be able to answer a question on the operator's
#     behalf.
#   * EOF at the prompt (Ctrl-D on a real terminal) with nothing typed: the
#     same branch as an empty line, i.e. the caller's default. EOF IS NOT
#     CONSENT — it can only ever produce "yes" for a caller that explicitly
#     asked for a Y default. EOF ON A PARTIALLY TYPED LINE HONOURS WHAT WAS
#     TYPED, though: `read` fails at EOF but leaves the partial line behind,
#     and an operator who typed "n" before pressing Ctrl-D has refused — a
#     default of Y must never overrule them.
#   * A blank-looking answer: empty, or NOTHING BUT WHITESPACE IS NO ANSWER, so
#     the caller's default applies. The operator has just read the hint, and a
#     stray space before Return must not hand them the opposite of what it
#     advertised. (A space stuck to an answer, "y ", is a different thing: a
#     typo in an answer, and still no.)
#   * Default omitted, or anything other than Y/y/N/n: N, plus a `warn` naming
#     the value whenever one was actually supplied. Silence is never consent,
#     and neither is a default the caller got wrong; a bad default fails
#     closed, and says so, because the verdict channel is binary and code
#     could not otherwise tell "the operator said no" from "you passed me
#     junk". A warning and not a `die`: see the contract above — a caller must
#     be able to carry on past a bad prompt argument.
#
# A TYPED answer may be y, Y, yes or YES; everything else — n, no, "yep" — is
# no. A yes/no gate that guesses is a gate that consents by accident, so there
# is no re-prompt loop: an unrecognised answer is simply no, and the caller can
# ask again if it wants to.
#
# The DEFAULT, by contrast, means "yes" for Y/y and nothing else, because the
# hint the operator saw and the answer actually taken are decided by the same
# test — they cannot drift apart and show [Y/n] while assuming N.
#
# ── what this is not ─────────────────────────────────────────────────────────
# confirm is for ordinary yes/no questions ("launch claude in 'work' now to log
# in? [Y/n]"). It is NOT THE DELETION GATE. An irreversible removal must make
# the operator retype the account name — the typed-name confirmation on the
# delete path — because a single keystroke is far too cheap for an `rm -rf`,
# and because the no-terminal branch above deliberately answers with no human
# present. Never front an irreversible action with confirm alone.
_confirm_reply() {
  local reply default
  reply="${1-}"
  default="${2-}"

  # Nobody answered: empty, or a line carrying no non-whitespace character at
  # all. Both take the caller's default. `*[![:space:]]*` is bash-3 glob
  # syntax, like the rest of this file, and it deliberately still rejects "y "
  # — a space attached to an answer is a typo in an answer, not a blank line.
  case "$reply" in
    *[![:space:]]*) ;;
    *)
      case "$default" in
        [Yy]) return 0 ;;
        *) return 1 ;;
      esac
      ;;
  esac

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
    [Nn]) default="N" ;;
    *)
      # Only a default that was actually SUPPLIED is reported: omitting it is
      # the documented way to ask for N, and warning about that would put a
      # spurious line in front of every well-behaved caller.
      if [ "$#" -ge 2 ]; then
        warn "confirm: unrecognised default [$default]; using N"
      fi
      default="N"
      ;;
  esac

  # Both channels, or no exchange: stdin to read the answer from and stderr to
  # show the question on. Checked before any read, so this branch consumes
  # nothing.
  if [ ! -t 0 ] || [ ! -t 2 ]; then
    log "$prompt $hint (no terminal; assuming $default)"
    if _confirm_reply "" "$default"; then return 0; else return 1; fi
  fi

  printf '%s: %s %s ' "$CLAUDE_MULTI_PROG" "$prompt" "$hint" >&2
  if ! IFS= read -r reply; then
    # Close the prompt line the terminal left open, then decide what the failed
    # read actually means.
    printf '\n' >&2
    case "$reply" in
      *[![:space:]]*)
        # The line was typed but never terminated — Ctrl-D on a partial line.
        # `read` reports failure and still hands back what was typed, and that
        # answer wins: discarding it would turn a typed refusal into whatever
        # the caller happened to pass as its default.
        if _confirm_reply "$reply" "$default"; then return 0; else return 1; fi
        ;;
    esac
    # Nothing was typed. A default taken in silence is indistinguishable from
    # an answered question, so say which one was taken and why.
    warn "no answer (EOF); assuming $default"
    if _confirm_reply "" "$default"; then return 0; else return 1; fi
  fi

  if _confirm_reply "$reply" "$default"; then return 0; else return 1; fi
}

# Result of the last validate_name call. Empty means "no valid name".
CANONICAL_NAME=""

# validate_name <raw>
# 0 and CANONICAL_NAME set, or 1 with a stderr message and CANONICAL_NAME="".
#
# The name is returned through a global rather than printed, because an
# uncaptured $(validate_name …) would put the name on claude's stdout.
#
# Requires is_reserved_name from lib/config.sh.
validate_name() {
  local raw="${1-}" name="" upper lower upper_char lower_char i
  CANONICAL_NAME=""

  if [[ -z "$raw" ]]; then
    warn "an account name is required"
    return 1
  fi

  # Checked before lowercasing so the message names the real problem.
  if [[ "$raw" == .* ]]; then
    warn "account names may not start with '.': $raw"
    return 1
  fi

  name="$raw"
  if [[ "$name" =~ [A-Z] ]]; then
    # Keep this library parseable by bash 3 so require_bash4 can report its
    # own useful error instead of the source operation failing first.
    upper="ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    lower="abcdefghijklmnopqrstuvwxyz"
    for ((i = 0; i < 26; i++)); do
      upper_char="${upper:$i:1}"
      lower_char="${lower:$i:1}"
      name="${name//$upper_char/$lower_char}"
    done
    warn "account names are lowercase; using '$name'"
  fi

  if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; then
    warn "invalid account name '$raw': must match ^[a-z0-9][a-z0-9-]{0,31}\$"
    return 1
  fi

  if is_reserved_name "$name"; then
    warn "'$name' is a reserved name and cannot be an account"
    return 1
  fi

  CANONICAL_NAME="$name"
  return 0
}
