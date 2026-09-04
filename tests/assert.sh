# shellcheck shell=bash
# tests/assert.sh — assertion helpers. Sourced by tests/test_*.sh.
#
# Sourced, never executed: no shebang, and the file is not executable. It also
# deliberately omits `set -euo pipefail`, which would leak into the caller.
#
# Contract: an assertion returns 0 on success, and on failure prints one
# "  FAIL: …" line to STDERR and returns 1. Test files run under
# `set -euo pipefail`, so a bare failing assertion aborts the test file and
# tests/run.sh reports it. Nothing here writes to stdout.

_assert_fail() {
  printf '  FAIL: %s\n' "$1" >&2
  return 1
}

# assert_eq <expected> <actual> [message]
assert_eq() {
  local expected="${1-}" actual="${2-}" msg="${3:-assert_eq}"
  if [[ "$expected" == "$actual" ]]; then
    return 0
  fi
  _assert_fail "$msg: expected [$expected] got [$actual]"
}

# assert_contains <haystack> <needle> [message]
assert_contains() {
  local haystack="${1-}" needle="${2-}" msg="${3:-assert_contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    return 0
  fi
  _assert_fail "$msg: [$needle] not found in [$haystack]"
}

# assert_link <path> <expected-target>
# The target need not exist: a dangling link is still a link, and Phase 2 must
# be able to tell "points at the right place" from "resolves".
assert_link() {
  local path="${1-}" want="${2-}" got=""
  if [[ ! -L "$path" ]]; then
    _assert_fail "assert_link: [$path] is not a symlink"
    return 1
  fi
  got="$(readlink -- "$path")"
  if [[ "$got" == "$want" ]]; then
    return 0
  fi
  _assert_fail "assert_link: [$path] -> [$got], expected [$want]"
}

# assert_fails <command> [args...]   — expects a non-zero exit
assert_fails() {
  if "$@" >/dev/null 2>&1; then
    _assert_fail "assert_fails: [$*] unexpectedly succeeded"
    return 1
  fi
  return 0
}

# assert_no_stdout <command> [args...]
# The whole point of the project: stdout belongs to claude.
#
# Content-level check: it captures stdout and reports what leaked, which makes
# it the right tool for "did this print something it should not have". Because
# it uses a command substitution it cannot see stdout that is *only* trailing
# newlines or *only* NUL bytes — for the byte-exact guarantee, use
# assert_stdout_empty_bytes below. Both are kept on purpose.
assert_no_stdout() {
  local out=""
  out="$("$@" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    return 0
  fi
  _assert_fail "assert_no_stdout: [$*] wrote to stdout: [$out]"
}

# assert_stdout_empty_bytes <command> [args...]
# Byte-exact stdout emptiness: 0 if the command wrote *zero bytes* to stdout.
#
# This is the assertion for the project's binding guarantee — the launch path
# must leave stdout byte-empty so `claude-multi work -p "…" | jq` is never
# corrupted. A bare `echo` on that path emits exactly one byte, and a command
# substitution cannot express the difference: it strips trailing newlines, and
# drops NUL bytes while making bash print "warning: command substitution:
# ignored null byte in input" under this file's own name. Counting bytes out of
# a pipe avoids both: `wc` reports every byte, and only its digits cross the
# substitution boundary.
#
# stderr is discarded and the command's exit status is deliberately ignored,
# matching assert_no_stdout — the contract is about stdout alone. Compose with
# assert_fails to check the status too.
assert_stdout_empty_bytes() {
  local bytes=""
  bytes="$( { "$@" || true; } 2>/dev/null | wc -c )"
  bytes="${bytes//[[:space:]]/}"
  if [[ "$bytes" == "0" ]]; then
    return 0
  fi
  _assert_fail "assert_stdout_empty_bytes: [$*] wrote $bytes byte(s) to stdout, expected 0"
}
