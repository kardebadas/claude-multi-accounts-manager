# shellcheck shell=bash
# tests/test_fake_claude.sh — tests for the stub `claude`.
#
# The stub is the instrument Phase 6 measures `launch_account` with: it is the
# only witness to what environment and argv the real `exec claude` would have
# received. If it lies, every launch test lies with it — so its record format is
# pinned here, facet by facet.
#
# Invoked as `bash tests/test_fake_claude.sh` (by tests/run.sh, or by hand) with
# REPO_ROOT and TEST_TMP exported. Not executable and no shebang, matching the
# rest of the suite: nothing ever runs it as `./tests/test_fake_claude.sh`.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"

# ── standard wiring: a `claude` on PATH that is really the stub ──────────────
# claude-multi resolves `claude` through PATH, so pointing PATH at a directory
# holding a symlink named `claude` is enough to intercept a launch. These four
# lines are the wiring Phase 6 copies inline into each launch test.
mkdir -p "$TEST_TMP/bin"
ln -sf "$REPO_ROOT/tests/fake-claude" "$TEST_TMP/bin/claude"
export PATH="$TEST_TMP/bin:$PATH"
export FAKE_CLAUDE_LOG="$TEST_TMP/invocation"

# The stub must exist and be executable before a single test runs. `ln -sf`
# creates a dangling link without complaint when the target is missing, and
# `command -v` then walks straight past the dangling link to whatever real
# `claude` the developer has installed — so a missing or non-executable stub
# would silently launch the real binary instead of failing. Checked once, here,
# because that failure mode is invisible in the assertions themselves.
if [[ ! -f "$REPO_ROOT/tests/fake-claude" ]]; then
  printf '  FAIL: tests/fake-claude does not exist; refusing to run (PATH would resolve the real claude)\n' >&2
  exit 1
fi
if [[ ! -x "$REPO_ROOT/tests/fake-claude" ]]; then
  printf '  FAIL: tests/fake-claude is not executable; refusing to run (PATH would resolve the real claude)\n' >&2
  exit 1
fi

# read_argv <file> — load a NUL-delimited argv record into the global ARGV.
#
# `read -d ''` splits on NUL, so an argument containing spaces, tabs, globs or
# newlines round-trips byte for byte. A zero-length file yields an empty array,
# which is how "no arguments" is distinguished from "one empty argument" (one
# NUL byte, one element).
declare -a ARGV=()
read_argv() {
  ARGV=()
  local a
  while IFS= read -r -d '' a; do ARGV+=("$a"); done <"$1"
}

# ── the stub must be reachable through PATH, not by absolute path ────────────
test_resolved_through_path() {
  assert_eq "$TEST_TMP/bin/claude" "$(command -v claude)"
  [[ -x "$REPO_ROOT/tests/fake-claude" ]] \
    || assert_eq "executable" "not executable" "tests/fake-claude must be +x"
}

# ── the headline record: argv plus the environment that matters ──────────────
test_records_argv_and_env() {
  CLAUDE_CONFIG_DIR="$TEST_TMP/acct" \
  CLAUDE_CODE_PLUGIN_CACHE_DIR="$TEST_TMP/shared/plugin-cache" \
    claude -p "hello world" --flag

  local log
  log="$(cat "$TEST_TMP/invocation")"
  assert_contains "$log" "ARGC=3"
  assert_contains "$log" "ARG=-p"
  assert_contains "$log" "ARG=hello world"
  assert_contains "$log" "ARG=--flag"
  assert_contains "$log" "CLAUDE_CONFIG_DIR=$TEST_TMP/acct"
  assert_contains "$log" "CLAUDE_CODE_PLUGIN_CACHE_DIR=$TEST_TMP/shared/plugin-cache"
  assert_contains "$log" "HOME=$HOME"
  assert_contains "$log" "PWD=$PWD"

  # The NUL record is the authoritative one: exact count, exact bytes.
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "3" "${#ARGV[@]}"
  assert_eq "-p" "${ARGV[0]}"
  assert_eq "hello world" "${ARGV[1]}"
  assert_eq "--flag" "${ARGV[2]}"
}

# ── awkward arguments must survive verbatim ─────────────────────────────────
# One test per shape, because each fails for a different reason if the stub
# re-splits, re-globs or joins its arguments.
test_glob_arg_verbatim() {
  claude '*.md'
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "1" "${#ARGV[@]}"
  assert_eq "*.md" "${ARGV[0]}"
  # A stub that expanded the glob would record the directory listing instead;
  # the cwd holds a matching file so that mistake cannot pass unnoticed.
  : >"$TEST_TMP/decoy.md"
  claude '*.md'
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "1" "${#ARGV[@]}"
  assert_eq "*.md" "${ARGV[0]}"
}

test_empty_string_arg() {
  claude -p "" --flag
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "3" "${#ARGV[@]}"
  assert_eq "-p" "${ARGV[0]}"
  assert_eq "" "${ARGV[1]}" "an empty-string argument must be preserved"
  assert_eq "--flag" "${ARGV[2]}"
  assert_contains "$(cat "$TEST_TMP/invocation")" "ARGC=3"
}

test_newline_arg() {
  claude "$(printf 'line one\nline two')"
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "1" "${#ARGV[@]}" "a newline must not split one argument into two"
  assert_eq "$(printf 'line one\nline two')" "${ARGV[0]}"
}

test_leading_dash_args() {
  claude -- --flag=value -x -
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "4" "${#ARGV[@]}"
  assert_eq "--" "${ARGV[0]}" "a bare -- must not be eaten as an option"
  assert_eq "--flag=value" "${ARGV[1]}"
  assert_eq "-x" "${ARGV[2]}"
  assert_eq "-" "${ARGV[3]}"
}

test_quotes_and_whitespace_args() {
  claude "say \"hi\"" $'tab\there' '  padded  '
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "3" "${#ARGV[@]}"
  assert_eq 'say "hi"' "${ARGV[0]}"
  assert_eq "$(printf 'tab\there')" "${ARGV[1]}"
  assert_eq "  padded  " "${ARGV[2]}" "leading and trailing spaces must survive"
}

# ── zero arguments is legal and must not trip set -u ────────────────────────
test_zero_args() {
  claude
  assert_contains "$(cat "$TEST_TMP/invocation")" "ARGC=0"
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "0" "${#ARGV[@]}"
  assert_eq "0" "$(wc -c <"$TEST_TMP/invocation.argv" | tr -d '[:space:]')" \
    "no arguments must leave a zero-byte argv record"
}

# ── every record is fresh: no residue from the previous invocation ──────────
test_record_is_truncated_between_runs() {
  claude -p "first call" --flag
  claude second
  local log
  log="$(cat "$TEST_TMP/invocation")"
  assert_contains "$log" "ARGC=1"
  assert_contains "$log" "ARG=second"
  assert_eq "" "$(grep -F -- 'first call' "$TEST_TMP/invocation" || true)" \
    "the log must be truncated, not appended to"
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "1" "${#ARGV[@]}" "the argv record must be truncated, not appended to"
  assert_eq "second" "${ARGV[0]}"
  # And back down to zero arguments, the case an append would hide entirely.
  claude
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "0" "${#ARGV[@]}" "a stale argv record must not survive a zero-arg call"
}

# ── unset variables record as empty, never as an error ──────────────────────
test_unset_env_records_empty() {
  env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_PLUGIN_CACHE_DIR \
      FAKE_CLAUDE_LOG="$TEST_TMP/invocation" PATH="$PATH" HOME="$HOME" claude
  local log
  log="$(cat "$TEST_TMP/invocation")"
  assert_contains "$log" "CLAUDE_CONFIG_DIR="
  assert_contains "$log" "CLAUDE_CODE_PLUGIN_CACHE_DIR="
  assert_eq "" "$(grep -E '^CLAUDE_CONFIG_DIR=.+$' "$TEST_TMP/invocation" || true)" \
    "an unset CLAUDE_CONFIG_DIR must record as empty"
}

# ── PWD is the caller's cwd, recorded per invocation ────────────────────────
test_records_caller_cwd() {
  mkdir -p "$TEST_TMP/elsewhere"
  ( cd "$TEST_TMP/elsewhere" && claude )
  assert_contains "$(cat "$TEST_TMP/invocation")" "PWD=$TEST_TMP/elsewhere"
}

# ── the log path is configurable, and its directory is created ──────────────
test_log_path_directory_created() {
  local deep="$TEST_TMP/deep/deeper/record"
  FAKE_CLAUDE_LOG="$deep" claude -p x
  assert_contains "$(cat "$deep")" "ARG=-p"
  read_argv "$deep.argv"
  assert_eq "2" "${#ARGV[@]}"
}

test_default_log_location() {
  rm -f -- "$TEST_TMP/fake-claude.log" "$TEST_TMP/fake-claude.log.argv"
  env -u FAKE_CLAUDE_LOG PATH="$PATH" HOME="$HOME" TEST_TMP="$TEST_TMP" claude default
  assert_contains "$(cat "$TEST_TMP/fake-claude.log")" "ARG=default"
  read_argv "$TEST_TMP/fake-claude.log.argv"
  assert_eq "1" "${#ARGV[@]}"
  assert_eq "default" "${ARGV[0]}"
}

# ── silence: stdout belongs to claude-multi's caller ────────────────────────
# Phase 6 asserts the launch path leaves stdout byte-empty. That measures
# claude-multi only if the stub itself contributes zero bytes.
test_stdout_is_byte_empty() {
  assert_no_stdout claude -p x
  assert_stdout_empty_bytes claude -p x
  assert_stdout_empty_bytes claude
  assert_stdout_empty_bytes env FAKE_CLAUDE_EXIT=5 FAKE_CLAUDE_LOG="$TEST_TMP/invocation" \
    PATH="$PATH" HOME="$HOME" claude
}

test_stderr_is_silent_on_success() {
  local err
  err="$(claude -p x 2>&1 >/dev/null)"
  assert_eq "" "$err" "the stub must not narrate its own success on stderr"
}

# ── exit-code fidelity: Phase 6 must be able to prove it is propagated ──────
test_exit_status_injectable() {
  local code=0
  set +e
  claude -p x
  code=$?
  set -e
  assert_eq "0" "$code" "the default exit status is 0"

  set +e
  FAKE_CLAUDE_EXIT=3 claude -p x
  code=$?
  set -e
  assert_eq "3" "$code"

  set +e
  FAKE_CLAUDE_EXIT=42 claude
  code=$?
  set -e
  assert_eq "42" "$code"

  set +e
  FAKE_CLAUDE_EXIT=0 claude
  code=$?
  set -e
  assert_eq "0" "$code" "an explicit 0 must still succeed"

  assert_fails env FAKE_CLAUDE_EXIT=3 FAKE_CLAUDE_LOG="$TEST_TMP/invocation" \
    PATH="$PATH" HOME="$HOME" claude
}

# A non-zero exit must not cost us the record: Phase 6 needs to inspect what a
# failing launch was handed.
test_record_written_even_when_exiting_nonzero() {
  set +e
  FAKE_CLAUDE_EXIT=7 claude -p "failing call"
  local code=$?
  set -e
  assert_eq "7" "$code"
  assert_contains "$(cat "$TEST_TMP/invocation")" "ARG=failing call"
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "2" "${#ARGV[@]}"
}

# A junk exit value must be a sentence on stderr and a non-zero status, not a
# silent success.
test_junk_exit_value_fails_loudly() {
  local err code
  set +e
  err="$(FAKE_CLAUDE_EXIT=notanumber claude 2>&1 >/dev/null)"
  code=$?
  set -e
  assert_contains "$err" "FAKE_CLAUDE_EXIT"
  if [[ "$code" == "0" ]]; then
    assert_eq "non-zero" "0" "a junk FAKE_CLAUDE_EXIT must not exit 0"
  fi
  assert_stdout_empty_bytes env FAKE_CLAUDE_EXIT=notanumber \
    FAKE_CLAUDE_LOG="$TEST_TMP/invocation" PATH="$PATH" HOME="$HOME" claude

  # Out of range too: `exit 256` silently wraps to 0, which would hand Phase 6
  # a passing status for a failing launch.
  set +e
  err="$(FAKE_CLAUDE_EXIT=256 claude 2>&1 >/dev/null)"
  code=$?
  set -e
  assert_contains "$err" "FAKE_CLAUDE_EXIT"
  if [[ "$code" == "0" ]]; then
    assert_eq "non-zero" "0" "FAKE_CLAUDE_EXIT=256 must not wrap to exit 0"
  fi
  # 255 is the last legal value and must still be honoured verbatim.
  set +e
  FAKE_CLAUDE_EXIT=255 claude
  code=$?
  set -e
  assert_eq "255" "$code"
}

# ── dispatch ────────────────────────────────────────────────────────────────
# Every test_* function defined above is discovered and run, each in its own
# subshell with errexit re-armed. `set +e` around the call is what makes that
# possible: bash suppresses errexit inside a subshell used as a condition, so
# the status is collected explicitly instead. A file that defined tests and
# never ran them would report success while testing nothing, and zero
# discovered tests is itself a failure.
declare -a _tests=()
while IFS= read -r _fn; do _tests+=("$_fn"); done < <(
  declare -F | awk '$3 ~ /^test_/ { print $3 }' | sort
)
if ((${#_tests[@]} == 0)); then
  printf '  FAIL: no test_* functions discovered in %s\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi
_failed=0
for _fn in "${_tests[@]}"; do
  set +e
  ( set -euo pipefail; "$_fn" )
  _status=$?
  set -e
  if ((_status != 0)); then
    printf '  FAIL: %s (exit %d)\n' "$_fn" "$_status" >&2
    _failed=$((_failed + 1))
  fi
done
if ((_failed > 0)); then
  printf '  %d of %d test functions failed\n' "$_failed" "${#_tests[@]}" >&2
  exit 1
fi
