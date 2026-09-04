# shellcheck shell=bash
# tests/test_check_no_secrets.sh — the second gate's contract.
#
# .gitignore is deny-by-default, but `git add -f` walks straight past it. This
# suite pins what scripts/check-no-secrets.sh refuses, what it must NOT refuse,
# and that it never writes to stdout.
#
# Invoked as `bash tests/test_check_no_secrets.sh` (by tests/run.sh, or by hand)
# with REPO_ROOT exported. Not executable and no shebang, matching
# tests/assert.sh, tests/test_assert.sh and tests/test_runner.sh.
#
# TWO RULES THIS FILE MUST FOLLOW, both of which are about this file itself:
#
#  1. Never write a literal offending string into this file. The guard is meant
#     to run as a pre-commit hook over the whole staged tree, this file
#     included, so a hard-coded absolute home path or key prefix here would make
#     the hook refuse its own test suite. Every offending string below is
#     assembled at runtime with printf, so the committed literal is `/home/%s/`
#     or "sk" "-ant-", which no pattern can match.
#  2. Never stage anything in the real repository. Everything happens in
#     throwaway `git init` repos under $TEST_TMP; the real checkout is only ever
#     read (`git ls-files`), never written and never staged.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"

guard="$REPO_ROOT/scripts/check-no-secrets.sh"

# A name that looks like a real account but belongs to nobody. Built into paths
# at runtime, never committed next to a leading /home/.
fake_user="someuser"

# new_repo — a fresh throwaway repo with the guard copied in, cd'd into.
# Echoes nothing: the guard under test is the only thing allowed to talk.
new_repo() {
  local repo
  repo="$(mktemp -d "$TEST_TMP/repo.XXXXXX")"
  mkdir -p -- "$repo/scripts" "$repo/lib" "$repo/tests" "$repo/bin"
  cp -- "$guard" "$repo/scripts/check-no-secrets.sh"
  git -C "$repo" init -q -b main
  cd -- "$repo"
}

# check — the guard must accept the current index.
check() {
  bash scripts/check-no-secrets.sh
}

# refusal — the guard's stderr, with stdout dropped so a leak cannot hide in it.
refusal() {
  bash scripts/check-no-secrets.sh 2>&1 >/dev/null || true
}

# expect_refused <relative path> [needle …] — stage <path> with -f, require a
# refusal that names it, then leave the index clean again.
expect_refused() {
  local p="$1"
  shift
  mkdir -p -- "$(dirname -- "$p")"
  printf 'x\n' >"$p"
  git add -f -- "$p"
  if bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
    printf '  FAIL: the guard accepted %s\n' "$p" >&2
    git reset -q
    return 1
  fi
  local out
  out="$(refusal)"
  assert_contains "$out" "$p" "the refusal must name the offending path"
  assert_contains "$out" "REFUSED" "the refusal must say REFUSED"
  local needle
  for needle in "$@"; do
    assert_contains "$out" "$needle" "the refusal must name the rule"
  done
  assert_no_stdout bash scripts/check-no-secrets.sh
  git rm -q --cached -- "$p" >/dev/null 2>&1 || git reset -q
  git reset -q
  assert_eq "" "$(git diff --cached --name-only)" "the test must leave the index clean"
  rm -f -- "$p"
}

# ── the guard exists, and is executable ──────────────────────────────────────
t_guard_is_executable() {
  if [[ ! -x "$guard" ]]; then
    printf '  FAIL: %s is not executable\n' "$guard" >&2
    return 1
  fi
}

# ── an empty index passes, silently ──────────────────────────────────────────
t_empty_index_passes() {
  new_repo
  check
  assert_no_stdout bash scripts/check-no-secrets.sh
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
}

# ── ordinary tooling passes ──────────────────────────────────────────────────
t_ordinary_tooling_passes() {
  new_repo
  printf 'echo hi\n' >lib/ok.sh
  printf 'root="$HOME/.claude-multi"\n' >lib/paths.sh
  printf 'cfg="${XDG_CONFIG_HOME:-$HOME/.config}"\n' >lib/cfg.sh
  git add -f -- lib/ok.sh lib/paths.sh lib/cfg.sh
  check
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
}

# ── the guard must not refuse itself, or this test suite ─────────────────────
# The guard's own source spells out the roots as /(home|Users)/ and the key
# prefix as sk-a[n]t-, which is exactly the property this asserts: the patterns
# must not match the file that defines them.
#
# This file is staged too, and that half is not decoration. The guard is meant
# to run as a pre-commit hook over the whole staged tree, so a single literal
# offending string in this file would make the hook refuse its own test suite —
# which is precisely what happened twice during development: an earlier draft
# hard-coded one absolute-root fixture, and then the comment explaining that
# mistake hard-coded it again. Both were invisible to the suite until this test
# existed. Staging both files here is the lock; prose counts as content.
t_guard_does_not_refuse_itself_or_its_tests() {
  new_repo
  cp -- "$REPO_ROOT/tests/test_check_no_secrets.sh" tests/test_check_no_secrets.sh
  git add -f -- scripts/check-no-secrets.sh tests/test_check_no_secrets.sh
  check
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
}

# ── the whole real tracked tree passes: zero false positives ─────────────────
# Two legitimate near-misses live in the checkout and both must survive:
# CLAUDE.md documents the forbidden shape as /home/<username>/..., and
# tests/run.sh builds a temp path whose middle segment is /home/. The real repo
# is only read here — the mirror is a throwaway repo, and the staging happens
# there.
t_real_tracked_tree_passes() {
  new_repo
  local mirror f
  local -a paths=()
  mirror="$(mktemp -d "$TEST_TMP/mirror.XXXXXX")"
  while IFS= read -r -d '' f; do
    mkdir -p -- "$(dirname -- "$mirror/$f")"
    cp -- "$REPO_ROOT/$f" "$mirror/$f"
    paths+=("$f")
  done < <(git -C "$REPO_ROOT" ls-files -z)
  if ((${#paths[@]} == 0)); then
    printf '  FAIL: no tracked files found in %s\n' "$REPO_ROOT" >&2
    return 1
  fi
  git -C "$mirror" init -q -b main
  git -C "$mirror" add -f -- "${paths[@]}"
  cd -- "$mirror"
  if ! bash "$guard"; then
    printf '  FAIL: the guard refuses the repo own tracked set:\n%s\n' \
      "$(bash "$guard" 2>&1 >/dev/null || true)" >&2
    return 1
  fi
  assert_stdout_empty_bytes bash "$guard"
}

# ── credentials, even forced past .gitignore ─────────────────────────────────
t_refuses_credentials() {
  new_repo
  expect_refused "tests/.credentials.json" "credential"
  expect_refused "bin/acct.credentials.json" "credential"
  expect_refused "bin/.claude.json" "account state"
}

# ── archives, logs, captured output, env files, history ──────────────────────
t_refuses_archives_logs_and_env() {
  new_repo
  expect_refused "lib/backup.tgz" "archive"
  expect_refused "lib/backup.tar.gz" "archive"
  expect_refused "lib/backup.tar" "archive"
  expect_refused "lib/backup.zip" "archive"
  expect_refused "scripts/run.log" "captured output"
  expect_refused "scripts/capture.out" "captured output"
  expect_refused "lib/.env" "environment file"
  expect_refused "lib/.env.local" "environment file"
  expect_refused "tests/history.jsonl" "prompt history"
  expect_refused "tests/tmp/scratch" "scratch"
}

# ── real config trees ────────────────────────────────────────────────────────
t_refuses_real_config_trees() {
  new_repo
  expect_refused "lib/.claude/CLAUDE.md" "Claude config tree"
  expect_refused "lib/.claude-multi/accounts" "claude-multi root"
  expect_refused "lib/shared/CLAUDE.md" "shared config"
  expect_refused "lib/.trash/acct-1.txt" "delete-path backup"
  expect_refused "lib/agent-memory/MEMORY.md" "memory"
  expect_refused "lib/project-memory/slug/notes.md" "memory"
  expect_refused "docs/superpowers/specs/leak.md" "pipeline state"
}

# ── F-001: settings.json and projects/* were covered by nothing ──────────────
# CLAUDE.md names both as never-commit, but no ignore rule and no path rule
# covered them. This test is the lock on that gap staying closed.
t_refuses_settings_and_projects() {
  new_repo
  expect_refused "settings.json" "settings"
  expect_refused "lib/settings.json" "settings"
  expect_refused "lib/settings.local.json" "settings"
  expect_refused "projects/slug/transcript.md" "transcript"
  expect_refused "lib/projects/slug/transcript.md" "transcript"
}

# ── content: an absolute home path, in all four shapes ───────────────────────
t_refuses_absolute_home_paths() {
  new_repo
  local shape
  # Assembled at runtime; the committed literals are /home/%s, /Users/%s, …
  for shape in \
    "$(printf '/home/%s/.claude/settings.json' "$fake_user")" \
    "$(printf '/Users/%s/.claude' "$fake_user")" \
    "$(printf '/export/home/%s/.claude' "$fake_user")" \
    "$(printf '/%s/.claude-multi' "root")"
  do
    printf '# see %s\n' "$shape" >lib/leak.sh
    git add -f -- lib/leak.sh
    if bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
      printf '  FAIL: the guard accepted an absolute home path\n' >&2
      git reset -q
      return 1
    fi
    local out
    out="$(refusal)"
    assert_contains "$out" "lib/leak.sh" "the refusal must name the file"
    assert_contains "$out" "absolute home path" "the refusal must name the rule"
    assert_no_stdout bash scripts/check-no-secrets.sh
    git reset -q
    rm -f -- lib/leak.sh
  done
  # A quoted path is the classic leak shape and must still be caught.
  printf 'cfg="%s/settings.json"\n' "$(printf '/home/%s/.claude' "$fake_user")" >lib/leak.sh
  git add -f -- lib/leak.sh
  assert_fails bash scripts/check-no-secrets.sh
  git reset -q
  rm -f -- lib/leak.sh
}

# ── content: the two legitimate near-misses, in isolation ────────────────────
t_allows_home_placeholder_and_midpath() {
  new_repo
  # The placeholder is the text of the rule itself — CLAUDE.md contains it.
  printf 'never write /home/<username>/... — use $HOME or ~\n' >lib/doc.sh
  # /home/ in the MIDDLE of a path is a temp path, not a real home.
  # tests/run.sh genuinely contains "$tmp/home/.claude-multi".
  printf 'export CLAUDE_MULTI_ROOT="$tmp/home/.claude-multi"\n' >lib/mid.sh
  printf 'mkdir -p "$mini/Users/x"\n' >>lib/mid.sh
  printf 'want="${TMPDIR}/home/acct"\n' >>lib/mid.sh
  printf 'alt="~/home/acct"\n' >>lib/mid.sh
  # A dotted or dashed first segment is not a username.
  printf 'p="/home/.cache-only-a-marker"\n' >lib/dot.sh
  git add -f -- lib/doc.sh lib/mid.sh lib/dot.sh
  check
}

# ── content: something that looks like a credential ──────────────────────────
t_refuses_credential_content_without_echoing_it() {
  new_repo
  local secret="abcdef0123456789abcdef"
  printf 'TOKEN=%s%s%s\n' "sk" "-ant-" "$secret" >lib/tok.sh
  git add -f -- lib/tok.sh
  assert_fails bash scripts/check-no-secrets.sh
  local out
  out="$(refusal)"
  assert_contains "$out" "lib/tok.sh" "the refusal must name the file"
  assert_contains "$out" "credential" "the refusal must name the rule"
  assert_eq "" "$(printf '%s' "$out" | grep -F "$secret" || true)" \
    "the guard must not print the secret it found"
  assert_no_stdout bash scripts/check-no-secrets.sh
  git reset -q
  rm -f -- lib/tok.sh

  local shape
  for shape in \
    "$(printf '%s_API_%s=zzz' "ANTHROPIC" "KEY")" \
    "$(printf -- '-----%s RSA PRIVATE KEY-----' "BEGIN")" \
    "$(printf '{"%s%s": "zzz"}' "access" "Token")" \
    "$(printf '{"%s%s": "zzz"}' "refresh" "Token")"
  do
    printf '%s\n' "$shape" >lib/tok.sh
    git add -f -- lib/tok.sh
    if bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
      printf '  FAIL: the guard accepted credential-shaped content\n' >&2
      git reset -q
      return 1
    fi
    git reset -q
    rm -f -- lib/tok.sh
  done
}

# ── a deletion is not a refusal ──────────────────────────────────────────────
# Removing a forbidden file that somehow got committed must be committable.
t_deletion_is_not_a_refusal() {
  new_repo
  printf 'x\n' >lib/gone.sh
  git add -f -- lib/gone.sh
  check
  git -c user.name=t -c user.email=t@t commit -q -m seed
  git rm -q -- lib/gone.sh
  check
}

# ── an unknown argument is an error, not a silent pass ───────────────────────
t_unknown_argument_fails() {
  new_repo
  assert_fails bash scripts/check-no-secrets.sh --bogus
  assert_fails bash scripts/check-no-secrets.sh extra
  local out
  out="$(bash scripts/check-no-secrets.sh --bogus 2>&1 >/dev/null || true)"
  assert_contains "$out" "unknown argument" "an unknown argument must be explained"
  assert_no_stdout bash scripts/check-no-secrets.sh --bogus
  # --install-hook arrives in T12; until then it must not silently pass.
  assert_fails bash scripts/check-no-secrets.sh --install-hook
}

# ── outside a git repository the guard must say so, not crash ────────────────
t_outside_a_repo_is_explained() {
  local bare
  bare="$(mktemp -d "$TEST_TMP/bare.XXXXXX")"
  cp -- "$guard" "$bare/check-no-secrets.sh"
  cd -- "$bare"
  # A temp dir under TMPDIR is not inside a repo; if the host TMPDIR ever were,
  # this test would be meaningless, so it is skipped by assertion-free return.
  if git rev-parse --show-toplevel >/dev/null 2>&1; then
    return 0
  fi
  assert_fails bash ./check-no-secrets.sh
  local out
  out="$(bash ./check-no-secrets.sh 2>&1 >/dev/null || true)"
  assert_contains "$out" "git repository" "the diagnostic must name the cause"
  assert_no_stdout bash ./check-no-secrets.sh
}

# ── the guard runs from a subdirectory ───────────────────────────────────────
# A pre-commit hook can be invoked with any cwd inside the worktree.
t_works_from_a_subdirectory() {
  new_repo
  printf 'echo hi\n' >lib/ok.sh
  git add -f -- lib/ok.sh
  ( cd lib && bash ../scripts/check-no-secrets.sh )
  printf '# see %s\n' "$(printf '/home/%s/.claude' "$fake_user")" >lib/leak.sh
  git add -f -- lib/leak.sh
  ( cd lib && assert_fails bash ../scripts/check-no-secrets.sh )
  git reset -q
  rm -f -- lib/leak.sh
}

# ── dispatch ─────────────────────────────────────────────────────────────────
# Every t_* function defined above runs, in its own subshell so one failure does
# not abort the rest and so a test's `cd` cannot leak into the next. Zero
# discovered tests is a loud failure, not a silent pass.
#
# The subshell is run as a plain command with the outer errexit temporarily off,
# NOT as `if ! ( … )`. Bash suppresses errexit for everything executed inside an
# `if` condition, and that suppression survives both the subshell and an
# explicit `set -e` within it: a failing assertion halfway through a test would
# print its FAIL line and then carry on, and the test would be recorded as a
# pass. Measured, not assumed — the first draft of this dispatch reported
# "5 failed" for a run in which 16 tests were broken.
declare -a discovered=()
while IFS= read -r fn; do
  discovered+=("$fn")
done < <(declare -F | awk '{ print $3 }' | grep '^t_' | sort)

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
