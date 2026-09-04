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
