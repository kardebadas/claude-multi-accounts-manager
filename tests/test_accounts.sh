#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/assert.sh"
. "$REPO_ROOT/lib/util.sh"
. "$REPO_ROOT/lib/config.sh"
. "$REPO_ROOT/lib/links.sh"
. "$REPO_ROOT/lib/seed.sh"
. "$REPO_ROOT/lib/memory.sh"
. "$REPO_ROOT/lib/accounts.sh"

LIB_ACCOUNTS="$REPO_ROOT/lib/accounts.sh"
REAL_HOME="$HOME"

# Refuse to run against anything that is not a throwaway tree.
guard_fake_root() {
  case "${CLAUDE_MULTI_ROOT:-}" in
    "$REAL_HOME/.claude-multi"|"$REAL_HOME/.claude"|""|"/"|"$REAL_HOME")
      printf 'FATAL: test tried to use a real root: %s\n' "${CLAUDE_MULTI_ROOT:-<unset>}" >&2
      exit 99 ;;
  esac
  case "${HOME:-}" in
    "$REAL_HOME")
      printf 'FATAL: test tried to use the real HOME\n' >&2
      exit 99 ;;
  esac
}

# Builds a temp HOME + a fake root whose shared/ tree is already seeded BY HAND.
# seed_shared is never called: A38 makes it refuse an existing shared/, and this
# fixture is not a test of seeding.
# Prints the temp base dir. Exports HOME and CLAUDE_MULTI_ROOT.
fake_root() {
  local base
  base="$(mktemp -d "${TMPDIR:-/tmp}/cm-acct.XXXXXX")"
  export HOME="$base/home"
  export CLAUDE_MULTI_ROOT="$HOME/.claude-multi"
  guard_fake_root
  mkdir -p "$CLAUDE_MULTI_ROOT/shared/agents" \
           "$CLAUDE_MULTI_ROOT/shared/hooks" \
           "$CLAUDE_MULTI_ROOT/shared/commands" \
           "$CLAUDE_MULTI_ROOT/shared/agent-memory" \
           "$CLAUDE_MULTI_ROOT/shared/project-memory" \
           "$CLAUDE_MULTI_ROOT/shared/plugin-cache" \
           "$base/codex-skills"
  printf '%s\n' '# shared rules' > "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md"
  printf '%s\n' '{}' > "$CLAUDE_MULTI_ROOT/shared/settings.json"
  ln -s "$base/codex-skills" "$CLAUDE_MULTI_ROOT/shared/skills"
  printf '%s\n' "$base"
}

mk_account() {
  mkdir -p "$CLAUDE_MULTI_ROOT/$1"
}

# yesno <command> [args...] — prints "yes" if the command succeeds, "no" if it
# fails. tests/assert.sh has no `fail`, so a boolean claim about the filesystem
# is expressed as:
#     assert_eq "yes" "$(yesno test -d "$p")" "the account directory exists"
#     assert_eq "no"  "$(yesno test -e "$p")" "nothing was created"
# It is total by construction, so it can never abort a test under errexit, and
# the message survives (which `assert_fails` cannot carry).
yesno() {
  if "$@"; then printf 'yes'; else printf 'no'; fi
}

# feed <line> <command> [args...] — runs the command with <line> on stdin.
# Lets a stdin-reading function be passed to assert_stdout_empty_bytes, which
# takes argv and cannot be given a pipeline.
feed() {
  local line="$1"; shift
  printf '%s\n' "$line" | "$@"
}

test_list_accounts_is_empty_on_a_fresh_root() {
  fake_root >/dev/null
  local out
  out="$(list_accounts)"
  assert_eq "" "$out" "a fresh root has zero accounts"
}

# ── harness teeth ────────────────────────────────────────────────────────────
# Does the runner block below actually catch a failing test? The dangerous case
# is not "a test fails" — it is "a test's FIRST assertion fails and a LATER one
# passes", which is what an `if ! ( … )` dispatcher reports as PASS, because
# bash's errexit suppression inside an `if` condition reaches into subshells.
#
# This builds a probe file out of the REAL runner block (copied verbatim out of
# this file with sed, so the probe cannot drift from what ships) plus two test
# functions: one that fails its first assertion and would pass its last, and one
# that is clean. The probe must report the first FAILED, the second passed, and
# exit 1 — and must never reach the sentinel after the failing assertion.
test_the_runner_block_reports_an_early_failing_assertion() {
  local probe_dir probe rc=0 err
  probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/cm-teeth.XXXXXX")"
  probe="$probe_dir/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. %q\n' "$REPO_ROOT/tests/assert.sh"
    printf '%s\n' \
      'test_early_fail_then_pass() {' \
      '  assert_eq "expected" "actual" "the first assertion must abort this test"' \
      '  printf "TEETH-SENTINEL-REACHED\n" >&2' \
      '  assert_eq "same" "same" "a later passing assertion must not rescue it"' \
      '}' \
      'test_clean_control() {' \
      '  assert_eq "a" "a" "the control test must still pass"' \
      '}'
    sed -n '/^# ── RUNNER ──/,$p' "$REPO_ROOT/tests/test_accounts.sh"
  } > "$probe"

  # `env -u CM_ONE_TEST` is required, not tidiness: this test is itself running
  # inside a CM_ONE_TEST re-exec, so the probe would inherit that variable,
  # take the single-test branch of the block it just copied, and fail with 127
  # for a test name it does not define. Clearing the seam is what makes the
  # probe run its own dispatcher.
  #
  # And the status is captured with set +e / $? / set -e for the same reason the
  # dispatcher is: `if ! bash -- "$probe"` would suppress errexit in this shell
  # and read as if the vulnerable form were acceptable.
  set +e
  err="$(env -u CM_ONE_TEST bash -- "$probe" 2>&1 >/dev/null)"
  rc=$?
  set -e
  rm -rf -- "$probe_dir"

  assert_eq "1" "$rc" "a failing test must make the file exit non-zero"
  assert_contains "$err" "FAIL  test_early_fail_then_pass"
  assert_contains "$err" "pass  test_clean_control"
  assert_contains "$err" "2 test(s), 1 failure(s)"
  assert_eq "" "$(printf '%s\n' "$err" | grep -F 'TEETH-SENTINEL-REACHED' || true)" \
            "an aborted test must not run past its failed assertion"
}

test_list_accounts_skips_reserved_and_hidden_entries() {
  fake_root >/dev/null
  mk_account personal
  mk_account work
  mk_account personal-mother
  mkdir -p "$CLAUDE_MULTI_ROOT/.trash" \
           "$CLAUDE_MULTI_ROOT/plugin-cache" \
           "$CLAUDE_MULTI_ROOT/project-memory" \
           "$CLAUDE_MULTI_ROOT/.hidden"
  printf 'x\n' > "$CLAUDE_MULTI_ROOT/not-a-dir"

  local out expected
  out="$(list_accounts)"
  expected="$(printf 'personal\npersonal-mother\nwork\n')"
  assert_eq "$expected" "$out" "only real accounts are listed, sorted"
}

test_list_accounts_order_is_deterministic_and_locale_independent() {
  # Phase 6 numbers the menu by this order and deletes by the typed number, so
  # the order is part of the delete path's safety. Accounts are created in a
  # deliberately non-alphabetical order, and the names are chosen so that a
  # locale-sensitive collation (which ignores or reorders '-') would disagree
  # with the byte-wise one: under LC_ALL=C, '-' (0x2D) sorts before every
  # letter and digit, so 'personal-mother' precedes 'personal2' precedes
  # 'personalx'.
  fake_root >/dev/null
  local n
  for n in work personalx 0zero personal-mother alpha personal2 personal; do
    mk_account "$n"
  done

  local expected
  expected="$(printf '%s\n' 0zero alpha personal personal-mother personal2 personalx work)"
  assert_eq "$expected" "$(list_accounts)" \
            "list_accounts emits byte-wise ascending order"

  # same bytes under a collating locale, and under a reversed sort environment
  assert_eq "$expected" "$(LC_ALL=en_US.UTF-8 list_accounts)" \
            "the order must not follow LC_COLLATE"
  assert_eq "$expected" "$(LC_COLLATE=en_US.UTF-8 list_accounts)" \
            "the order must not follow LC_COLLATE alone either"

  # and it is stable across repeated calls (readdir order is not a contract)
  assert_eq "$(list_accounts)" "$(list_accounts)" \
            "two consecutive calls must agree byte for byte"
}

test_list_accounts_returns_zero_when_root_is_absent() {
  fake_root >/dev/null
  rm -rf "$CLAUDE_MULTI_ROOT"
  local out rc=0
  out="$(list_accounts)" || rc=$?
  assert_eq "0" "$rc" "a missing root is not an error"
  assert_eq "" "$out" "a missing root lists nothing"
}

test_account_status_reports_credentials_presence() {
  fake_root >/dev/null
  mk_account personal
  mk_account work
  printf '%s\n' 'not-a-real-token' > "$CLAUDE_MULTI_ROOT/personal/.credentials.json"
  : > "$CLAUDE_MULTI_ROOT/work/.credentials.json"   # exists but empty -> not logged in

  assert_eq "logged-in"      "$(account_status personal)" "non-empty credentials -> logged-in"
  assert_eq "no-credentials" "$(account_status work)"     "empty credentials file -> no-credentials"
  mk_account fresh
  assert_eq "no-credentials" "$(account_status fresh)"    "absent credentials -> no-credentials"
}

test_account_status_is_exactly_the_existence_test() {
  local body
  body="$(sed -n '/^account_status()/,/^}/p' "$LIB_ACCOUNTS")"
  assert_contains "$body" '[[ -s "$acct/.credentials.json" ]]'

  # Every line in account_status that mentions the file must BE the -s test.
  local line
  while IFS= read -r line; do
    case "$line" in
      *'[[ -s "$acct/.credentials.json" ]]'*) : ;;
      *) assert_eq "" "$line" "account_status may only existence-test the credentials file" ;;
    esac
  done < <(printf '%s\n' "$body" | grep -F 'credentials.json' || true)
}

test_accounts_lib_never_reads_copies_or_deletes_credentials() {
  # No command anywhere in the library may target the credentials path.
  local hits
  hits="$(grep -nE '\b(cat|jq|cp|mv|rm|head|tail|awk|sed|tr|chmod|chown|source|install|rsync)\b[^#]*\.credentials\.json' "$LIB_ACCOUNTS" || true)"
  assert_eq "" "$hits" "lib/accounts.sh must never read, parse, copy or delete .credentials.json"
}

test_credentials_references_are_limited_to_three_allowed_forms() {
  # An explicit allowlist, so that later delete-path work cannot quietly add a
  # fourth way of touching that filename. The three legitimate forms are:
  #   1. the existence test in account_status (5a)
  #   2. tar's --exclude= in archive_account (5b)
  #   3. the archive-listing check in verify_archive (5b) -- which reads the
  #      ARCHIVE's table of contents, never the real file
  # delete_account removes the containing directory; that is not a
  # path-targeted access and no line of it names the file.
  local line trimmed
  while IFS= read -r line; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      'if [[ -s "$acct/.credentials.json" ]]; then'*) : ;;
      'tar --exclude=./.credentials.json --exclude=./.claude.json'*) : ;;
      "if tar -tzf \"\$tgz\" 2>/dev/null | grep -qxF './.credentials.json'; then"*) : ;;
      *) assert_eq "" "$trimmed" "unapproved reference to the credentials filename" ;;
    esac
  done < <(grep -F 'credentials.json' "$LIB_ACCOUNTS" || true)
}

test_add_account_creates_links_stub_and_syncs_memory() {
  fake_root >/dev/null
  mkdir -p "$CLAUDE_MULTI_ROOT/shared/project-memory/project-one"
  local out
  out="$(add_account personal 2>/dev/null)"
  assert_eq "" "$out" "add_account writes nothing to stdout"

  local acct="$CLAUDE_MULTI_ROOT/personal"
  assert_eq "700" "$(stat -c '%a' "$acct")" "the account directory is mode 700"
  assert_link "$acct/CLAUDE.md"      "../shared/CLAUDE.md"
  assert_link "$acct/agents"         "../shared/agents"
  assert_link "$acct/hooks"          "../shared/hooks"
  assert_link "$acct/commands"       "../shared/commands"
  assert_link "$acct/agent-memory"   "../shared/agent-memory"
  assert_link "$acct/settings.json"  "../shared/settings.json"
  assert_eq "yes" "$(yesno test -L "$acct/skills")" "skills must be a symlink"
  assert_eq "yes" "$(yesno test -d "$acct/skills")" "the skills link must resolve to a directory"
  assert_link "$acct/projects/project-one/memory" \
              "../../../shared/project-memory/project-one"

  assert_eq '{"hasCompletedOnboarding":true,"projects":{}}' \
            "$(cat "$acct/.claude.json")" \
            ".claude.json stub is exactly the A31 payload"
  assert_eq "600" "$(stat -c '%a' "$acct/.claude.json")" "stub is mode 600"
  assert_eq "no" "$(yesno test -e "$acct/.credentials.json")" "add must not fabricate credentials"
  assert_eq "no-credentials" "$(account_status personal)" "a new account is not logged in"
  assert_contains "$(list_accounts)" "personal"
}

test_add_account_lowercases_with_a_notice_on_stderr() {
  fake_root >/dev/null
  local err
  err="$(add_account Work-A 2>&1 >/dev/null)"
  assert_contains "$err" "work-a"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/work-a")" "uppercase input must create the lowercase account"
  assert_eq "no" "$(yesno test -e "$CLAUDE_MULTI_ROOT/Work-A")" "the uppercase directory must not exist"
}

test_add_account_warns_but_completes_when_a_shared_link_cannot_be_healed() {
  fake_root >/dev/null
  rm -rf "$CLAUDE_MULTI_ROOT/shared/agents"

  local err rc=0
  err="$(add_account personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "an unrepairable shared link must not abort account creation"
  assert_contains "$err" "some shared links"
  assert_eq "yes" "$(yesno test -f "$CLAUDE_MULTI_ROOT/personal/.claude.json")" \
            "the onboarding stub must still be written"
}

test_add_account_warns_but_completes_when_memory_sync_returns_one() {
  fake_root >/dev/null
  sync_project_memory() {
    return 1
  }

  local err rc=0
  err="$(add_account personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "a refused memory sync must not abort account creation"
  assert_contains "$err" "project-memory sync"
  assert_eq "yes" "$(yesno test -f "$CLAUDE_MULTI_ROOT/personal/.claude.json")" \
            "the onboarding stub must remain available"
}

test_add_account_refuses_an_existing_name() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'sentinel\n' > "$CLAUDE_MULTI_ROOT/personal/.claude.json"

  local rc=0 err
  err="$(add_account personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "1" "$rc" "a second add of the same name fails"
  assert_contains "$err" "already exists"
  assert_eq "sentinel" "$(cat "$CLAUDE_MULTI_ROOT/personal/.claude.json")" \
            "the existing account must not be overwritten"
}

test_add_account_refuses_reserved_names() {
  fake_root >/dev/null
  local n rc
  for n in shared .trash plugin-cache project-memory; do
    rc=0
    add_account "$n" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "add_account must refuse the reserved name '$n'"
  done
  assert_eq "yes" "$(yesno test -f "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md")" "shared/CLAUDE.md was disturbed"
  assert_eq "no" "$(yesno test -e "$CLAUDE_MULTI_ROOT/shared/.claude.json")" "a stub leaked into shared/"
}

test_add_account_refuses_invalid_names() {
  fake_root >/dev/null
  local n rc
  for n in "" "-leading" ".dotted" "has space" "under_score" "Ünicode" \
           "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "path/traversal" ".." ; do
    rc=0
    add_account "$n" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "add_account must refuse the invalid name '$n'"
  done
  assert_eq "" "$(list_accounts)" "no invalid name created a directory"
}

test_offer_launch_prompt_text_and_default_yes() {
  fake_root >/dev/null
  unset CLAUDE_MULTI_NO_LAUNCH
  local err rc=0
  err="$(printf '\n' | offer_launch personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "empty answer means yes"
  assert_contains "$err" "launch claude in 'personal' now to log in? [Y/n]"

  local out
  out="$(printf '\n' | offer_launch personal 2>/dev/null)"
  assert_eq "" "$out" "the prompt must not touch stdout"
}

test_offer_launch_declines_on_n_and_on_eof() {
  fake_root >/dev/null
  unset CLAUDE_MULTI_NO_LAUNCH
  local rc

  rc=0; printf 'n\n' | offer_launch personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "'n' declines"

  rc=0; printf 'N\n' | offer_launch personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "'N' declines"

  rc=0; offer_launch personal </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "EOF declines rather than hanging or launching"

  rc=0; printf 'y\n' | offer_launch personal >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "'y' accepts"
}

test_offer_launch_is_fully_suppressible() {
  fake_root >/dev/null
  local rc=0 err
  err="$(CLAUDE_MULTI_NO_LAUNCH=1 offer_launch personal 2>&1 >/dev/null </dev/null)" || rc=$?
  assert_eq "1" "$rc" "suppressed offer declines"
  assert_eq "" "$(printf '%s\n' "$err" | grep -F '[Y/n]' || true)" \
            "CLAUDE_MULTI_NO_LAUNCH must suppress the prompt itself"
  assert_contains "$err" "claude-multi personal"
}

test_offer_launch_never_execs_claude() {
  # The launch offer returns a decision; only Phase 6 execs. Guard that here so
  # nobody "helpfully" adds an exec to the add path.
  local hits
  hits="$(grep -nE '\b(exec|claude)\b' <(sed -n '/^offer_launch()/,/^}/p' "$LIB_ACCOUNTS") \
          | grep -vE "launch claude in|claude-multi" || true)"
  assert_eq "" "$hits" "offer_launch must not exec or invoke claude"
}

# ── RUNNER ── KEEP THIS BLOCK LAST IN THE FILE ───────────────────────────────
# Every later task in 5a and 5b appends its test functions ABOVE this marker.
#
# tests/run.sh only checks the file's exit status, so without this block the
# file would define its tests, exit 0, and be reported `ok` while running
# nothing — including the whole guarded-delete suite. See the Test-file
# execution contract in Global Constraints.
#
# Each test runs in a FRESH bash process (self re-exec with CM_ONE_TEST set),
# so `set -euo pipefail` above is genuinely in force inside it and a bare
# failing assertion aborts that test and nothing else.
#
# DO NOT "simplify" the status capture below to `if ! ( set -e; "$t" ); then`
# or to `... || _cm_rc=$?`. Bash disables errexit for anything run inside an
# `if` condition or on the left of a &&/|| list, AND that suppression reaches
# into subshells: a test whose FIRST assertion fails would then keep running,
# and a later passing assertion in the same function would leave the exit
# status 0 — the test would be reported as PASSED. Phase 1 Task 7 caught this
# with a mutant that escaped its dispatcher for exactly this reason. The
# `set +e` / read `$?` / `set -e` form below is the verified one, and is the
# form already committed throughout tests/test_runner.sh.
# test_the_runner_block_reports_an_early_failing_assertion (above) is the
# regression test for this comment; if you change the dispatcher, that test is
# what tells you whether the harness still has teeth.
if [[ -n "${CM_ONE_TEST:-}" ]]; then
  "$CM_ONE_TEST"
  exit 0
fi

_cm_ran=0
_cm_failed=0
while IFS= read -r _cm_test; do
  _cm_ran=$(( _cm_ran + 1 ))
  set +e
  CM_ONE_TEST="$_cm_test" bash -- "${BASH_SOURCE[0]}"
  _cm_rc=$?
  set -e
  if (( _cm_rc == 0 )); then
    printf '  pass  %s\n' "$_cm_test" >&2
  else
    printf '  FAIL  %s (exit %d)\n' "$_cm_test" "$_cm_rc" >&2
    _cm_failed=$(( _cm_failed + 1 ))
  fi
done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

printf '%s: %d test(s), %d failure(s)\n' \
  "${BASH_SOURCE[0]##*/}" "$_cm_ran" "$_cm_failed" >&2

if (( _cm_ran == 0 )); then
  printf 'FATAL: tests/test_accounts.sh defined no tests — a green run here would be a lie\n' >&2
  exit 1
fi
if (( _cm_failed > 0 )); then
  exit 1
fi
