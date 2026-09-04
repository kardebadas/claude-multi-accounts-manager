# shellcheck shell=bash
# tests/fixtures/failing.sh — a deliberately failing test file.
#
# Lives in fixtures/ so the depth-1 tests/test_*.sh discovery in tests/run.sh
# never picks it up, and is named without the test_ prefix for good measure.
# Used by tests/test_runner.sh to prove the runner exits non-zero and echoes a
# failing file's own output. Not executable and no shebang, matching the other
# test files: the runner always invokes them as `bash <file>`.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"
assert_eq "expected" "actual" "this assertion is meant to fail"
