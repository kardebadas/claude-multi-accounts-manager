# shellcheck shell=bash
# tests/test_runner.sh — the runner's own contract: isolation, discovery,
# honest exit codes, and a byte-empty stdout.
#
# Invoked as `bash tests/test_runner.sh` (by tests/run.sh, or by hand) with
# REPO_ROOT exported. Not executable and no shebang, matching tests/assert.sh
# and tests/test_assert.sh: nothing ever runs it as `./tests/test_runner.sh`.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"

# ── isolation ────────────────────────────────────────────────────────────────
assert_contains "$HOME" "claude-multi-test."
if [[ "$HOME" == "$REAL_HOME_GUARD" ]]; then
  printf '  FAIL: HOME is the real home — tests could destroy user config\n' >&2
  exit 1
fi
if [[ ! -d "$HOME" ]]; then
  printf '  FAIL: HOME does not exist\n' >&2
  exit 1
fi
assert_eq "" "$(ls -A "$HOME")" "a test HOME must start empty"
assert_eq "$HOME/.claude-multi" "$CLAUDE_MULTI_ROOT"
if [[ -e "$CLAUDE_MULTI_ROOT" ]]; then
  printf '  FAIL: CLAUDE_MULTI_ROOT must not be pre-created\n' >&2
  exit 1
fi
assert_eq "$TEST_TMP" "$PWD" "each test runs in its own temp cwd"
assert_contains "$TEST_TMP" "claude-multi-test."
# The runner keeps its own bookkeeping (the per-test HOME and the output
# capture) outside the test's cwd, so a test can assert on its cwd contents and
# so a test that clears its cwd cannot destroy the runner's records.
assert_eq "" "$(ls -A "$PWD")" "a test's cwd must start empty"
if [[ ! -f "$REPO_ROOT/tests/assert.sh" ]]; then
  printf '  FAIL: REPO_ROOT does not look like the checkout\n' >&2
  exit 1
fi
# CLAUDE_CONFIG_DIR is the one env var this whole project switches. If the
# developer's shell already has it pointed at a real account, it must not
# survive into a test: a test that honours it would read and write live config.
if [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  printf '  FAIL: CLAUDE_CONFIG_DIR leaked into the test env: [%s]\n' \
    "${CLAUDE_CONFIG_DIR}" >&2
  exit 1
fi

# ── a failing test file must fail the run, loudly ────────────────────────────
set +e
out="$(bash "$REPO_ROOT/tests/run.sh" "tests/fixtures/failing.sh" 2>&1)"
code=$?
set -e
assert_eq "1" "$code" "a failing test file must make the runner exit 1"
assert_contains "$out" "FAIL"
assert_contains "$out" "failing.sh"
assert_contains "$out" "meant to fail" "the failing test's own output must be shown"

# ── a passing test file must pass ────────────────────────────────────────────
set +e
out="$(bash "$REPO_ROOT/tests/run.sh" "tests/test_assert.sh" 2>&1)"
code=$?
set -e
assert_eq "0" "$code"
assert_contains "$out" "ok"
assert_contains "$out" "test_assert.sh"

# ── the runner's report is a diagnostic: stderr only ─────────────────────────
# stdout is reserved for the thing being launched. The runner never writes to
# it, on the passing path or the failing one.
assert_stdout_empty_bytes bash "$REPO_ROOT/tests/run.sh" "tests/test_assert.sh"
assert_stdout_empty_bytes bash "$REPO_ROOT/tests/run.sh" "tests/fixtures/failing.sh"

# ── discovery: depth-1 test_*.sh only, fixtures/ invisible ───────────────────
# Exercised against a miniature tests tree rather than this repo's own, because
# a no-argument run from inside a test file would rediscover this very file and
# recurse forever.
mini="$TEST_TMP/mini"
mkdir -p "$mini/tests/fixtures"
cp "$REPO_ROOT/tests/run.sh" "$mini/tests/run.sh"
cp "$REPO_ROOT/tests/assert.sh" "$mini/tests/assert.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' >"$mini/tests/test_alpha.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' >"$mini/tests/test_beta.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 1\n' >"$mini/tests/fixtures/test_ignored.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 1\n' >"$mini/tests/helper.sh"
out="$(bash "$mini/tests/run.sh" 2>&1)"
assert_contains "$out" "test_alpha.sh"
assert_contains "$out" "test_beta.sh"
assert_contains "$out" "2 passed, 0 failed"
assert_eq "" "$(printf '%s\n' "$out" | grep -F "test_ignored.sh" || true)" \
  "a test_*.sh below depth 1 must not be discovered"
assert_eq "" "$(printf '%s\n' "$out" | grep -F "helper.sh" || true)" \
  "only test_*.sh files run"

# ── an inherited CLAUDE_CONFIG_DIR must not survive into a test ──────────────
# Unconditional: the test supplies the hostile value itself rather than relying
# on the ambient environment happening to have one, so deleting the runner's
# `unset CLAUDE_CONFIG_DIR` goes red even under `env -u CLAUDE_CONFIG_DIR`.
printf 'set -euo pipefail\n[[ -z "${CLAUDE_CONFIG_DIR:-}" ]]\n' \
  >"$mini/tests/test_cfg.sh"
set +e
CLAUDE_CONFIG_DIR=/hostile/account \
  bash "$mini/tests/run.sh" "tests/test_cfg.sh" >/dev/null 2>&1
code=$?
set -e
assert_eq "0" "$code" "the runner must strip an inherited CLAUDE_CONFIG_DIR"
rm -f -- "$mini/tests/test_cfg.sh"

# ── runaway recursion must be capped, loudly ─────────────────────────────────
# A test file that invokes tests/run.sh with no arguments rediscovers itself.
# Unguarded that is an unbounded silent hang that fills TMPDIR; the runner must
# refuse past a small depth with a diagnostic and a non-zero exit.
rec="$TEST_TMP/rec"
mkdir -p "$rec/tests"
cp "$REPO_ROOT/tests/run.sh" "$rec/tests/run.sh"
printf 'set -euo pipefail\nbash "$REPO_ROOT/tests/run.sh"\n' \
  >"$rec/tests/test_recurse.sh"
rec_tmp="$TEST_TMP/rec-tmp"
mkdir -p "$rec_tmp"
declare -a limit=()
command -v timeout >/dev/null 2>&1 && limit=(timeout 20)
set +e
out="$(TMPDIR="$rec_tmp" ${limit[@]+"${limit[@]}"} bash "$rec/tests/run.sh" 2>&1)"
code=$?
set -e
assert_eq "1" "$code" "runaway recursion must exit 1, not hang until killed"
assert_contains "$out" "refusing to nest" "the depth cap must say why it refused"
assert_eq "" "$(ls -A "$rec_tmp")" "a capped run must leave no temp dirs behind"

# ── the cap must leave usable margin above the suite's own nesting ───────────
# The suite nests 2 levels structurally (this file runs the runner against a
# miniature tests tree); the recursion pin above then drives the runner to the
# cap on purpose, so the depth the suite is *observed* to reach is always the
# cap and says nothing about margin. The margin is cap - 2: the inherited depth
# a run can start from and still finish. At a cap of 4 that was 2, and a suite
# started at inherited depth 3 failed with a misleading assertion rather than a
# "cap refused" diagnostic. Asked from outside — an inherited depth past the
# cap makes the runner state its own ceiling — so this pin adds no nesting.
set +e
out="$(CLAUDE_MULTI_TEST_DEPTH=999 bash "$mini/tests/run.sh" "tests/test_alpha.sh" 2>&1)"
code=$?
set -e
assert_eq "1" "$code" "an inherited depth past the cap must refuse"
cap_stated=0
if [[ "$out" =~ deeper\ than\ ([0-9]+)\ levels ]]; then
  cap_stated="${BASH_REMATCH[1]}"
fi
if ((cap_stated < 6)); then
  printf '  FAIL: the depth cap [%s] leaves too little margin above the 2 levels this suite nests\n' \
    "$cap_stated" >&2
  exit 1
fi

# ── a malformed depth counter must be a sentence, not a bash internal error ──
# Only run.sh itself ever sets CLAUDE_MULTI_TEST_DEPTH, but an inherited junk
# value used to reach `$(( … ))` raw: `abc: unbound variable` under `set -u`,
# `1foo: value too great for base`. Same class as the unset-HOME guard below.
for bad in abc 1foo -3 "2 3"; do
  set +e
  out="$(CLAUDE_MULTI_TEST_DEPTH="$bad" \
    bash "$REPO_ROOT/tests/run.sh" "tests/test_assert.sh" 2>&1)"
  code=$?
  set -e
  assert_eq "1" "$code" "a malformed depth counter [$bad] must fail safe"
  assert_contains "$out" "CLAUDE_MULTI_TEST_DEPTH must be" \
    "the diagnostic must name the variable [$bad]"
  assert_eq "" "$(printf '%s\n' "$out" | grep -E 'run\.sh: line [0-9]+' || true)" \
    "a malformed depth counter [$bad] must not surface as a raw bash error"
done

# ── a test that clears its own cwd must not truncate the run ─────────────────
# The runner's capture file used to live in the test's cwd, so a failing test
# that wiped its cwd made the runner's own `sed` fail under `set -e`: exit 2,
# no summary, and every remaining file silently skipped.
wipe="$TEST_TMP/wipe"
mkdir -p "$wipe/tests"
cp "$REPO_ROOT/tests/run.sh" "$wipe/tests/run.sh"
printf 'set -euo pipefail\nexit 0\n' >"$wipe/tests/test_aaa.sh"
printf 'set -euo pipefail\nrm -rf -- ./* "$TEST_TMP"/*\nexit 1\n' \
  >"$wipe/tests/test_bbb_wipe.sh"
printf 'set -euo pipefail\nexit 0\n' >"$wipe/tests/test_ccc.sh"
printf 'set -euo pipefail\nexit 0\n' >"$wipe/tests/test_ddd.sh"
wipe_tmp="$TEST_TMP/wipe-tmp"
mkdir -p "$wipe_tmp"
set +e
out="$(TMPDIR="$wipe_tmp" bash "$wipe/tests/run.sh" 2>&1)"
code=$?
set -e
assert_eq "1" "$code" "a cwd-clearing failing test must still exit 1"
assert_contains "$out" "3 passed, 1 failed" "the summary must still be printed"
assert_contains "$out" "test_ccc.sh" "files after the wiping test must still run"
assert_contains "$out" "test_ddd.sh" "files after the wiping test must still run"
assert_eq "" "$(printf '%s\n' "$out" | grep -F 'sed:' || true)" \
  "the runner's capture must be out of reach of the test's cwd"
assert_eq "" "$(ls -A "$wipe_tmp")" "no temp dir may leak"

# ── destroying the runner's own capture must not garble the report ───────────
# The capture lives one `..` above the test's cwd, so a test that deliberately
# reaches out of its cwd can still delete it. The fallback line covers that,
# but sed's own complaint must not reach the report un-indented beside it.
cap="$TEST_TMP/cap"
mkdir -p "$cap/tests"
cp "$REPO_ROOT/tests/run.sh" "$cap/tests/run.sh"
printf 'set -euo pipefail\nrm -f -- "$TEST_TMP/../output"\nexit 1\n' \
  >"$cap/tests/test_nocap.sh"
printf 'set -euo pipefail\nexit 0\n' >"$cap/tests/test_zzz.sh"
cap_tmp="$TEST_TMP/cap-tmp"
mkdir -p "$cap_tmp"
set +e
out="$(TMPDIR="$cap_tmp" bash "$cap/tests/run.sh" 2>&1)"
code=$?
set -e
assert_eq "1" "$code" "a test that deletes the capture must still exit 1"
assert_contains "$out" "1 passed, 1 failed" "the summary must still be printed"
assert_contains "$out" "capture file unreadable" "the fallback line must be printed"
assert_eq "" "$(printf '%s\n' "$out" | grep -F 'sed:' || true)" \
  "sed's own error must not reach the report un-indented"
assert_eq "" "$(ls -A "$cap_tmp")" "no temp dir may leak"

# ── an unset HOME must be a sentence, not a bash internal error ──────────────
set +e
out="$(env -u HOME bash "$REPO_ROOT/tests/run.sh" "tests/test_assert.sh" 2>&1)"
code=$?
set -e
assert_eq "1" "$code" "an unset HOME must fail safe"
assert_contains "$out" "HOME is unset" "the diagnostic must name the variable"
assert_eq "" "$(printf '%s\n' "$out" | grep -F 'unbound variable' || true)" \
  "an unset HOME must not surface as a raw set -u abort"

# ── an interrupted run must not leak its temp dir ────────────────────────────
int_tmp="$TEST_TMP/int-tmp"
mkdir -p "$int_tmp"
printf 'set -euo pipefail\nsleep 0.6\n' >"$mini/tests/test_slow.sh"
TMPDIR="$int_tmp" bash "$mini/tests/run.sh" "tests/test_slow.sh" >/dev/null 2>&1 &
runner_pid=$!
sleep 0.2
kill -TERM "$runner_pid" 2>/dev/null || true
wait "$runner_pid" 2>/dev/null || true
assert_eq "" "$(ls -A "$int_tmp")" "an interrupted run must clean up its temp dir"
rm -f -- "$mini/tests/test_slow.sh"
