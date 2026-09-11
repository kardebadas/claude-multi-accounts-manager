#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/assert.sh"

REAL_HOME="${REAL_HOME_GUARD:-$HOME}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-launch.XXXXXX")"

cleanup_launch_tmp() {
  case "${TMP:-}" in
    */cm-launch.*) rm -rf -- "$TMP" ;;
    *) printf 'FATAL: refusing to remove unexpected launch-test path: %s\n' \
         "${TMP:-<unset>}" >&2 ;;
  esac
}
trap cleanup_launch_tmp EXIT

export HOME="$TMP/home"
export CLAUDE_MULTI_ROOT="$HOME/.claude-multi"
mkdir -p "$HOME"

# Every fixture mutator calls this first. A typo may therefore fail a test, but
# can never redirect setup into the developer's real Claude directories.
guard_fake_root() {
  case "${HOME:-}" in
    ""|/|"$REAL_HOME")
      printf 'FATAL: launch test refused unsafe HOME\n' >&2
      exit 99 ;;
    "$TMP"/*) ;;
    *)
      printf 'FATAL: launch test HOME is outside its temporary tree\n' >&2
      exit 99 ;;
  esac
  case "${CLAUDE_MULTI_ROOT:-}" in
    ""|/|"$REAL_HOME"|"$REAL_HOME/.claude"|"$REAL_HOME/.claude-multi")
      printf 'FATAL: launch test refused unsafe multi root\n' >&2
      exit 99 ;;
    "$TMP"/*) ;;
    *)
      printf 'FATAL: launch test multi root is outside its temporary tree\n' >&2
      exit 99 ;;
  esac
}

# A seeded fake multi root. Accounts are deliberately created separately and
# initially unlinked so later launch tests exercise the real healing path.
mk_root() {
  guard_fake_root
  local shared="$CLAUDE_MULTI_ROOT/shared"
  mkdir -p "$shared/agents" \
           "$shared/hooks" \
           "$shared/commands" \
           "$shared/agent-memory" \
           "$shared/project-memory" \
           "$shared/plugin-cache" \
           "$TMP/codex-skills"
  printf '%s\n' '# shared rules' > "$shared/CLAUDE.md"
  printf '%s\n' '{}' > "$shared/settings.json"
  ln -s "$TMP/codex-skills" "$shared/skills"
}

mk_account() {
  guard_fake_root
  local name="${1:?mk_account needs an account name}"
  mkdir -p "$CLAUDE_MULTI_ROOT/$name/projects"
  printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{}}' \
    > "$CLAUDE_MULTI_ROOT/$name/.claude.json"
}

# The PATH seam used by every launch test.
stub_bin_dir() {
  local dir="$TMP/stub-bin"
  mkdir -p "$dir"
  ln -sfn "$REPO_ROOT/tests/fake-claude" "$dir/claude"
  printf '%s' "$dir"
}

STUB_BIN="$(stub_bin_dir)"
export PATH="$STUB_BIN:$PATH"
export FAKE_CLAUDE_LOG="$TMP/invocation"

# Copied from tests/test_fake_claude.sh: compare fully resolved identities, not
# path strings, and fail before dispatch if PATH could reach a real Claude.
canonical_path() {
  local p="${1-}" dir base
  [[ -n "$p" && -e "$p" ]] || return 1
  if p="$(readlink -f -- "$1" 2>/dev/null)" && [[ -n "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  dir="$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename -- "$1")"
  printf '%s/%s' "$dir" "$base"
}

require_fake_claude_wiring() {
  local stub="${1-}" on_path="" want="" got=""
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
  if [[ "$want" != "$got" ]]; then
    printf '  FAIL: PATH does not resolve claude to the stub; refusing to run (want [%s], got [%s] via [%s])\n' \
      "$want" "$got" "$on_path" >&2
    return 1
  fi
  return 0
}

# This precondition deliberately precedes test discovery and dispatch.
require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" || exit 1

# Sidecar readers. The readable line log is never an assertion authority.
rec_argv() {
  local file="$1.argv" arg index=0
  [[ -f "$file" ]] || return 0
  while IFS= read -r -d '' arg; do
    printf '%d\t%s\n' "$index" "$arg"
    index=$(( index + 1 ))
  done < "$file"
}

rec_argc() {
  local file="$1.argv" arg count=0
  [[ -f "$file" ]] || { printf '0'; return 0; }
  while IFS= read -r -d '' arg; do count=$(( count + 1 )); done < "$file"
  printf '%s' "$count"
}

rec_arg() {
  local file="$1.argv" wanted="$2" arg index=0
  [[ -f "$file" ]] || return 1
  while IFS= read -r -d '' arg; do
    if [[ "$index" == "$wanted" ]]; then
      printf '%s' "$arg"
      return 0
    fi
    index=$(( index + 1 ))
  done < "$file"
  return 1
}

rec_env_val() {
  local file="$1.env" wanted="$2" entry
  [[ -f "$file" ]] || return 1
  while IFS= read -r -d '' entry; do
    if [[ "${entry%%=*}" == "$wanted" ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done < "$file"
  return 1
}

declare -a REC_ENV_ENTRIES=()
read_env_record() {
  REC_ENV_ENTRIES=()
  local entry
  while IFS= read -r -d '' entry; do
    REC_ENV_ENTRIES+=("$entry")
  done < "$1.env"
}

test_fixture_guard_refuses_real_home_and_root() {
  local rc=0 err
  set +e
  err="$( (
    export HOME="$REAL_HOME"
    export CLAUDE_MULTI_ROOT="$REAL_HOME/.claude-multi"
    mk_root
  ) 2>&1 >/dev/null )"
  rc=$?
  set -e
  assert_eq "99" "$rc" "fixture setup must refuse the real HOME and multi root"
  assert_contains "$err" "FATAL: launch test refused unsafe HOME"
}

test_harness_resolves_the_executable_stub_before_dispatch() {
  local want got decoy rc=0 err
  want="$(canonical_path "$REPO_ROOT/tests/fake-claude")"
  got="$(canonical_path "$(command -v claude)")"
  assert_eq "$want" "$got" "PATH must select the canonical fake Claude"
  assert_eq "yes" "$(if [[ -x "$(command -v claude)" ]]; then printf yes; else printf no; fi)" \
    "the selected stub must be executable"

  # Mutation proof for the dangerous PATH-append typo: an earlier executable
  # must make the guard refuse instead of dispatching it.
  decoy="$TMP/decoy-bin"
  mkdir -p "$decoy"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$decoy/claude"
  chmod 700 "$decoy/claude"
  set +e
  err="$(PATH="$decoy:$PATH" require_fake_claude_wiring \
    "$REPO_ROOT/tests/fake-claude" 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "1" "$rc" "a decoy ahead of the stub must be refused"
  assert_contains "$err" "does not resolve claude to the stub"
}

test_sidecar_readers_ignore_the_forgeable_line_log() {
  local rec="$TMP/line-log-mutant"
  printf '%s\n' 'ARGC=2' 'ARG=forged-one' 'ARG=forged-two' \
    'CLAUDE_CONFIG_DIR=/forged' > "$rec"
  printf '%s\0' 'real-sidecar-argument' > "$rec.argv"
  printf '%s\0' 'CLAUDE_CONFIG_DIR=' \
    'CLAUDE_CODE_PLUGIN_CACHE_DIR=' "HOME=$HOME" "PWD=$PWD" > "$rec.env"

  assert_eq "1" "$(rec_argc "$rec")" \
    "argv assertions must use the NUL sidecar, not the readable log"
  assert_eq "real-sidecar-argument" "$(rec_arg "$rec" 0)"
  assert_eq "" "$(rec_env_val "$rec" CLAUDE_CONFIG_DIR)" \
    "environment assertions must use the NUL sidecar"
}

test_stub_contract_records_nul_argv_four_env_entries_and_exit() {
  mk_root
  mk_account work
  local rec="$TMP/headline" out="$TMP/headline.out" rc=0
  set +e
  env -u CLAUDE_CODE_PLUGIN_CACHE_DIR \
    PATH="$PATH" HOME="$HOME" FAKE_CLAUDE_LOG="$rec" FAKE_CLAUDE_EXIT=7 \
    CLAUDE_CONFIG_DIR="$CLAUDE_MULTI_ROOT/work" \
    claude --resume "two words" '' > "$out"
  rc=$?
  set -e

  assert_eq "7" "$rc" "a validated fake-Claude status must propagate"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the stub writes zero stdout bytes by default"
  assert_eq "3" "$(rec_argc "$rec")"
  assert_eq "--resume" "$(rec_arg "$rec" 0)"
  assert_eq "two words" "$(rec_arg "$rec" 1)"
  assert_eq "" "$(rec_arg "$rec" 2)" "the empty third argument must survive"

  read_env_record "$rec"
  assert_eq "4" "${#REC_ENV_ENTRIES[@]}" "the env sidecar has exactly four entries"
  assert_eq "CLAUDE_CONFIG_DIR=$CLAUDE_MULTI_ROOT/work" "${REC_ENV_ENTRIES[0]}"
  assert_eq "CLAUDE_CODE_PLUGIN_CACHE_DIR=" "${REC_ENV_ENTRIES[1]}"
  assert_eq "HOME=$HOME" "${REC_ENV_ENTRIES[2]}"
  assert_eq "PWD=$PWD" "${REC_ENV_ENTRIES[3]}"
  assert_eq "no" "$(if [[ -e "$rec.rejected" ]]; then printf yes; else printf no; fi)" \
    "an accepted exit value must not leave a rejection marker"
}

test_stub_stdout_knob_and_invalid_exit_are_byte_exact() {
  local rec="$TMP/knobs" out="$TMP/knobs.out" err="$TMP/knobs.err" rc=0
  FAKE_CLAUDE_LOG="$rec" FAKE_CLAUDE_STDOUT=$'one\ntwo\n' \
    claude > "$out"
  assert_eq "8" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "FAKE_CLAUDE_STDOUT must be emitted verbatim"
  assert_eq "$(printf 'one\ntwo')" "$(cat "$out")"

  set +e
  FAKE_CLAUDE_LOG="$rec" FAKE_CLAUDE_EXIT=256 FAKE_CLAUDE_STDOUT=leak \
    claude > "$out" 2> "$err"
  rc=$?
  set -e
  assert_eq "64" "$rc" "an invalid exit value must be rejected out of band"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "invalid exit validation must happen before stdout"
  assert_eq "256" "$(cat "$rec.rejected")"
  assert_contains "$(cat "$err")" "FAKE_CLAUDE_EXIT must be an integer 0-255"
}

# Harness-teeth mutation proof: copy this file's real dispatcher beneath an
# early-failing test whose later assertion would pass if errexit were masked.
test_runner_dispatch_reports_an_early_failing_assertion() {
  local dir probe rc=0 err
  dir="$(mktemp -d "${TMPDIR:-/tmp}/cm-launch-teeth.XXXXXX")"
  probe="$dir/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. %q\n' "$REPO_ROOT/tests/assert.sh"
    printf '%s\n' \
      'test_early_fail_then_pass() {' \
      '  assert_eq "expected" "actual" "the first assertion must abort"' \
      '  printf "LAUNCH-TEETH-SENTINEL\n" >&2' \
      '  assert_eq "same" "same" "a later pass must not rescue the test"' \
      '}' \
      'test_clean_control() { assert_eq "a" "a"; }'
    sed -n '/^# ── RUNNER ──/,$p' "$REPO_ROOT/tests/test_launch.sh"
  } > "$probe"

  set +e
  err="$(env -u CM_ONE_TEST bash -- "$probe" 2>&1 >/dev/null)"
  rc=$?
  set -e
  rm -rf -- "$dir"
  assert_eq "1" "$rc" "the dispatcher must report an early failed assertion"
  assert_contains "$err" "FAIL  test_early_fail_then_pass"
  assert_contains "$err" "pass  test_clean_control"
  assert_contains "$err" "2 test(s), 1 failure(s)"
  assert_eq "" "$(printf '%s\n' "$err" | grep -F 'LAUNCH-TEETH-SENTINEL' || true)" \
    "the failing test must stop before its later passing assertion"
}

# ── RUNNER ── KEEP THIS BLOCK LAST IN THE FILE ───────────────────────────────
if [[ -n "${CM_ONE_TEST:-}" ]]; then
  "$CM_ONE_TEST"
  exit 0
fi

_cm_ran=0
_cm_failed=0
while IFS= read -r _cm_test; do
  _cm_ran=$(( _cm_ran + 1 ))
  set +e
  CM_ONE_TEST="$_cm_test" bash -- "${BASH_SOURCE[0]}"
  _cm_rc=$?
  set -e
  if (( _cm_rc == 0 )); then
    printf '  pass  %s\n' "$_cm_test" >&2
  else
    printf '  FAIL  %s (exit %d)\n' "$_cm_test" "$_cm_rc" >&2
    _cm_failed=$(( _cm_failed + 1 ))
  fi
done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

printf '%s: %d test(s), %d failure(s)\n' \
  "${BASH_SOURCE[0]##*/}" "$_cm_ran" "$_cm_failed" >&2
if (( _cm_ran == 0 )); then
  printf 'FATAL: tests/test_launch.sh defined no tests — refusing false green\n' >&2
  exit 1
fi
if (( _cm_failed > 0 )); then
  exit 1
fi
