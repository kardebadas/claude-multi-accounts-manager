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

# ── PRECONDITION: PATH must resolve `claude` to *this* stub ─────────────────
# A precondition, not a test among the tests: it runs below, before a single
# test function is dispatched, and aborts the whole file on failure. It has to
# be, because dispatch is alphabetical — a resolution check written as a test
# runs somewhere in the middle, long after the earlier tests have already
# invoked whatever `claude` PATH really points at.
#
# Three ways the wiring goes wrong, all ending with the developer's real
# `claude` being launched:
#   * the stub is missing — `ln -sf` makes a dangling link without complaint
#     and `command -v` walks straight past it;
#   * the stub is not executable — same outcome;
#   * PATH was appended to instead of prepended (`"$PATH:$TEST_TMP/bin"`), so
#     another `claude` earlier on PATH wins every invocation. The stub is
#     present and +x here, so an existence check passes happily while every
#     test hits the real binary.
# The third is a one-character typo away in wiring Phase 6 copies into each
# launch file, and it is the one an existence check cannot see.

# canonical_path <path> — absolute, fully symlink-resolved. Non-zero and silent
# if the path does not resolve, a dangling symlink included.
canonical_path() {
  local p="${1-}" dir base
  [[ -n "$p" && -e "$p" ]] || return 1
  if p="$(readlink -f -- "$1" 2>/dev/null)" && [[ -n "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  # No usable `readlink -f`: resolve the directory instead and keep the leaf.
  dir="$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename -- "$1")"
  printf '%s/%s' "$dir" "$base"
}

# require_fake_claude_wiring <stub> — 0 if PATH resolves `claude` to <stub>.
# On failure: one "  FAIL: …" line on stderr, return 1, nothing on stdout.
# PATH is read from the environment, so a test can call this under a doctored
# PATH in a subshell instead of re-running this file.
require_fake_claude_wiring() {
  local stub="${1-}" on_path="" want="" got=""
  # bash remembers where it last found a command; a stale hash would let this
  # check pass while the invocations that follow go somewhere else.
  hash -r 2>/dev/null || true
  if [[ ! -f "$stub" ]]; then
    printf '  FAIL: %s does not exist; refusing to run (PATH would resolve the real claude)\n' \
      "$stub" >&2
    return 1
  fi
  if [[ ! -x "$stub" ]]; then
    printf '  FAIL: %s is not executable; refusing to run (PATH would resolve the real claude)\n' \
      "$stub" >&2
    return 1
  fi
  on_path="$(command -v claude 2>/dev/null || true)"
  if [[ -z "$on_path" ]]; then
    printf '  FAIL: PATH resolves no claude at all; refusing to run (the stub is not on PATH)\n' >&2
    return 1
  fi
  if ! want="$(canonical_path "$stub")" || [[ -z "$want" ]]; then
    printf '  FAIL: cannot resolve the stub [%s]; refusing to run\n' "$stub" >&2
    return 1
  fi
  if ! got="$(canonical_path "$on_path")" || [[ -z "$got" ]]; then
    printf '  FAIL: PATH resolves claude to [%s], which does not resolve; refusing to run\n' \
      "$on_path" >&2
    return 1
  fi
  # Resolved target against resolved target — never two strings that merely
  # look alike.
  if [[ "$want" != "$got" ]]; then
    printf '  FAIL: PATH does not resolve claude to the stub; refusing to run (want [%s], got [%s] via [%s])\n' \
      "$want" "$got" "$on_path" >&2
    return 1
  fi
  return 0
}

require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" || exit 1

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

# read_env_record <file> — load a NUL-delimited `NAME=value` record into the
# globals ENVREC (name -> value) and ENVREC_ENTRIES (the raw entries, in order).
# Same reasoning as read_argv: NUL is the one byte neither a variable name nor
# its value can contain, so a value holding newlines or its own `=` signs cannot
# invent an extra entry. The name is everything up to the FIRST `=`; the value
# is the rest, however many `=` it contains.
#
# Both globals, because the map alone cannot see a structural fault: a record
# that was appended to rather than truncated repeats the same four names, and a
# map just overwrites the four keys and looks perfectly healthy. ENVREC_ENTRIES
# counts what is actually in the file, so "four distinct names" and "four
# entries" are separate, separately-assertable claims.
declare -A ENVREC=()
declare -a ENVREC_ENTRIES=()
read_env_record() {
  ENVREC=()
  ENVREC_ENTRIES=()
  local e
  while IFS= read -r -d '' e; do
    ENVREC_ENTRIES+=("$e")
    ENVREC["${e%%=*}"]="${e#*=}"
  done <"$1"
}

# ── the stub must be reachable through PATH, not by absolute path ────────────
test_resolved_through_path() {
  # Identity, not string shape: `command -v` must land on the very file this
  # suite measures, however the symlink and TMPDIR happen to be spelled.
  local want got
  want="$(canonical_path "$REPO_ROOT/tests/fake-claude")"
  got="$(canonical_path "$(command -v claude)")"
  assert_contains "$want" "/" "canonical_path must yield an absolute path, not nothing"
  assert_eq "$want" "$got"
  [[ -x "$REPO_ROOT/tests/fake-claude" ]] \
    || assert_eq "executable" "not executable" "tests/fake-claude must be +x"
}

# ── the wiring precondition itself ──────────────────────────────────────────
# The precondition runs once, at the top of this file, before a single test.
# These tests exercise its logic directly — under a doctored PATH in a subshell
# — rather than by re-running this file, which would recurse.
test_wiring_precondition_accepts_real_wiring() {
  local err status=0
  set +e
  err="$( require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" 2>&1 >/dev/null )"
  status=$?
  set -e
  assert_eq "0" "$status" "the suite's own wiring must satisfy the precondition"
  assert_eq "" "$err" "a satisfied precondition says nothing"
}

test_wiring_precondition_accepts_any_path_resolving_to_the_stub() {
  # A differently-named symlink to the same file is still the stub, so the
  # check must compare resolved targets, not literal path strings.
  local alt="$TEST_TMP/altbin"
  mkdir -p "$alt"
  ln -sf "$REPO_ROOT/tests/fake-claude" "$alt/claude"
  local status=0
  set +e
  ( export PATH="$alt:$PATH"; require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" ) 2>/dev/null
  status=$?
  set -e
  assert_eq "0" "$status" "any PATH entry resolving to the stub must be accepted"
}

test_wiring_precondition_rejects_missing_stub() {
  # `ln -sf` to a missing target makes a dangling link without complaint, and
  # `command -v` then walks straight past it to the developer's real claude.
  local err status=0
  set +e
  err="$( require_fake_claude_wiring "$TEST_TMP/no-such-stub" 2>&1 >/dev/null )"
  status=$?
  set -e
  assert_eq "1" "$status"
  assert_contains "$err" "does not exist"
  assert_contains "$err" "refusing to run"
}

test_wiring_precondition_rejects_non_executable_stub() {
  local s="$TEST_TMP/notexec-stub"
  cp -- "$REPO_ROOT/tests/fake-claude" "$s"
  chmod -x "$s"
  local err status=0
  set +e
  err="$( require_fake_claude_wiring "$s" 2>&1 >/dev/null )"
  status=$?
  set -e
  assert_eq "1" "$status"
  assert_contains "$err" "is not executable"
}

test_wiring_precondition_rejects_no_claude_on_path() {
  mkdir -p "$TEST_TMP/empty-bin"
  local err status=0
  set +e
  err="$( export PATH="$TEST_TMP/empty-bin"; \
          require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" 2>&1 >/dev/null )"
  status=$?
  set -e
  assert_eq "1" "$status"
  assert_contains "$err" "resolves no claude at all"
}

test_wiring_precondition_rejects_path_append_typo() {
  # The one-character typo the existence check misses:
  #   export PATH="$PATH:$TEST_TMP/bin"   instead of   "$TEST_TMP/bin:$PATH"
  # The stub is present and +x, so -f/-x pass happily while some other `claude`
  # earlier on PATH takes every single invocation. This is the shape that let a
  # stand-in be invoked 21 times with the old guard fully in place.
  local decoy="$TEST_TMP/decoybin"
  mkdir -p "$decoy"
  printf '#!/usr/bin/env bash\nexit 99\n' >"$decoy/claude"
  chmod +x "$decoy/claude"
  local err status=0
  set +e
  err="$( export PATH="$decoy:$PATH"; \
          require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" 2>&1 >/dev/null )"
  status=$?
  set -e
  assert_eq "1" "$status" "a decoy claude ahead of the stub on PATH must be refused"
  assert_contains "$err" "does not resolve claude to the stub"
}

test_wiring_precondition_rejects_lookalike_stub_copy() {
  # A *copy* of the stub, in a directory that also ends in /bin: the paths look
  # alike, but Phase 6 must measure the committed file, not a snapshot of it.
  local look="$TEST_TMP/other/bin"
  mkdir -p "$look"
  cp -- "$REPO_ROOT/tests/fake-claude" "$look/claude"
  chmod +x "$look/claude"
  local err status=0
  set +e
  err="$( export PATH="$look:$PATH"; \
          require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" 2>&1 >/dev/null )"
  status=$?
  set -e
  assert_eq "1" "$status" "a look-alike copy is not the stub"
  assert_contains "$err" "does not resolve claude to the stub"
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

# ── the authoritative environment record ────────────────────────────────────
# The line log's env and PWD lines are forgeable: one argument containing a
# newline followed by `PWD=/spoofed` puts that exact line in the log, and
# assert_contains cannot tell it from the real one. $log.env gets the same
# NUL-delimited treatment as $log.argv, and it — not the line log — is what
# Phase 6's headline assertion ("the launch exported CLAUDE_CONFIG_DIR=<the
# account's dir>") must be built on.
test_env_record_is_authoritative() {
  CLAUDE_CONFIG_DIR="$TEST_TMP/acct" \
  CLAUDE_CODE_PLUGIN_CACHE_DIR="$TEST_TMP/shared/plugin-cache" \
    claude -p x
  read_env_record "$TEST_TMP/invocation.env"
  assert_eq "4" "${#ENVREC_ENTRIES[@]}" "exactly four NUL-terminated entries in the file"
  assert_eq "4" "${#ENVREC[@]}" "exactly the four recorded variables, nothing else"
  assert_eq "CLAUDE_CONFIG_DIR=$TEST_TMP/acct" "${ENVREC_ENTRIES[0]}" "and in the documented order"
  assert_eq "PWD=$PWD" "${ENVREC_ENTRIES[3]}"
  assert_eq "$TEST_TMP/acct" "${ENVREC[CLAUDE_CONFIG_DIR]}"
  assert_eq "$TEST_TMP/shared/plugin-cache" "${ENVREC[CLAUDE_CODE_PLUGIN_CACHE_DIR]}"
  assert_eq "$HOME" "${ENVREC[HOME]}"
  assert_eq "$PWD" "${ENVREC[PWD]}"
}

test_env_record_unset_is_empty_not_absent() {
  # An absent entry and an empty one must not be confusable: Phase 6 asserting
  # "CLAUDE_CONFIG_DIR was exported as X" needs "recorded, and empty" to be a
  # distinguishable, failing answer.
  env -u CLAUDE_CONFIG_DIR -u CLAUDE_CODE_PLUGIN_CACHE_DIR -u HOME \
      FAKE_CLAUDE_LOG="$TEST_TMP/invocation" PATH="$PATH" claude
  read_env_record "$TEST_TMP/invocation.env"
  assert_eq "4" "${#ENVREC[@]}"
  assert_eq "" "${ENVREC[CLAUDE_CONFIG_DIR]}"
  assert_eq "" "${ENVREC[CLAUDE_CODE_PLUGIN_CACHE_DIR]}"
  assert_eq "" "${ENVREC[HOME]}"
  assert_eq "$PWD" "${ENVREC[PWD]}"
}

test_env_record_resists_newline_injection() {
  # The spoof, verbatim: one argument that reads as four log lines.
  local spoof
  spoof="$(printf 'real\nARG=FORGED\nPWD=/spoofed\nCLAUDE_CONFIG_DIR=/spoofed-acct')"
  CLAUDE_CONFIG_DIR="$TEST_TMP/acct" claude "$spoof"

  # The line log is taken in — pinned here so nobody mistakes it for a record
  # worth asserting on.
  local log
  log="$(cat "$TEST_TMP/invocation")"
  assert_contains "$log" "PWD=/spoofed" "the line log is forgeable — this is why it is not the authority"
  assert_contains "$log" "CLAUDE_CONFIG_DIR=/spoofed-acct"

  # The sidecars are not.
  read_argv "$TEST_TMP/invocation.argv"
  assert_eq "1" "${#ARGV[@]}" "one argument, however many lines it spans"
  assert_eq "$spoof" "${ARGV[0]}"
  read_env_record "$TEST_TMP/invocation.env"
  assert_eq "4" "${#ENVREC_ENTRIES[@]}" "argv must not be able to add entries to the env record"
  assert_eq "4" "${#ENVREC[@]}"
  assert_eq "$TEST_TMP/acct" "${ENVREC[CLAUDE_CONFIG_DIR]}" "the real value, not the injected one"
  assert_eq "$PWD" "${ENVREC[PWD]}" "the real cwd, not the injected one"
}

test_env_record_handles_awkward_values() {
  # A value carrying its own newlines and `=` signs must round-trip whole.
  local weird
  weird="$(printf 'a=b\nCLAUDE_CONFIG_DIR=/spoofed\nc')"
  CLAUDE_CONFIG_DIR="$weird" claude
  read_env_record "$TEST_TMP/invocation.env"
  assert_eq "4" "${#ENVREC_ENTRIES[@]}" "a value cannot split itself into extra entries"
  assert_eq "4" "${#ENVREC[@]}"
  assert_eq "$weird" "${ENVREC[CLAUDE_CONFIG_DIR]}"
}

test_env_record_is_truncated_between_runs() {
  CLAUDE_CONFIG_DIR="$TEST_TMP/first" claude
  env -u CLAUDE_CONFIG_DIR FAKE_CLAUDE_LOG="$TEST_TMP/invocation" \
      PATH="$PATH" HOME="$HOME" claude
  read_env_record "$TEST_TMP/invocation.env"
  # The entry count, not the key count: an appended record repeats the same
  # four names and a name-keyed map would show four keys either way.
  assert_eq "4" "${#ENVREC_ENTRIES[@]}" "the env record must be truncated, not appended to"
  assert_eq "4" "${#ENVREC[@]}"
  assert_eq "" "${ENVREC[CLAUDE_CONFIG_DIR]}" "a stale value must not survive"
}

# ── PWD is the caller's cwd, recorded per invocation ────────────────────────
test_records_caller_cwd() {
  mkdir -p "$TEST_TMP/elsewhere"
  ( cd "$TEST_TMP/elsewhere" && claude )
  assert_contains "$(cat "$TEST_TMP/invocation")" "PWD=$TEST_TMP/elsewhere"
  read_env_record "$TEST_TMP/invocation.env"
  assert_eq "$TEST_TMP/elsewhere" "${ENVREC[PWD]}"
}

# ── the log path is configurable, and its directory is created ──────────────
test_log_path_directory_created() {
  local deep="$TEST_TMP/deep/deeper/record"
  FAKE_CLAUDE_LOG="$deep" claude -p x
  assert_contains "$(cat "$deep")" "ARG=-p"
  read_argv "$deep.argv"
  assert_eq "2" "${#ARGV[@]}"
  read_env_record "$deep.env"
  assert_eq "4" "${#ENVREC[@]}"
}

test_default_log_location() {
  rm -f -- "$TEST_TMP/fake-claude.log" "$TEST_TMP/fake-claude.log.argv" \
           "$TEST_TMP/fake-claude.log.env"
  env -u FAKE_CLAUDE_LOG PATH="$PATH" HOME="$HOME" TEST_TMP="$TEST_TMP" claude default
  assert_contains "$(cat "$TEST_TMP/fake-claude.log")" "ARG=default"
  read_argv "$TEST_TMP/fake-claude.log.argv"
  assert_eq "1" "${#ARGV[@]}"
  assert_eq "default" "${ARGV[0]}"
  read_env_record "$TEST_TMP/fake-claude.log.env"
  assert_eq "$PWD" "${ENVREC[PWD]}" "the sidecars follow the log wherever it is put"
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

# ── FAKE_CLAUDE_STDOUT: the one deliberate way the stub may speak ───────────
# Silence alone is not enough for Phase 6. Its launch tests must prove that
# *claude's own* stdout reaches the caller unmodified — and against a stub that
# is silent on every path, a launch path that swallowed claude's stdout entirely
# would pass byte-for-byte identically to a correct one. So there is exactly one
# opt-in knob, default off, so every byte-empty assertion above still holds.
test_stdout_knob_silent_when_unset() {
  assert_stdout_empty_bytes env -u FAKE_CLAUDE_STDOUT \
    FAKE_CLAUDE_LOG="$TEST_TMP/invocation" PATH="$PATH" HOME="$HOME" claude -p x
  # An empty value is silence too, not an empty line.
  assert_stdout_empty_bytes env FAKE_CLAUDE_STDOUT= \
    FAKE_CLAUDE_LOG="$TEST_TMP/invocation" PATH="$PATH" HOME="$HOME" claude -p x
}

test_stdout_knob_emits_exact_bytes() {
  local out bytes
  out="$(FAKE_CLAUDE_STDOUT='{"ok":true}' claude -p x)"
  assert_eq '{"ok":true}' "$out"
  # Byte-exact: no trailing newline added, which a command substitution would
  # hide and a `jq` pipeline would notice.
  FAKE_CLAUDE_STDOUT='{"ok":true}' claude -p x >"$TEST_TMP/knob.out"
  assert_eq "11" "$(wc -c <"$TEST_TMP/knob.out" | tr -d '[:space:]')" \
    "exactly the given bytes and nothing appended"

  # Awkward payloads survive, so a launch path that re-quoted or line-split
  # claude's stdout is catchable.
  FAKE_CLAUDE_STDOUT=$'one\ntwo\n' claude -p x >"$TEST_TMP/knob.out"
  assert_eq "8" "$(wc -c <"$TEST_TMP/knob.out" | tr -d '[:space:]')" \
    "an embedded and a trailing newline must both survive"
  assert_eq "$(printf 'one\ntwo')" "$(cat "$TEST_TMP/knob.out")"

  # And the knob speaks only on stdout.
  assert_eq "" "$(FAKE_CLAUDE_STDOUT=hello claude -p x 2>&1 >/dev/null)" \
    "the knob must not leak onto stderr"
}

test_stdout_knob_emits_before_a_nonzero_exit() {
  # A real claude can print and then fail; Phase 6 must be able to reproduce
  # that shape to prove the launch path forwards both.
  local out code=0
  set +e
  out="$(FAKE_CLAUDE_STDOUT=partial FAKE_CLAUDE_EXIT=3 claude -p x)"
  code=$?
  set -e
  assert_eq "3" "$code"
  assert_eq "partial" "$out"
}

test_stdout_knob_does_not_perturb_the_records() {
  # Turning the knob on must change stdout and nothing else, or Phase 6 cannot
  # use it and the argv/env assertions in the same test.
  claude -p "hello world" --flag
  local plain_log plain_argv
  plain_log="$(cat "$TEST_TMP/invocation")"
  plain_argv="$(od -An -c "$TEST_TMP/invocation.argv")"
  local plain_env
  plain_env="$(od -An -c "$TEST_TMP/invocation.env")"

  FAKE_CLAUDE_STDOUT='noise' claude -p "hello world" --flag >/dev/null
  assert_eq "$plain_log" "$(cat "$TEST_TMP/invocation")" \
    "the line log must be unchanged by the stdout knob"
  assert_eq "$plain_argv" "$(od -An -c "$TEST_TMP/invocation.argv")" \
    "the argv record must be unchanged by the stdout knob"
  assert_eq "$plain_env" "$(od -An -c "$TEST_TMP/invocation.env")" \
    "the env record must be unchanged by the stdout knob"
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

# ── a mistyped FAKE_CLAUDE_EXIT must never look like claude's own status ────
# The rejection used to exit 2 — a status the real claude can plausibly return,
# so a Phase 6 test asserting "the launch forwarded status 2" could be satisfied
# by a typo in its own knob rather than by the product. The rejection now uses
# 64 (EX_USAGE, outside anything claude returns) and, decisively, leaves a
# marker file: the exit status alone can always be coincidence, a named marker
# cannot.
test_rejected_exit_knob_is_out_of_band() {
  local code=0 err
  set +e
  err="$(FAKE_CLAUDE_EXIT=256 claude 2>&1 >/dev/null)"
  code=$?
  set -e
  assert_eq "64" "$code" "the rejection status must not collide with a status claude can return"
  assert_contains "$err" "FAKE_CLAUDE_EXIT"
  assert_eq "256" "$(cat "$TEST_TMP/invocation.rejected")" \
    "the marker must name the rejected value, out of band from the exit status"
  # stdout stays byte-empty even here, and even with the knob set.
  assert_stdout_empty_bytes env FAKE_CLAUDE_EXIT=256 FAKE_CLAUDE_STDOUT=leak \
    FAKE_CLAUDE_LOG="$TEST_TMP/invocation" PATH="$PATH" HOME="$HOME" claude

  # The marker must not outlive the mistake, or a stale one would condemn a
  # healthy call.
  claude -p x
  if [[ -e "$TEST_TMP/invocation.rejected" ]]; then
    assert_eq "absent" "present" \
      "an accepted invocation must clear the rejection marker"
  fi
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
