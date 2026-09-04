#!/usr/bin/env bash
# tests/assert.sh — assertion helpers. Sourced by tests/test_*.sh.
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
assert_no_stdout() {
  local out=""
  out="$("$@" 2>/dev/null || true)"
  if [[ -z "$out" ]]; then
    return 0
  fi
  _assert_fail "assert_no_stdout: [$*] wrote to stdout: [$out]"
}
