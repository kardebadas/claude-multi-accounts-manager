#!/usr/bin/env bash
# Install-script behaviour. Each case gets its own throwaway HOME.
#
# `set -euo pipefail` here, and again inside each case's subshell at the bottom
# of the file. Without `-e` a failing assertion only prints "  FAIL: …" and
# returns 1; execution continues, the function's status becomes that of its
# final `rm -rf -- "$h"` cleanup line, the file exits 0, and tests/run.sh
# prints `ok` while discarding the captured FAIL line. `-e` plus the
# accumulator at the bottom is what makes a failure here actually fail.
set -euo pipefail

repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
. "$repo/tests/assert.sh"

src="$repo/bin/claude-multi"

# new_home: a throwaway HOME with the profiles a careless installer would edit.
new_home() {
  local h
  h="$(mktemp -d "${TMPDIR:-/tmp}/cm-install-home.XXXXXX")"
  printf 'original bashrc\n'      > "$h/.bashrc"
  printf 'original profile\n'     > "$h/.profile"
  printf 'original bash_profile\n'> "$h/.bash_profile"
  printf 'original zshrc\n'       > "$h/.zshrc"
  printf '%s' "$h"
}

# run_install HOMEDIR [args...] -> sets rc, OUT (stdout), ERR (stderr)
run_install() {
  local h="$1"; shift
  local o e
  o="$(mktemp)"; e="$(mktemp)"
  rc=0
  HOME="$h" bash "$repo/install.sh" "$@" >"$o" 2>"$e" || rc=$?
  OUT="$(cat "$o")"; ERR="$(cat "$e")"
  rm -f -- "$o" "$e"
}

test_install_creates_link() {
  local h; h="$(new_home)"
  run_install "$h"
  assert_eq "0" "$rc" "fresh install exits 0"
  assert_link "$h/.local/bin/claude-multi" "$src"
  rm -rf -- "$h"
}

test_install_creates_bin_dir_when_absent() {
  local h; h="$(new_home)"
  [[ -d "$h/.local/bin" ]] && { printf 'precondition failed: bin dir pre-exists\n' >&2; return 1; }
  run_install "$h"
  assert_eq "0" "$rc" "install exits 0 with no ~/.local/bin"
  [[ -d "$h/.local/bin" ]] || { printf 'install did not create ~/.local/bin\n' >&2; return 1; }
  rm -rf -- "$h"
}

test_install_is_idempotent() {
  local h; h="$(new_home)"
  run_install "$h"
  assert_eq "0" "$rc" "first install exits 0"
  run_install "$h"
  assert_eq "0" "$rc" "second install exits 0"
  assert_contains "$ERR" "already installed" "re-run reports already installed"
  assert_link "$h/.local/bin/claude-multi" "$src"
  rm -rf -- "$h"
}

test_install_prints_only_to_stderr() {
  local h; h="$(new_home)"
  run_install "$h"
  assert_eq "" "$OUT" "install writes nothing to stdout"
  assert_contains "$ERR" "claude-multi" "install reports the result on stderr"
  rm -rf -- "$h"
}

test_install_rejects_unknown_option() {
  local h; h="$(new_home)"
  run_install "$h" --nope
  assert_eq "2" "$rc" "unknown option exits 2"
  assert_contains "$ERR" "unknown option" "unknown option is named on stderr"
  [[ -e "$h/.local/bin/claude-multi" ]] && { printf 'usage error still installed\n' >&2; return 1; }
  rm -rf -- "$h"
}

# ── run every test this file defines ────────────────────────────────────────
# Auto-discovery rather than a hand-maintained list, so a case appended by a
# later task cannot be silently unregistered. Each case runs in its own
# subshell under `set -euo pipefail`, so the first failing assertion aborts
# that case (and only that case) with a non-zero status. `status` accumulates:
# ONE failure fails the file, no matter which case it was — the bug the
# pre-flight scan filed as C14.
#
# A failing case skips its own `rm -rf -- "$h"` cleanup and leaves its
# throwaway HOME under $TMPDIR on purpose: that directory is the evidence.
# Task 7 Step 4's leftover check therefore applies to a green run only.
status=0
while IFS= read -r fn; do
  set +e
  ( set -euo pipefail; "$fn" )
  fn_status=$?
  set -e
  if (( fn_status == 0 )); then
    printf 'ok   %s\n' "$fn" >&2
  else
    status=1
    printf 'FAIL %s\n' "$fn" >&2
  fi
done < <(declare -F | awk '{print $3}' | grep '^test_' | LC_ALL=C sort)

exit "$status"
