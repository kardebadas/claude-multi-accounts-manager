#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/assert.sh"
. "$REPO_ROOT/lib/util.sh"
. "$REPO_ROOT/lib/config.sh"
. "$REPO_ROOT/lib/links.sh"
. "$REPO_ROOT/lib/seed.sh"
. "$REPO_ROOT/lib/memory.sh"
. "$REPO_ROOT/lib/accounts.sh"

LIB_ACCOUNTS="$REPO_ROOT/lib/accounts.sh"
REAL_HOME="$HOME"

# Refuse to run against anything that is not a throwaway tree.
guard_fake_root() {
  case "${CLAUDE_MULTI_ROOT:-}" in
    "$REAL_HOME/.claude-multi"|"$REAL_HOME/.claude"|""|"/"|"$REAL_HOME")
      printf 'FATAL: test tried to use a real root: %s\n' "${CLAUDE_MULTI_ROOT:-<unset>}" >&2
      exit 99 ;;
  esac
  case "${HOME:-}" in
    "$REAL_HOME")
      printf 'FATAL: test tried to use the real HOME\n' >&2
      exit 99 ;;
  esac
}

# Builds a temp HOME + a fake root whose shared/ tree is already seeded BY HAND.
# seed_shared is never called: A38 makes it refuse an existing shared/, and this
# fixture is not a test of seeding.
# Prints the temp base dir. Exports HOME and CLAUDE_MULTI_ROOT.
fake_root() {
  local base
  base="$(mktemp -d "${TMPDIR:-/tmp}/cm-acct.XXXXXX")"
  export HOME="$base/home"
  export CLAUDE_MULTI_ROOT="$HOME/.claude-multi"
  guard_fake_root
  mkdir -p "$CLAUDE_MULTI_ROOT/shared/agents" \
           "$CLAUDE_MULTI_ROOT/shared/hooks" \
           "$CLAUDE_MULTI_ROOT/shared/commands" \
           "$CLAUDE_MULTI_ROOT/shared/agent-memory" \
           "$CLAUDE_MULTI_ROOT/shared/project-memory" \
           "$CLAUDE_MULTI_ROOT/shared/plugin-cache" \
           "$base/codex-skills"
  printf '%s\n' '# shared rules' > "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md"
  printf '%s\n' '{}' > "$CLAUDE_MULTI_ROOT/shared/settings.json"
  ln -s "$base/codex-skills" "$CLAUDE_MULTI_ROOT/shared/skills"
  printf '%s\n' "$base"
}

mk_account() {
  mkdir -p "$CLAUDE_MULTI_ROOT/$1"
}

# yesno <command> [args...] — prints "yes" if the command succeeds, "no" if it
# fails. tests/assert.sh has no `fail`, so a boolean claim about the filesystem
# is expressed as:
#     assert_eq "yes" "$(yesno test -d "$p")" "the account directory exists"
#     assert_eq "no"  "$(yesno test -e "$p")" "nothing was created"
# It is total by construction, so it can never abort a test under errexit, and
# the message survives (which `assert_fails` cannot carry).
yesno() {
  if "$@"; then printf 'yes'; else printf 'no'; fi
}

# feed <line> <command> [args...] — runs the command with <line> on stdin.
# Lets a stdin-reading function be passed to assert_stdout_empty_bytes, which
# takes argv and cannot be given a pipeline.
feed() {
  local line="$1"; shift
  printf '%s\n' "$line" | "$@"
}

test_list_accounts_is_empty_on_a_fresh_root() {
  fake_root >/dev/null
  local out
  out="$(list_accounts)"
  assert_eq "" "$out" "a fresh root has zero accounts"
}

# ── harness teeth ────────────────────────────────────────────────────────────
# Does the runner block below actually catch a failing test? The dangerous case
# is not "a test fails" — it is "a test's FIRST assertion fails and a LATER one
# passes", which is what an `if ! ( … )` dispatcher reports as PASS, because
# bash's errexit suppression inside an `if` condition reaches into subshells.
#
# This builds a probe file out of the REAL runner block (copied verbatim out of
# this file with sed, so the probe cannot drift from what ships) plus two test
# functions: one that fails its first assertion and would pass its last, and one
# that is clean. The probe must report the first FAILED, the second passed, and
# exit 1 — and must never reach the sentinel after the failing assertion.
test_the_runner_block_reports_an_early_failing_assertion() {
  local probe_dir probe rc=0 err
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cm-teeth.XXXXXX")"
  probe="$probe_dir/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. %q\n' "$REPO_ROOT/tests/assert.sh"
    printf '%s\n' \
      'test_early_fail_then_pass() {' \
      '  assert_eq "expected" "actual" "the first assertion must abort this test"' \
      '  printf "TEETH-SENTINEL-REACHED\n" >&2' \
      '  assert_eq "same" "same" "a later passing assertion must not rescue it"' \
      '}' \
      'test_clean_control() {' \
      '  assert_eq "a" "a" "the control test must still pass"' \
      '}'
    sed -n '/^# ── RUNNER ──/,$p' "$REPO_ROOT/tests/test_accounts.sh"
  } > "$probe"

  # `env -u CM_ONE_TEST` is required, not tidiness: this test is itself running
  # inside a CM_ONE_TEST re-exec, so the probe would inherit that variable,
  # take the single-test branch of the block it just copied, and fail with 127
  # for a test name it does not define. Clearing the seam is what makes the
  # probe run its own dispatcher.
  #
  # And the status is captured with set +e / $? / set -e for the same reason the
  # dispatcher is: `if ! bash -- "$probe"` would suppress errexit in this shell
  # and read as if the vulnerable form were acceptable.
  set +e
  err="$(env -u CM_ONE_TEST bash -- "$probe" 2>&1 >/dev/null)"
  rc=$?
  set -e
  rm -rf -- "$probe_dir"

  assert_eq "1" "$rc" "a failing test must make the file exit non-zero"
  assert_contains "$err" "FAIL  test_early_fail_then_pass"
  assert_contains "$err" "pass  test_clean_control"
  assert_contains "$err" "2 test(s), 1 failure(s)"
  assert_eq "" "$(printf '%s\n' "$err" | grep -F 'TEETH-SENTINEL-REACHED' || true)" \
            "an aborted test must not run past its failed assertion"
}

# ── RUNNER ── KEEP THIS BLOCK LAST IN THE FILE ───────────────────────────────
# Every later task in 5a and 5b appends its test functions ABOVE this marker.
#
# tests/run.sh only checks the file's exit status, so without this block the
# file would define its tests, exit 0, and be reported `ok` while running
# nothing — including the whole guarded-delete suite. See the Test-file
# execution contract in Global Constraints.
#
# Each test runs in a FRESH bash process (self re-exec with CM_ONE_TEST set),
# so `set -euo pipefail` above is genuinely in force inside it and a bare
# failing assertion aborts that test and nothing else.
#
# DO NOT "simplify" the status capture below to `if ! ( set -e; "$t" ); then`
# or to `... || _cm_rc=$?`. Bash disables errexit for anything run inside an
# `if` condition or on the left of a &&/|| list, AND that suppression reaches
# into subshells: a test whose FIRST assertion fails would then keep running,
# and a later passing assertion in the same function would leave the exit
# status 0 — the test would be reported as PASSED. Phase 1 Task 7 caught this
# with a mutant that escaped its dispatcher for exactly this reason. The
# `set +e` / read `$?` / `set -e` form below is the verified one, and is the
# form already committed throughout tests/test_runner.sh.
# test_the_runner_block_reports_an_early_failing_assertion (above) is the
# regression test for this comment; if you change the dispatcher, that test is
# what tells you whether the harness still has teeth.
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
  printf 'FATAL: tests/test_accounts.sh defined no tests — a green run here would be a lie\n' >&2
  exit 1
fi
if (( _cm_failed > 0 )); then
  exit 1
fi
