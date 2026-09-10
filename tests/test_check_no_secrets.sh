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

# expect_accepted <relative path> … — stage each with -f, require the guard to
# accept the whole index, then leave the index clean again. Every body is the
# single character `x`, so only the NAME is under test.
expect_accepted() {
  local p
  for p in "$@"; do
    mkdir -p -- "$(dirname -- "$p")"
    printf 'x\n' >"$p"
    git add -f -- "$p"
  done
  if ! bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
    printf '  FAIL: the guard refused a legitimate name:\n%s\n' "$(refusal)" >&2
    git reset -q
    return 1
  fi
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
  git reset -q
  for p in "$@"; do rm -f -- "$p"; done
}

# expect_leak_refused <content line> <rule needle> — write one line into
# lib/leak.sh, stage it, require a refusal that names both the file and the
# rule. The offending text never appears as a committed literal: callers
# assemble it with printf and only the assembled value reaches this function.
expect_leak_refused() {
  local line="$1" needle="$2" out
  printf '%s\n' "$line" >lib/leak.sh
  git add -f -- lib/leak.sh
  if bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
    printf '  FAIL: the guard accepted the leak shape [%s]\n' "$line" >&2
    git reset -q
    rm -f -- lib/leak.sh
    return 1
  fi
  out="$(refusal)"
  assert_contains "$out" "lib/leak.sh" "the refusal must name the file"
  assert_contains "$out" "$needle" "the refusal must name the rule"
  assert_no_stdout bash scripts/check-no-secrets.sh
  git reset -q
  rm -f -- lib/leak.sh
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
  git reset -q

  # An EMPTY blob is not "unscannable" — there is simply nothing in it, and a
  # zero-byte placeholder is a legitimate tracked file. Without this the binary
  # rule would refuse it: grep declines to match an empty stream just as it
  # declines to match a binary one, so size has to be checked first.
  : >lib/.keep
  printf '\n\n' >lib/blank.sh
  git add -f -- lib/.keep lib/blank.sh
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
  # M-5: this lock needs a git checkout to mirror. Run from an exported tarball
  # or a plain copy there is nothing to check, and an opaque red test would be
  # worse than saying so. Skipped deliberately, with the reason on stderr.
  if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    printf '  SKIP: %s is not a git checkout — the real-tracked-tree lock needs one\n' \
      "$REPO_ROOT" >&2
    return 0
  fi
  mirror="$(mktemp -d "$TEST_TMP/mirror.XXXXXX")"
  while IFS= read -r -d '' f; do
    mkdir -p -- "$(dirname -- "$mirror/$f")"
    cp -- "$REPO_ROOT/$f" "$mirror/$f"
    paths+=("$f")
  done < <(git -C "$REPO_ROOT" ls-files -z)
  if ((${#paths[@]} == 0)); then
    printf '  FAIL: %s is a git checkout but tracks no files — the lock cannot run\n' \
      "$REPO_ROOT" >&2
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

# ── content: the evasions that walked past the first pattern (C-1) ───────────
# Every shape below spells out a real username in full. The first draft of
# ABS_HOME_RE let all of them through because `/` and `-` were in its boundary
# exclusion class and because the WSL and tilde-user roots were absent. Each is
# assembled at runtime, so the committed literal here is `//%s/%s/.claude` and
# friends — nothing a pattern can match.
t_refuses_absolute_home_path_evasions() {
  new_repo
  local why="absolute home path"

  # A doubled separator resolves to exactly the same file.
  expect_leak_refused "$(printf '# see //%s/%s/.claude' "home" "$fake_user")" "$why"
  # A file:// URL in a markdown doc.
  expect_leak_refused "$(printf '[cfg](file:///%s/%s/.claude)' "home" "$fake_user")" "$why"
  # tilde-user — invited by the very advice "write $HOME or ~".
  expect_leak_refused "$(printf 'cfg=~%s/.claude/settings.json' "$fake_user")" "$why"
  # WSL, which is the platform this project is developed on. Leaks the
  # Windows account name.
  expect_leak_refused "$(printf 'p=/mnt/c/%s/%s/AppData' "Users" "$fake_user")" "$why"
  expect_leak_refused "$(printf 'p=/mnt/D/%s/%s/Desktop' "Users" "$fake_user")" "$why"
  expect_leak_refused "$(printf 'p=/mnt/wsl/%s/%s' "home" "$fake_user")" "$why"
  # The removed side of a committed diff or patch hunk.
  expect_leak_refused "$(printf -- '-/%s/%s/.claude/settings.json' "home" "$fake_user")" "$why"
  # Any other hyphen-adjacent text.
  expect_leak_refused "$(printf -- 'make -C-/%s/%s/src' "home" "$fake_user")" "$why"
}

# ── content: the legitimate near-misses, in isolation ────────────────────────
# M-7: every root below is spliced in at runtime, so no committed literal in
# this file sits one character from matching the guard. The earlier draft wrote
# these out in full — `/home/<username>`, `$tmp/home/`, `/home/.cache-…` — and
# each one's safety rested on a single character (the `<`, the `p`, the `.`).
# The self-refusal lock would have caught an edit to any of them loudly, but a
# fixture that cannot trip the guard at all is better than one the lock has to
# rescue.
t_allows_home_placeholder_and_midpath() {
  new_repo
  local home_root users_root
  home_root="$(printf '/%s' "home")"
  users_root="$(printf '/%s' "Users")"

  # The placeholder is the text of the rule itself — CLAUDE.md contains it.
  printf 'never write %s/<username>/... — use $HOME or ~\n' "$home_root" >lib/doc.sh
  # The root in the MIDDLE of a path is a temp path, not a real home.
  # tests/run.sh genuinely builds "$tmp/home/.claude-multi".
  printf 'export CLAUDE_MULTI_ROOT="$tmp%s/.claude-multi"\n' "$home_root" >lib/mid.sh
  printf 'mkdir -p "$mini%s/x"\n' "$users_root" >>lib/mid.sh
  printf 'want="${TMPDIR}%s/acct"\n' "$home_root" >>lib/mid.sh
  printf 'alt="~%s/acct"\n' "$home_root" >>lib/mid.sh
  # A dotted or dashed first segment is not a username.
  printf 'p="%s/.cache-only-a-marker"\n' "$home_root" >lib/dot.sh
  printf 'q="%s/-not-a-user"\n' "$home_root" >>lib/dot.sh
  # A bare tilde, and a tilde with no path after the name, are not leaks.
  printf 'r="~/.claude-multi"\n' >lib/tilde.sh
  printf 's="approximately ~ half"\n' >>lib/tilde.sh
  git add -f -- lib/doc.sh lib/mid.sh lib/dot.sh lib/tilde.sh
  check
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
}

# ── names that merely resemble a forbidden one must pass ─────────────────────
# A guard that refuses documentation about credentials, or a settings template,
# is a guard people switch off. These 19 names are the ones a real repo grows.
t_near_miss_names_pass() {
  new_repo
  expect_accepted \
    "settings.example.json" \
    "docs/settings.sample.json" \
    "env.sample" \
    "docs/projects.md" \
    "docs/shared-notes.md" \
    "lib/shared.sh" \
    "README.md" \
    "bin/claude-multi" \
    "install.sh" \
    "docs/credentials.md" \
    "docs/claude-json.md" \
    "lib/logging.sh" \
    "docs/changelog.md" \
    "tests/tmpdir.sh" \
    "docs/history.md" \
    "docs/superpowers-notes.md" \
    "src/output.txt" \
    "docs/design.out.md" \
    "lib/.claude-multi-helpers.sh"

  # .env.example is DELIBERATELY refused — see the .env.* note in the guard.
  # Asserted here so nobody "fixes" it into a pass by accident.
  expect_refused ".env.example" "environment file"
}

# ── a binary blob cannot be scanned, so it cannot be trusted (I-2) ───────────
# grep -I skips binaries outright, so before this rule a .png carrying a home
# path or a token sailed through both content scans. This repo's .gitignore
# allowlist only ever permits .sh files plus bin/claude-multi and
# tests/fake-claude, so there is no legitimate tracked binary to protect: the
# correct answer is to refuse one, not to try to scan it.
t_refuses_a_binary_blob() {
  new_repo
  local leak
  leak="$(printf '/%s/%s/.claude' "home" "$fake_user")"
  printf 'PNG\r\n\032\n\000\000IHDR\000\000%s\000\n' "$leak" >lib/shot.png
  git add -f -- lib/shot.png
  if bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
    printf '  FAIL: the guard accepted a binary blob\n' >&2
    git reset -q
    return 1
  fi
  local out
  out="$(refusal)"
  assert_contains "$out" "lib/shot.png" "the refusal must name the file"
  assert_contains "$out" "binary" "the refusal must name the rule"
  assert_no_stdout bash scripts/check-no-secrets.sh
  git reset -q
  rm -f -- lib/shot.png

  # An extensionless binary must go the same way — the rule is the content,
  # not the name.
  printf 'ELF\000\001\002\000%s\000\n' "$leak" >lib/blob
  git add -f -- lib/blob
  assert_fails bash scripts/check-no-secrets.sh
  assert_contains "$(refusal)" "binary" "the rule is content, not extension"
  git reset -q
  rm -f -- lib/blob
}

# F-003: a text prefix larger than the pipe buffer must not hide binary content
# later in the staged blob. The old `grep -Iq` decision returned at the first
# text line, before it ever reached the NUL, so both it and the later `grep -I`
# content scans treated this mixed blob as clean.
t_refuses_a_large_text_prefixed_binary_blob() {
  new_repo
  local bytes i leak out
  leak="$(printf '/%s/%s/.claude' "home" "$fake_user")"
  { for ((i = 0; i < 40000; i++)); do printf 'echo line %s\n' "$i"; done; } >lib/mixed.sh
  printf '\000%s\n' "$leak" >>lib/mixed.sh
  git add -f -- lib/mixed.sh

  bytes="$(git cat-file -s :lib/mixed.sh)"
  if ((bytes < 200000)); then
    printf '  FAIL: fixture is only %s bytes — too small to exceed the pipe buffer\n' "$bytes" >&2
    return 1
  fi
  if bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
    printf '  FAIL: the guard accepted a %s-byte text-prefixed binary blob\n' "$bytes" >&2
    return 1
  fi
  out="$(refusal)"
  assert_contains "$out" "lib/mixed.sh" "the refusal must name the mixed blob"
  assert_contains "$out" "binary" "the complete blob must be classified as binary"
  assert_no_stdout bash scripts/check-no-secrets.sh
}

# ── the binary decision must not be able to come back as a SIGNAL ────────────
# blob_is_unscannable used to be `if git show ":$p" | grep -Iq -e ''`. `grep -q`
# exits at its first match and closes the pipe, `git show` dies of SIGPIPE with
# a large blob still half-written, pipefail turns the pipeline into 141, and the
# `if` reads that as "grep would not read it" — so an ordinary UTF-8 shell
# script was REFUSED as binary content. It needed the reader to win the race, so
# it was intermittent: roughly one whole-suite run in five, blaming a different
# innocent file each time.
#
# The tests below pin both sides of the replacement: a complete large text blob
# stays scannable, while a genuine staged-blob read failure stays fail-closed.
#
# 1. Through the real guard, with a blob far larger than the 64 KiB pipe buffer,
#    so the writer CANNOT finish before a `grep -q` on the other end exits. The
#    old construct returned 141 on 10 of 10 runs at this size.
t_a_large_text_blob_is_not_refused_as_binary() {
  new_repo
  local i
  { for ((i = 0; i < 40000; i++)); do printf 'echo line %s\n' "$i"; done; } >lib/big.sh
  # Guard the premise: a blob that fits in the pipe buffer would prove nothing.
  local bytes
  git add -f -- lib/big.sh
  bytes="$(git cat-file -s :lib/big.sh)"
  if ((bytes < 200000)); then
    printf '  FAIL: fixture is only %s bytes — too small to force the pipe to fill\n' "$bytes" >&2
    return 1
  fi
  if ! bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
    printf '  FAIL: an ordinary %s-byte text blob was refused:\n%s\n' "$bytes" "$(refusal)" >&2
    git reset -q
    return 1
  fi
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
  git reset -q
  rm -f -- lib/big.sh
}

# 2. At the seam, a staged-blob read that genuinely fails must stay fail-closed.
#    The full byte-counting consumer above removes the short-read/SIGPIPE race,
#    so any remaining non-zero producer status is a real inability to scan.
t_a_blob_read_failure_is_unscannable() {
  new_repo
  printf 'echo hi\n' >lib/ok.sh
  git add -f -- lib/ok.sh
  # shellcheck source=/dev/null
  source scripts/check-no-secrets.sh
  git() {
    case "$*" in
      *"cat-file -s"*)    printf '8\n'; return 0 ;;
      *"cat-file blob"*) return 1 ;;
      *)               command git "$@" ;;
    esac
  }
  if ! blob_is_unscannable "$PWD" lib/ok.sh; then
    unset -f git
    printf '  FAIL: a failed staged-blob read was treated as scannable\n' >&2
    return 1
  fi
  unset -f git
}

# ── a gitlink cannot be scanned either (M-6) ─────────────────────────────────
# `git show ":sub"` on a submodule entry yields no content, so both content
# scans silently found nothing and the entry passed. This repo has no
# submodules and must never gain one, so a gitlink is refused outright.
t_refuses_a_gitlink() {
  new_repo
  local sha
  sha="$(printf 'placeholder\n' | git hash-object -w --stdin)"
  git update-index --add --cacheinfo "160000,$sha,vendor/sub"
  if bash scripts/check-no-secrets.sh >/dev/null 2>&1; then
    printf '  FAIL: the guard accepted a gitlink entry\n' >&2
    git reset -q
    return 1
  fi
  local out
  out="$(refusal)"
  assert_contains "$out" "vendor/sub" "the refusal must name the entry"
  assert_contains "$out" "gitlink" "the refusal must name the rule"
  assert_no_stdout bash scripts/check-no-secrets.sh
  git reset -q
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

# ── content: the token shapes the first pattern missed (I-3) ─────────────────
# Every literal here is assembled at runtime. That is not decoration: the
# self-refusal lock caught two hard-coded fixtures in earlier drafts of this
# very file, and a token-shaped literal committed here would make the guard
# refuse its own test suite.
t_refuses_broader_credential_shapes() {
  new_repo
  local why="credential"
  local ey jwt
  # The JWT header prefix, split so the committed literal cannot match. The
  # payload chunks below deliberately contain no such prefix of their own.
  ey="$(printf '%s%s' "ey" "J")"
  jwt="${ey}hbGciOiJIUzI1NiJ9.${ey}zdWIiOiIxIn0.c2lnbmF0dXJlYWJjZGVmZ2hp"

  # Single-quoted, the shape a JS/Python config uses.
  expect_leak_refused "$(printf "{'%s%s': 'zzz'}" "access" "Token")" "$why"
  # Unquoted assignment, the shape a shell export uses.
  expect_leak_refused "$(printf '%s%s=%s' "access" "Token" "abcdef0123456789")" "$why"
  # snake_case, the shape an OAuth response uses.
  expect_leak_refused "$(printf '%s_%s: %s' "access" "token" "abcdef0123456789")" "$why"
  expect_leak_refused "$(printf '%s_%s=%s' "refresh" "token" "abcdef0123456789")" "$why"
  # The other Anthropic env var.
  expect_leak_refused "$(printf '%s_AUTH_%s=zzz' "ANTHROPIC" "TOKEN")" "$why"
  # A Bearer header, and a bare JWT with no header around it.
  expect_leak_refused "$(printf 'Authorization: %s %s' "Bearer" "$jwt")" "$why"
  expect_leak_refused "$(printf 'tok = "%s"' "$jwt")" "$why"
  # GitHub fine-grained and the newer classic prefixes.
  expect_leak_refused "$(printf '%s%s' "github" "_pat_11ABCDEFGH0123456789")" "$why"
  expect_leak_refused "$(printf '%s%s' "gho" "_0123456789abcdefghij")" "$why"
  # Slack.
  expect_leak_refused "$(printf '%s%s' "xox" "b-0123456789-abcdefghij")" "$why"
  # AWS, both spellings of the key name.
  expect_leak_refused "$(printf '%s_secret_access_%s=zzz' "aws" "key")" "$why"
  expect_leak_refused "$(printf '%s_SECRET_ACCESS_%s=zzz' "AWS" "KEY")" "$why"
}

# ── prose about credentials is not a credential ──────────────────────────────
# The token pattern requires a `:` or `=` after the key name, so documentation
# that merely names the field is not a refusal. Without this the guard would
# refuse README.md and its own design notes.
t_credential_prose_passes() {
  new_repo
  mkdir -p -- docs
  printf 'The %s%s field in that file is never read by this tool.\n' \
    "access" "Token" >docs/notes.md
  printf 'The %s_%s field is documented upstream, not here.\n' \
    "access" "token" >>docs/notes.md
  git add -f -- docs/notes.md
  check
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
}

# ── a deletion is not a refusal, even of a FORBIDDEN path (M-1) ──────────────
# Removing a forbidden file that somehow got committed must be committable: a
# deletion publishes nothing. The path deleted here is settings.json, which
# every path rule in the guard would refuse as an addition — that is what makes
# this test able to tell --diff-filter=ACMR from ACMRD. An earlier version
# deleted lib/gone.sh, a name no rule matches, so the ACMRD mutant had nothing
# to refuse and the test passed either way.
t_deletion_of_a_forbidden_path_is_not_a_refusal() {
  new_repo
  printf 'x\n' >lib/gone.sh
  printf 'x\n' >settings.json
  # Committed WITHOUT running the guard: as an addition, settings.json is
  # exactly what the guard exists to refuse.
  git add -f -- lib/gone.sh settings.json
  assert_fails bash scripts/check-no-secrets.sh
  git -c user.name=t -c user.email=t@t commit -q -m seed
  git rm -q -- settings.json
  assert_eq "settings.json" "$(git diff --cached --name-only)" \
    "the deletion must actually be staged"
  check
  assert_stdout_empty_bytes bash scripts/check-no-secrets.sh
  # And an ordinary deletion alongside it stays fine.
  git rm -q -- lib/gone.sh
  check
}

# ── every git call is anchored to the worktree root, not to cwd (M-2) ─────────
# A pre-commit hook inherits whatever cwd the committer had. `git diff --cached`
# is not cwd-limited by default, which is why swapping `git -C "$top"` for a
# plain `git` used to survive the whole suite. diff.relative=true makes the
# difference observable: under a plain `git` run from lib/, a leak at the repo
# ROOT is not even listed, and the guard exits 0 on a poisoned index.
t_anchoring_is_the_worktree_root_not_cwd() {
  new_repo
  git config diff.relative true
  printf '# see %s\n' "$(printf '/%s/%s/.claude' "home" "$fake_user")" >root-leak.sh
  git add -f -- root-leak.sh
  assert_fails bash scripts/check-no-secrets.sh
  ( cd lib && assert_fails bash ../scripts/check-no-secrets.sh )
  local out
  out="$( cd lib && bash ../scripts/check-no-secrets.sh 2>&1 >/dev/null || true )"
  assert_contains "$out" "root-leak.sh" \
    "a leak at the repo root must be reported from a subdirectory too"
  git reset -q
  rm -f -- root-leak.sh
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
  # --install-hook was the placeholder here while it did not exist yet. It is a
  # real argument now; its whole contract lives in tests/test_precommit_hook.sh,
  # including that `--install-hook --bogus` is still an error.
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
