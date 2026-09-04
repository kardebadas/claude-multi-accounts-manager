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
# Everything this runner prints — progress, failure reports, the summary — goes
# to stderr. stdout is reserved project-wide so `claude-multi work -p "…" | jq`
# is never corrupted, and the runner holds itself to the same rule so it can be
# composed into any pipeline without polluting it.
set -euo pipefail

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

for path in "${files[@]}"; do
  name="$(basename -- "$path")"
  if [[ ! -f "$path" ]]; then
    printf 'FAIL  %s (no such file)\n' "$name" >&2
    failed+=("$name")
    continue
  fi

  tmp="$(mktemp -d "${TMPDIR:-/tmp}/claude-multi-test.XXXXXX")"
  mkdir -p -- "$tmp/home"
  out="$tmp/output"

  if (
    set -euo pipefail
    export HOME="$tmp/home"
    export CLAUDE_MULTI_ROOT="$tmp/home/.claude-multi"
    export REPO_ROOT
    export TEST_TMP="$tmp"
    export REAL_HOME_GUARD="$real_home"
    unset CLAUDE_CONFIG_DIR
    cd -- "$tmp"
    bash -- "$path"
  ) >"$out" 2>&1; then
    printf 'ok    %s\n' "$name" >&2
    passed=$((passed + 1))
  else
    printf 'FAIL  %s\n' "$name" >&2
    sed 's/^/      /' "$out" >&2
    failed+=("$name")
  fi

  # Composed from mktemp output, but check the shape before rm -rf anyway.
  case "$tmp" in
    */claude-multi-test.*) rm -rf -- "$tmp" ;;
    *) printf 'refusing to remove unexpected temp dir: %s\n' "$tmp" >&2 ;;
  esac
done

printf '\n%d passed, %d failed\n' "$passed" "${#failed[@]}" >&2
if ((${#failed[@]} > 0)); then
  printf 'failed: %s\n' "${failed[*]}" >&2
  exit 1
fi
