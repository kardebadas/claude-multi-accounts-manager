# shellcheck shell=bash
# tests/test_precommit_hook.sh — the guard is only useful if git actually runs it.
#
# scripts/check-no-secrets.sh is the second gate over the staged index. Nothing
# calls it on its own, so `--install-hook` wires it into `.git/hooks/pre-commit`.
# This suite pins that installation: what it writes, that re-running it changes
# nothing, that it will not overwrite a hook it did not write, that it never
# writes outside the target repository's hooks directory, and — end to end —
# that a real `git commit` of a forbidden path is refused.
#
# Invoked as `bash tests/test_precommit_hook.sh` (by tests/run.sh, or by hand)
# with REPO_ROOT and TEST_TMP exported. Not executable and no shebang, matching
# tests/assert.sh and the other tests/test_*.sh files.
#
# FOUR RULES THIS FILE MUST FOLLOW, all of which are about this file itself:
#
#  1. Never write a literal offending string into this file. The guard runs as
#     a pre-commit hook over the whole staged tree, this file included, so a
#     hard-coded absolute home path or key prefix here would make the hook
#     refuse its own test suite. Every offending name and body below is
#     assembled at runtime with printf.
#  2. Never install a hook into the real repository, and never stage anything
#     in it. Every installation happens in a throwaway `git init` repo under
#     $TEST_TMP. This matters more here than anywhere else in the suite: in a
#     linked worktree `.git/hooks` is SHARED with the main checkout, so an
#     installation "into this worktree" is an installation into the main repo.
#  3. Never `git add -A`. Where a test has to stage something it names the
#     paths, and where it has to clear the index it clears the INDEX
#     (`git rm --cached` / `git reset`) and then asserts the index is empty —
#     `rm` on the working file does not unstage anything.
#  4. No `if ! ( … )` around a test body, and no pipeline whose failure can go
#     unnoticed. Both hazards are explained where the dispatch sets errexit
#     aside at the bottom of the file, and the first is pinned by
#     t_dispatch_records_an_early_failure.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"

guard="$REPO_ROOT/scripts/check-no-secrets.sh"

# ── fixtures assembled at runtime (rule 1) ───────────────────────────────────
# A credential file name and an absolute-home-path line, neither of which
# appears as a committed literal anywhere in this file.
cred_name() { printf '.%s.json' "credentials"; }
home_leak_line() { printf '# see /%s/%s/.claude\n' "home" "someuser"; }

# ── throwaway repositories ───────────────────────────────────────────────────
# new_repo — a fresh repo with the guard copied in, cd'd into. Echoes nothing:
# the code under test is the only thing allowed to talk.
new_repo() {
  local repo
  repo="$(mktemp -d "$TEST_TMP/repo.XXXXXX")"
  mkdir -p -- "$repo/scripts" "$repo/lib" "$repo/tests"
  cp -- "$guard" "$repo/scripts/check-no-secrets.sh"
  git -C "$repo" init -q -b main
  cd -- "$repo"
}

# install [args…] — the installer, stdout and stderr left alone for the caller.
install() { bash scripts/check-no-secrets.sh --install-hook "$@"; }

# install_err [args…] — the installer's stderr, with stdout DROPPED so a leak
# into stdout can never be mistaken for a diagnostic.
install_err() { bash scripts/check-no-secrets.sh --install-hook "$@" 2>&1 >/dev/null || true; }

# hook_path — where git will look for the pre-commit hook in the current repo,
# absolute. `--git-path` answers relative in an ordinary repo and absolute in a
# linked worktree, so both are normalised here rather than at each call site.
# This deliberately does NOT consult core.hooksPath: the tests that redirect
# hooks name the redirected path themselves, so this helper stays the
# independent answer rather than a second copy of the code under test.
hook_path() {
  local d
  d="$(git rev-parse --git-path hooks)"
  case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
  printf '%s/pre-commit\n' "$d"
}

# commit — a commit in a throwaway repo. The identity is supplied per-invocation
# and is deliberately not an address: this repository forbids email addresses in
# committed file contents, and git accepts any non-empty ident string.
commit() { git -c user.name=t -c user.email=t commit -q -m "$1"; }

# commit_err <message> — the same commit, its stderr captured and its status
# discarded, for asserting on what a REFUSED commit actually told the user.
commit_err() { git -c user.name=t -c user.email=t commit -q -m "$1" 2>&1 >/dev/null || true; }

# ── installing ───────────────────────────────────────────────────────────────
t_install_writes_an_executable_hook_that_runs_the_guard() {
  new_repo
  local hook
  hook="$(hook_path)"
  assert_eq "" "$([[ -e "$hook" ]] && printf 'exists')" \
    "git init must not have left a pre-commit hook behind"

  install
  if [[ ! -f "$hook" ]]; then
    printf '  FAIL: %s is not a regular file after --install-hook\n' "$hook" >&2
    return 1
  fi
  if [[ ! -x "$hook" ]]; then
    printf '  FAIL: %s is not executable\n' "$hook" >&2
    return 1
  fi
  assert_contains "$(cat -- "$hook")" "check-no-secrets.sh" \
    "the hook must invoke the guard"
  assert_contains "$(cat -- "$hook")" "Do not edit" \
    "the hook must say where it came from"
}

t_install_reports_on_stderr_and_never_on_stdout() {
  new_repo
  assert_contains "$(install_err)" "hook" \
    "the installer must say what it did, on stderr"
  assert_contains "$(install_err)" "$(hook_path)" \
    "the diagnostic must name the hook it wrote"
  # Both stdout assertions: one reports what leaked, one is byte-exact.
  assert_no_stdout bash scripts/check-no-secrets.sh --install-hook
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh --install-hook
}

t_install_is_idempotent() {
  new_repo
  local hook before
  hook="$(hook_path)"
  install
  before="$(cat -- "$hook")"
  install
  install
  assert_eq "$before" "$(cat -- "$hook")" "re-installing must not change the hook"
  if [[ ! -x "$hook" ]]; then
    printf '  FAIL: %s lost its executable bit on re-install\n' "$hook" >&2
    return 1
  fi
}

# The installer is a setup action on .git, which is not tracked. It must leave
# the worktree alone entirely, and add exactly ONE entry to the git directory.
t_install_touches_nothing_outside_the_hooks_directory() {
  new_repo
  local work_before work_after git_before git_after hook rel
  hook="$(hook_path)"
  rel="${hook#"$PWD"/}"
  rel="${rel#./}"
  work_before="$(find . -mindepth 1 -not -path './.git' -not -path './.git/*' | sort)"
  git_before="$(find .git -mindepth 1 | sort)"
  install
  work_after="$(find . -mindepth 1 -not -path './.git' -not -path './.git/*' | sort)"
  git_after="$(find .git -mindepth 1 | sort)"
  assert_eq "$work_before" "$work_after" "the installer must not touch the worktree"
  # awk, not grep: a zero-match grep exits 1 and would abort this pipeline
  # under pipefail with no diagnostic at all (hazard 2).
  assert_eq "$git_before" \
    "$(printf '%s\n' "$git_after" | awk -v skip="$rel" '$0 != skip')" \
    "the only new entry under .git must be the pre-commit hook"
}

# ── the installed hook actually refuses ──────────────────────────────────────
# Run the hook the way git runs it: as a program, from the worktree root.
t_the_installed_hook_refuses_a_planted_credential() {
  new_repo
  install
  local hook out cred
  hook="$(hook_path)"
  cred="tests/$(cred_name)"
  printf '{"t":"x"}\n' >"$cred"
  git add -f -- "$cred"

  assert_fails "$hook"
  out="$("$hook" 2>&1 >/dev/null || true)"
  assert_contains "$out" "REFUSED" "the hook must say REFUSED"
  assert_contains "$out" "$cred" "the refusal must name the offending path"
  assert_contains "$out" "rule:" "the refusal must name the rule"
  assert_stdout_empty_bytes "$hook"

  # Clearing the INDEX, not the working file: `rm` does not unstage.
  git rm -q --cached -- "$cred" >/dev/null
  rm -f -- "$cred"
  assert_eq "" "$(git diff --cached --name-only)" "the test must leave the index clean"
}

t_the_installed_hook_passes_a_clean_index() {
  new_repo
  install
  local hook
  hook="$(hook_path)"
  printf 'echo ok\n' >lib/ok.sh
  git add -- lib/ok.sh
  "$hook"
  assert_stdout_empty_bytes "$hook"
}

# ── end to end: git itself must refuse the commit ────────────────────────────
# The hook is only worth installing if `git commit` honours it. This is the one
# test that proves the whole chain rather than each link.
t_git_commit_is_blocked_by_the_installed_hook() {
  new_repo
  install
  local out cred
  cred="tests/$(cred_name)"
  printf '{"t":"x"}\n' >"$cred"
  git add -f -- "$cred"

  assert_fails commit "should never land"
  out="$(commit_err "should never land")"
  assert_contains "$out" "REFUSED" "git commit must surface the guard's refusal"
  assert_contains "$out" "$cred" "the blocked commit must name the offending path"
  assert_eq "" "$(git log --oneline 2>/dev/null || true)" \
    "no commit may exist after a blocked commit"

  # A leak in the CONTENT of an otherwise fine path is blocked the same way.
  git rm -q --cached -- "$cred" >/dev/null
  rm -f -- "$cred"
  home_leak_line >lib/leak.sh
  git add -- lib/leak.sh
  assert_fails commit "also never lands"
  assert_contains "$(commit_err "also never lands")" "lib/leak.sh" \
    "a content leak must be named too"
  git rm -q --cached -- lib/leak.sh >/dev/null
  rm -f -- lib/leak.sh
  assert_eq "" "$(git diff --cached --name-only)" "the index must be clean again"

  # And a legitimate commit goes through, so the hook is a gate and not a wall.
  printf 'echo ok\n' >lib/ok.sh
  git add -- lib/ok.sh
  commit "feat: a legitimate commit"
  assert_eq "lib/ok.sh" "$(git show --name-only --format= HEAD | tr -d '\n')" \
    "the legitimate commit must contain exactly the legitimate file"
}

# ── it will not clobber someone else's hook ──────────────────────────────────
t_install_refuses_to_clobber_a_foreign_hook() {
  new_repo
  local hook out
  hook="$(hook_path)"
  mkdir -p -- "$(dirname -- "$hook")"
  printf '#!/bin/sh\necho other\n' >"$hook"
  chmod +x -- "$hook"

  assert_fails install
  out="$(install_err)"
  assert_contains "$out" "not clobbering" "the refusal must say it is not clobbering"
  assert_contains "$out" "$hook" "the refusal must name the hook it left alone"
  assert_contains "$(cat -- "$hook")" "echo other" \
    "the foreign hook must be left byte-for-byte alone"
  assert_no_stdout bash scripts/check-no-secrets.sh --install-hook
}

t_force_replaces_a_foreign_hook() {
  new_repo
  local hook
  hook="$(hook_path)"
  mkdir -p -- "$(dirname -- "$hook")"
  printf '#!/bin/sh\necho other\n' >"$hook"
  chmod +x -- "$hook"

  install --force
  assert_contains "$(cat -- "$hook")" "check-no-secrets.sh" \
    "--force must install our hook"
  assert_eq "" "$(printf '%s\n' "$(cat -- "$hook")" | awk '/echo other/ { print "found" }')" \
    "--force must not leave the foreign hook's body behind"
  if [[ ! -x "$hook" ]]; then
    printf '  FAIL: %s is not executable after --force\n' "$hook" >&2
    return 1
  fi
}

# A symlinked pre-commit hook is the sharp edge: `cat >"$hook"` follows it and
# writes wherever it points, which may be anywhere on the filesystem. The
# installer must never do that.
t_install_refuses_a_symlinked_hook() {
  new_repo
  local hook outside
  hook="$(hook_path)"
  outside="$(mktemp -d "$TEST_TMP/outside.XXXXXX")"
  printf 'ORIGINAL\n' >"$outside/target"
  mkdir -p -- "$(dirname -- "$hook")"
  ln -s -- "$outside/target" "$hook"

  assert_fails install
  assert_contains "$(install_err)" "symlink" "the refusal must name the cause"
  assert_eq "ORIGINAL" "$(cat -- "$outside/target")" \
    "the installer must not write through a symlink"

  # Even --force must replace the LINK, never the file it points at.
  install --force
  assert_eq "ORIGINAL" "$(cat -- "$outside/target")" \
    "--force must not write through a symlink either"
  if [[ -L "$hook" ]]; then
    printf '  FAIL: %s is still a symlink after --force\n' "$hook" >&2
    return 1
  fi
  assert_contains "$(cat -- "$hook")" "check-no-secrets.sh" \
    "--force must leave a real hook in place of the link"
}

# ── core.hooksPath ───────────────────────────────────────────────────────────
# If the repo redirects its hooks, installing into .git/hooks would leave a
# file git never runs — a hook that exists and does nothing is worse than none.
t_install_honours_a_hookspath_inside_the_repo() {
  new_repo
  git config core.hooksPath .githooks
  install
  if [[ ! -x .githooks/pre-commit ]]; then
    printf '  FAIL: no executable hook at .githooks/pre-commit\n' >&2
    return 1
  fi
  assert_eq "" "$([[ -e .git/hooks/pre-commit ]] && printf 'exists')" \
    "nothing may be written to .git/hooks when hooks are redirected"
  # The payoff: git must actually run it.
  local cred
  cred="tests/$(cred_name)"
  printf '{"t":"x"}\n' >"$cred"
  git add -f -- "$cred"
  assert_fails commit "should never land"
  assert_contains "$(commit_err "should never land")" "REFUSED" \
    "the redirected hook must be the one git runs"
}

t_install_refuses_a_hookspath_outside_the_repo() {
  new_repo
  local outside out
  outside="$(mktemp -d "$TEST_TMP/outside.XXXXXX")"
  git config core.hooksPath "$outside"
  assert_fails install
  out="$(install_err)"
  assert_contains "$out" "core.hooksPath" "the refusal must name the setting"
  assert_eq "" "$(find "$outside" -mindepth 1)" \
    "nothing may be written outside the repository"
  # --force is an override for a foreign HOOK, not a licence to escape the repo.
  assert_fails install --force
  assert_eq "" "$(find "$outside" -mindepth 1)" \
    "--force must not write outside the repository either"
}

# ── invocation errors ────────────────────────────────────────────────────────
t_install_outside_a_repository_is_explained() {
  local bare
  bare="$(mktemp -d "$TEST_TMP/bare.XXXXXX")"
  cp -- "$guard" "$bare/check-no-secrets.sh"
  cd -- "$bare"
  # If the host TMPDIR ever sat inside a repo this test would be meaningless,
  # so it opts out by assertion-free return rather than asserting nonsense.
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    return 0
  fi
  assert_fails bash ./check-no-secrets.sh --install-hook
  local out
  out="$(bash ./check-no-secrets.sh --install-hook 2>&1 >/dev/null || true)"
  assert_contains "$out" "git repository" "the diagnostic must name the cause"
  assert_no_stdout bash ./check-no-secrets.sh --install-hook
}

t_install_rejects_an_unknown_extra_argument() {
  new_repo
  local out
  assert_fails install --bogus
  out="$(install_err --bogus)"
  assert_contains "$out" "unknown argument" "an unknown argument must be explained"
  assert_eq "" "$([[ -e "$(hook_path)" ]] && printf 'exists')" \
    "a rejected invocation must not have installed anything"
  assert_no_stdout bash scripts/check-no-secrets.sh --install-hook --bogus
  # And the plain check still refuses a junk first argument.
  assert_fails bash scripts/check-no-secrets.sh --bogus
}

# ── the dispatch below has teeth ─────────────────────────────────────────────
# Hazard 1, measured in this project rather than assumed: bash suppresses
# errexit for everything run inside an `if` condition, and the suppression
# survives both a subshell and an explicit `set -e` inside it. A test written
# as `if ! ( set -e; "$fn" ); then …` therefore keeps executing past its first
# failed assertion and is recorded as a PASS.
#
# This test runs a probe that fails an assertion and then would do more work,
# through the exact construct the dispatch uses, and requires that (a) the
# status is non-zero and (b) the work after the failure never happened.
_probe_fails_early_then_would_pass() {
  printf 'phase-1\n' >>"$TEST_TMP/probe.log"
  assert_eq "expected" "actual" "the probe is supposed to fail right here"
  printf 'phase-2\n' >>"$TEST_TMP/probe.log"
}

t_dispatch_records_an_early_failure() {
  local rc=0
  rm -f -- "$TEST_TMP/probe.log"
  set +e
  ( set -euo pipefail; _probe_fails_early_then_would_pass ) 2>/dev/null
  rc=$?
  set -e
  assert_eq "1" "$rc" "an early assertion failure must surface as a non-zero status"
  assert_eq "phase-1" "$(cat -- "$TEST_TMP/probe.log")" \
    "execution must stop AT the failing assertion — phase-2 must never run"
  rm -f -- "$TEST_TMP/probe.log"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
# Every t_* function defined above runs, in its own subshell so one failure
# cannot abort the rest and so a test's `cd` cannot leak into the next. Zero
# discovered tests is a loud failure, not a silent pass.
#
# Two deliberate choices, both hazards this project has already been bitten by:
#   * the subshell is run as a PLAIN COMMAND with errexit temporarily off, not
#     as `if ! ( … )` — see t_dispatch_records_an_early_failure above.
#   * discovery uses awk alone, with no grep in the pipeline. A zero-match
#     `grep` exits 1, which under pipefail kills the enclosing construct with
#     no diagnostic; the reader just sees fewer tests run. awk exits 0 whether
#     it matches or not, so the "no tests discovered" check below is the only
#     thing that can report an empty set — and it reports it loudly.
declare -a discovered=()
while IFS= read -r fn; do
  discovered+=("$fn")
done < <(declare -F | awk '$3 ~ /^t_/ { print $3 }' | sort)

if ((${#discovered[@]} == 0)); then
  printf '  FAIL: no t_* test functions discovered in %s\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

failures=0
for fn in "${discovered[@]}"; do
  set +e
  ( set -euo pipefail; cd -- "$TEST_TMP" && "$fn" )
  rc=$?
  set -e
  if ((rc != 0)); then
    printf '  FAIL: %s (exit %d)\n' "$fn" "$rc" >&2
    failures=$((failures + 1))
  fi
done

printf '  %d test(s), %d failed\n' "${#discovered[@]}" "$failures" >&2
((failures == 0)) || exit 1
