#!/usr/bin/env bash
# Tests for the assertion helpers themselves. If these are wrong, every other
# test in the suite is meaningless.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"

# ── assert_eq ────────────────────────────────────────────────────────────────
assert_eq "a" "a" "identical strings"
assert_eq "" "" "two empty strings"
assert_eq "with spaces" "with spaces"
assert_fails assert_eq "a" "b"
assert_fails assert_eq "a" ""

# ── assert_contains ──────────────────────────────────────────────────────────
assert_contains "hello world" "lo wo"
assert_contains "hello" "hello"
assert_contains "a*b" "*"
assert_fails assert_contains "hello" "xyz"

# ── assert_link ──────────────────────────────────────────────────────────────
mkdir -p real
ln -s real link_to_dir
ln -s ../shared/CLAUDE.md relative_link
: > plain_file
assert_link "link_to_dir" "real"
assert_link "relative_link" "../shared/CLAUDE.md"
assert_fails assert_link "link_to_dir" "other"
assert_fails assert_link "plain_file" "real"
assert_fails assert_link "does_not_exist" "real"
# A dangling link is still a link: assert_link must not require the target to
# exist, because Phase 2 needs to detect a dangling shared/skills.
ln -s /nonexistent/target dangling
assert_link "dangling" "/nonexistent/target"

# ── assert_no_stdout ─────────────────────────────────────────────────────────
assert_no_stdout true
assert_no_stdout bash -c 'printf "only stderr\n" >&2'
assert_fails assert_no_stdout bash -c 'printf "leak\n"'

# ── assert_fails must itself be honest ───────────────────────────────────────
if assert_fails true 2>/dev/null; then
  printf '  FAIL: assert_fails accepted a succeeding command\n' >&2
  exit 1
fi

# ── failure messages go to stderr, never stdout ──────────────────────────────
err="$(assert_eq "a" "b" "the message" 2>&1 >/dev/null || true)"
assert_contains "$err" "FAIL"
assert_contains "$err" "the message"
assert_contains "$err" "[a]"
assert_contains "$err" "[b]"
out="$(assert_eq "a" "b" 2>/dev/null || true)"
assert_eq "" "$out" "assertion failures must not print to stdout"
