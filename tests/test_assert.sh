# shellcheck shell=bash
# tests/test_assert.sh — tests for the assertion helpers themselves. If these
# are wrong, every other test in the suite is meaningless.
#
# Invoked as `bash tests/test_assert.sh` (by tests/run.sh, or by hand) with
# REPO_ROOT exported. It is not executable and carries no shebang: nothing ever
# runs it as `./tests/test_assert.sh`.
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
# The symlink fixtures live in a scratch directory of our own, created fresh on
# every run. Creating them in $PWD is not idempotent: on a second run
# `ln -s real link_to_dir` resolves *through* the existing symlink and silently
# creates real/real before the run dies on `ln: relative_link: File exists`.
# Owning the directory makes run N behave exactly like run 1, whatever the
# caller's $PWD already holds.
fixtures="$(mktemp -d "${TMPDIR:-/tmp}/test_assert.XXXXXX")"
_cleanup_fixtures() {
  [[ -n "${fixtures:-}" && -d "${fixtures:-}" ]] && rm -rf -- "$fixtures"
  return 0
}
trap _cleanup_fixtures EXIT
cd "$fixtures"

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
# Pinned, deliberate limitation: assert_no_stdout compares a command
# substitution, which strips trailing newlines, so newline-only stdout reads as
# empty. This is the contract, not a bug — it stays the content-level check.
# assert_stdout_empty_bytes below is the byte-exact one.
assert_no_stdout bash -c 'printf "\n"'

# ── assert_stdout_empty_bytes ────────────────────────────────────────────────
# The project's binding guarantee: the launch path must leave stdout
# byte-empty so `claude-multi work -p "…" | jq` is never corrupted. A bare
# `echo` on that path emits exactly one byte, which only a byte count sees.
assert_stdout_empty_bytes true
assert_stdout_empty_bytes bash -c 'printf "only stderr\n" >&2'
assert_fails assert_stdout_empty_bytes bash -c 'printf "leak\n"'
assert_fails assert_stdout_empty_bytes bash -c 'printf "\n"'
assert_fails assert_stdout_empty_bytes bash -c 'printf "\n\n\n"'
assert_fails assert_stdout_empty_bytes bash -c 'printf "   "'
assert_fails assert_stdout_empty_bytes bash -c 'printf "\t"'
assert_fails assert_stdout_empty_bytes bash -c 'printf "\000\000"'
# Exit status of the command is ignored, exactly as in assert_no_stdout: the
# contract is about stdout. Compose with assert_fails to check both.
assert_stdout_empty_bytes false
assert_fails assert_stdout_empty_bytes bash -c 'printf leak; exit 3'
# The failure report names the byte count.
err="$(assert_stdout_empty_bytes bash -c 'printf "abc"' 2>&1 >/dev/null || true)"
assert_contains "$err" "FAIL"
assert_contains "$err" "3"
out="$(assert_stdout_empty_bytes bash -c 'printf "abc"' 2>/dev/null || true)"
assert_eq "" "$out" "assert_stdout_empty_bytes must not print to stdout"
# A NUL-only leak must be reported without bash emitting its own
# "ignored null byte in input" warning under assert.sh's name — a helper that
# names its own source line in every failure report is noise.
err="$(assert_stdout_empty_bytes bash -c 'printf "\000\000"' 2>&1 >/dev/null || true)"
assert_contains "$err" "FAIL"
if [[ "$err" == *"warning"* || "$err" == *"null byte"* || "$err" == *"assert.sh: line"* ]]; then
  printf '  FAIL: assert_stdout_empty_bytes leaked a bash warning: [%s]\n' "$err" >&2
  exit 1
fi

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
