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

test_install_refuses_non_symlink() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  printf 'i am somebody elses script\n' > "$h/.local/bin/claude-multi"
  run_install "$h"
  assert_eq "1" "$rc" "non-symlink at target refuses with exit 1"
  assert_contains "$ERR" "not a symlink" "refusal explains it is not a symlink"
  assert_eq "i am somebody elses script" "$(cat "$h/.local/bin/claude-multi")" \
    "the existing regular file is left byte-identical"
  rm -rf -- "$h"
}

test_install_refuses_non_symlink_even_with_force() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  printf 'precious\n' > "$h/.local/bin/claude-multi"
  run_install "$h" --force
  assert_eq "1" "$rc" "--force does not override a regular file"
  assert_eq "precious" "$(cat "$h/.local/bin/claude-multi")" "regular file survives --force"
  rm -rf -- "$h"
}

test_install_refuses_foreign_symlink_without_force() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$h/other-tool"
  ln -s -- "$h/other-tool" "$h/.local/bin/claude-multi"
  run_install "$h"
  assert_eq "1" "$rc" "foreign symlink refuses with exit 1"
  assert_contains "$ERR" "--force" "refusal names the --force escape hatch"
  assert_link "$h/.local/bin/claude-multi" "$h/other-tool" "foreign link is untouched"
  rm -rf -- "$h"
}

test_install_force_replaces_foreign_symlink() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$h/other-tool"
  ln -s -- "$h/other-tool" "$h/.local/bin/claude-multi"
  run_install "$h" --force
  assert_eq "0" "$rc" "--force exits 0"
  assert_link "$h/.local/bin/claude-multi" "$src" "--force repoints the link at our bin"
  rm -rf -- "$h"
}

test_install_replaces_dangling_symlink_only_with_force() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  ln -s -- "$h/gone-forever" "$h/.local/bin/claude-multi"
  run_install "$h"
  assert_eq "1" "$rc" "dangling foreign link refuses without --force"
  run_install "$h" --force
  assert_eq "0" "$rc" "dangling foreign link yields to --force"
  assert_link "$h/.local/bin/claude-multi" "$src" "link now points at our bin"
  rm -rf -- "$h"
}

test_install_never_edits_a_profile() {
  local h; h="$(new_home)"
  local before after
  before="$(cd -- "$h" && cksum .bashrc .profile .bash_profile .zshrc)"
  run_install "$h"
  assert_eq "0" "$rc" "install exits 0"
  after="$(cd -- "$h" && cksum .bashrc .profile .bash_profile .zshrc)"
  assert_eq "$before" "$after" "no profile file is modified by install"
  [[ -e "$h/.zprofile" || -e "$h/.bash_login" ]] && \
    { printf 'install created a profile file\n' >&2; return 1; }
  rm -rf -- "$h"
}

test_install_writes_nothing_outside_local_bin() {
  local h; h="$(new_home)"
  local before after
  before="$(cd -- "$h" && find . -mindepth 1 | LC_ALL=C sort)"
  run_install "$h"
  after="$(cd -- "$h" && find . -mindepth 1 | LC_ALL=C sort)"
  assert_eq "$(printf '%s\n./.local\n./.local/bin\n./.local/bin/claude-multi' "$before" | LC_ALL=C sort)" \
            "$after" \
            "install adds exactly .local, .local/bin and the link"
  rm -rf -- "$h"
}

test_uninstall_removes_our_link() {
  local h; h="$(new_home)"
  run_install "$h"
  assert_eq "0" "$rc" "install exits 0"
  run_install "$h" --uninstall
  assert_eq "0" "$rc" "uninstall exits 0"
  [[ -e "$h/.local/bin/claude-multi" || -L "$h/.local/bin/claude-multi" ]] && \
    { printf 'uninstall left the link behind\n' >&2; return 1; }
  assert_contains "$ERR" "removed" "uninstall reports removal on stderr"
  [[ -d "$h/.local/bin" ]] || { printf 'uninstall removed the bin dir too\n' >&2; return 1; }
  rm -rf -- "$h"
}

test_uninstall_is_idempotent() {
  local h; h="$(new_home)"
  run_install "$h"
  run_install "$h" --uninstall
  assert_eq "0" "$rc" "first uninstall exits 0"
  run_install "$h" --uninstall
  assert_eq "0" "$rc" "second uninstall exits 0"
  assert_contains "$ERR" "nothing to uninstall" "second uninstall says nothing to do"
  rm -rf -- "$h"
}

test_uninstall_refuses_foreign_symlink() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$h/other-tool"
  ln -s -- "$h/other-tool" "$h/.local/bin/claude-multi"
  run_install "$h" --uninstall
  assert_eq "1" "$rc" "foreign link is not ours to remove"
  assert_link "$h/.local/bin/claude-multi" "$h/other-tool" "foreign link survives uninstall"
  rm -rf -- "$h"
}

test_uninstall_refuses_regular_file() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  printf 'not mine\n' > "$h/.local/bin/claude-multi"
  run_install "$h" --uninstall
  assert_eq "1" "$rc" "regular file is not ours to remove"
  assert_eq "not mine" "$(cat "$h/.local/bin/claude-multi")" "regular file survives uninstall"
  rm -rf -- "$h"
}

test_uninstall_force_still_refuses_foreign_link() {
  local h; h="$(new_home)"
  mkdir -p -- "$h/.local/bin"
  printf '#!/bin/sh\nexit 0\n' > "$h/other-tool"
  ln -s -- "$h/other-tool" "$h/.local/bin/claude-multi"
  run_install "$h" --uninstall --force
  assert_eq "1" "$rc" "--force does not widen uninstall ownership"
  assert_link "$h/.local/bin/claude-multi" "$h/other-tool" "foreign link survives --uninstall --force"
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
