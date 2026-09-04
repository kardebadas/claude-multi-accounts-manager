#!/usr/bin/env bash
# tests/run.sh — zero-dependency test runner.
#
#   tests/run.sh                        run every tests/test_*.sh
#   tests/run.sh tests/test_util_log.sh run just these files
#
# Each file runs in its own subshell with the three seams pointed somewhere
# harmless:
#   HOME              a fresh empty temp dir             (seam 1)
#   CLAUDE_MULTI_ROOT $HOME/.claude-multi, not created   (seam 2)
#   PATH              untouched; a test that needs a fake `claude` prepends
#                     its own stub dir                   (seam 3)
# CLAUDE_CONFIG_DIR is unset rather than redirected: it is the one variable
# this project switches, and a value inherited from the developer's shell would
# point a test straight at a live account. Nothing under the real $HOME is read
# or written by any test.
#
# The runner's own bookkeeping — the per-test HOME and the captured output —
# lives beside the test's cwd, never inside it, so a test that clears its cwd
# (this project's tests do exercise `rm -rf`) cannot destroy the records the
# runner needs to report the result, and so a test can assert on its own cwd
# without having to know about runner-owned entries.
#
# Everything this runner prints — progress, failure reports, the summary — goes
# to stderr. stdout is reserved project-wide so `claude-multi work -p "…" | jq`
# is never corrupted, and the runner holds itself to the same rule so it can be
# composed into any pipeline without polluting it.
set -euo pipefail

# ── runaway-recursion guard ──────────────────────────────────────────────────
# A test file that invokes this runner with no arguments rediscovers itself and
# recurses without bound: every level captures its child's output and prints
# nothing until the child finishes, so the observable symptom is a silent hang
# that fills TMPDIR one temp dir per level. The cap turns that hang into one
# line and exit 1.
#
# Measured, not guessed, by instrumenting this line and counting the depths the
# real suite actually enters. Two different numbers, and only one of them is a
# budget:
#   * structural nesting is 2 — the suite runs a test file, which runs the
#     runner against a miniature tests tree. That is what the cap must clear.
#   * the depth the whole suite is observed to reach is always the cap itself,
#     because the recursion pin in tests/test_runner.sh deliberately drives the
#     runner until it refuses. Raising the cap raises that observation in
#     lockstep, so it is not a headroom measurement and must not be read as one.
# So the usable margin is cap - 2, the inherited depth a run can start from and
# still finish. Measured at this cap: inherited depth 0-6 pass, 7 refuses. At
# the previous cap of 4 that margin was 2, and a suite started at inherited
# depth 3 failed with a misleading assertion instead of a "cap refused" line.
# Refusal costs the same fraction of a second at 8 as at 4, so the margin is
# free. Do not lower this below structural nesting plus a few spare levels, and
# do not make it settable from the environment: the ceiling must not be
# liftable by the thing it caps.
CLAUDE_MULTI_TEST_MAX_DEPTH=8
# A junk inherited value must be a sentence rather than a raw `set -u` abort or
# an arithmetic parse error from inside $(( … )).
_inherited_depth="${CLAUDE_MULTI_TEST_DEPTH:-0}"
if [[ ! "$_inherited_depth" =~ ^[0-9]{1,4}$ ]]; then
  printf 'tests/run.sh: CLAUDE_MULTI_TEST_DEPTH must be a non-negative integer of at most 4 digits; got [%s]\n' \
    "$_inherited_depth" >&2
  exit 1
fi
_depth=$(( _inherited_depth + 1 ))
if ((_depth > CLAUDE_MULTI_TEST_MAX_DEPTH)); then
  printf 'tests/run.sh: refusing to nest deeper than %d levels — runaway recursion (does a test file invoke tests/run.sh with no arguments?)\n' \
    "$CLAUDE_MULTI_TEST_MAX_DEPTH" >&2
  exit 1
fi
export CLAUDE_MULTI_TEST_DEPTH="$_depth"

# The real home is recorded for REAL_HOME_GUARD, so an unset HOME is a hard
# stop — stated as a sentence rather than left to `set -u`.
if [[ -z "${HOME:-}" ]]; then
  printf 'tests/run.sh: HOME is unset in this environment; it is needed to record REAL_HOME_GUARD\n' >&2
  exit 1
fi

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

declare -a files=()
if (($# > 0)); then
  for arg in "$@"; do
    case "$arg" in
      /*) files+=("$arg") ;;
      *)  files+=("$REPO_ROOT/$arg") ;;
    esac
  done
else
  while IFS= read -r f; do
    files+=("$f")
  done < <(find "$REPO_ROOT/tests" -maxdepth 1 -type f -name 'test_*.sh' | sort)
fi

if ((${#files[@]} == 0)); then
  printf 'no test files found\n' >&2
  exit 1
fi

real_home="$HOME"
passed=0
declare -a failed=()

# One temp dir per test file, removed as soon as that file finishes — and by
# the EXIT trap if the run is interrupted part way through one.
tmp=""
_cleanup_tmp() {
  local doomed="${tmp:-}"
  tmp=""
  [[ -n "$doomed" && -d "$doomed" ]] || return 0
  # Composed from mktemp output, but check the shape before rm -rf anyway.
  case "$doomed" in
    */claude-multi-test.*) rm -rf -- "$doomed" ;;
    *) printf 'refusing to remove unexpected temp dir: %s\n' "$doomed" >&2 ;;
  esac
  return 0
}
trap _cleanup_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for path in "${files[@]}"; do
  name="$(basename -- "$path")"
  if [[ ! -f "$path" ]]; then
    printf 'FAIL  %s (no such file)\n' "$name" >&2
    failed+=("$name")
    continue
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-multi-test.XXXXXX")"
  # $tmp/cwd is the test's; $tmp/home and $tmp/output are the runner's.
  mkdir -p -- "$tmp/home" "$tmp/cwd"
  out="$tmp/output"

  if (
    set -euo pipefail
    export HOME="$tmp/home"
    export CLAUDE_MULTI_ROOT="$tmp/home/.claude-multi"
    export REPO_ROOT
    export TEST_TMP="$tmp/cwd"
    export REAL_HOME_GUARD="$real_home"
    unset CLAUDE_CONFIG_DIR
    cd -- "$tmp/cwd"
    bash -- "$path"
  ) >"$out" 2>&1; then
    printf 'ok    %s\n' "$name" >&2
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "$name" >&2
    # The capture is out of the test's reach, but a runner must never let a
    # missing file abort the whole run under `set -e`.
    # sed's own "can't read" line would land un-indented beside the fallback,
    # so its stderr is dropped and the fallback line carries the report.
    sed 's/^/      /' "$out" >&2 2>/dev/null \
      || printf '      (runner capture file unreadable)\n' >&2
    failed+=("$name")
  fi

  _cleanup_tmp
done

printf '\n%d passed, %d failed\n' "$passed" "${#failed[@]}" >&2
if ((${#failed[@]} > 0)); then
  printf 'failed: %s\n' "${failed[*]}" >&2
  exit 1
fi
