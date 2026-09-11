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
      "if printf '%s\\n' \"\$listing\" | grep -qxF './.credentials.json'; then"*) : ;;
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

test_describe_account_shows_path_size_and_credentials() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  head -c 4096 /dev/zero | tr '\0' 'x' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  printf 'not-a-real-token\n' > "$CLAUDE_MULTI_ROOT/personal/.credentials.json"

  local err out
  err="$(describe_account personal 2>&1 >/dev/null)"
  out="$(describe_account personal 2>/dev/null)"
  assert_eq "" "$out" "describe_account writes nothing to stdout"
  assert_contains "$err" "$CLAUDE_MULTI_ROOT/personal"
  assert_contains "$err" "size:"
  assert_contains "$err" "credentials: present"
  assert_contains "$err" "log in again"

  add_account fresh 2>/dev/null
  err="$(describe_account fresh 2>&1 >/dev/null)"
  assert_contains "$err" "credentials: absent"
}

test_describe_account_refuses_a_missing_account() {
  fake_root >/dev/null
  local err out rc=0
  err="$(describe_account missing 2>&1 >/dev/null)" || rc=$?
  assert_eq "1" "$rc" "a missing account must be refused"
  assert_contains "$err" "no such account"

  rc=0
  out="$(describe_account missing 2>/dev/null)" || rc=$?
  assert_eq "1" "$rc" "the missing-account refusal remains non-zero"
  assert_eq "" "$out" "a missing-account refusal writes nothing to stdout"
}

test_confirm_exact_name_requires_the_exact_name() {
  fake_root >/dev/null
  local err rc=0

  err="$(printf 'personal\n' | confirm_exact_name personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "the exact name confirms"
  assert_contains "$err" "type the account name 'personal' to confirm deletion"

  local bad
  for bad in y Y yes YES '' PERSONAL Personal pErSoNaL personal2 \
             ' personal' 'personal ' persona; do
    rc=0
    printf '%s\n' "$bad" | confirm_exact_name personal >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "input '$bad' must NOT confirm deletion of 'personal'"
  done

  rc=0
  confirm_exact_name personal </dev/null >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "EOF must not confirm"

  local out
  out="$(printf 'personal\n' | confirm_exact_name personal 2>/dev/null)"
  assert_eq "" "$out" "the confirmation prompt must not touch stdout"
}

test_account_in_use_detects_a_live_process_via_proc() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  add_account work 2>/dev/null
  if [[ ! -r /proc/self/environ ]]; then
    printf '  SKIP: /proc/<pid>/environ is not readable here\n' >&2
    return 0
  fi

  CLAUDE_CONFIG_DIR="$CLAUDE_MULTI_ROOT/personal" sleep 30 &
  local pid=$!
  trap "kill '$pid' 2>/dev/null || true; wait '$pid' 2>/dev/null || true" EXIT
  local tries=0
  while [[ ! -r "/proc/$pid/environ" && $tries -lt 50 ]]; do
    tries=$((tries + 1))
  done

  local rc=0 err
  err="$(account_in_use personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "a live process holding the config dir means in-use"
  assert_contains "$err" "$pid"

  rc=0
  account_in_use work >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "an untouched account is not in use"

  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - EXIT

  rc=0
  account_in_use personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "after the process exits the account is free"
}

test_account_in_use_skips_its_own_pid() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local procdir rc=0
  procdir="$(mktemp -d "${TMPDIR:-/tmp}/cm-proc.XXXXXX")"
  mkdir -p "$procdir/self" "$procdir/$$"
  printf 'probe\0' > "$procdir/self/environ"
  printf 'CLAUDE_CONFIG_DIR=%s\0' "$CLAUDE_MULTI_ROOT/personal" > "$procdir/$$/environ"

  CLAUDE_MULTI_PROC="$procdir" account_in_use personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "the in-use probe must skip its own pid"
  rm -rf -- "$procdir"
}

test_account_in_use_reports_undeterminable_without_proc_or_lsof() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local empty
  empty="$(mktemp -d "${TMPDIR:-/tmp}/cm-noproc.XXXXXX")"

  local rc=0 err out
  err="$(CLAUDE_MULTI_PROC="$empty" CLAUDE_MULTI_LSOF=cm-no-such-tool \
         account_in_use personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "2" "$rc" "no /proc and no lsof must report UNDETERMINABLE, not free"
  assert_contains "$err" "could not determine"

  rc=0
  out="$(CLAUDE_MULTI_PROC="$empty" CLAUDE_MULTI_LSOF=cm-no-such-tool \
         account_in_use personal 2>/dev/null)" || rc=$?
  assert_eq "2" "$rc" "the no-probe result remains undeterminable"
  assert_eq "" "$out" "the in-use check writes nothing to stdout"
  rm -rf -- "$empty"
}

test_account_in_use_uses_lsof_when_proc_is_missing() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local empty stub
  empty="$(mktemp -d "${TMPDIR:-/tmp}/cm-noproc.XXXXXX")"
  stub="$empty/lsof-stub"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "4242\n"' > "$stub"
  chmod 700 "$stub"

  local rc=0 err
  err="$(CLAUDE_MULTI_PROC="$empty" CLAUDE_MULTI_LSOF="$stub" \
         account_in_use personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "0" "$rc" "an lsof hit means in-use"
  assert_contains "$err" "4242"
  rm -rf -- "$empty"
}

test_account_in_use_handles_lsof_no_hit_as_free() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local empty stub rc=0
  empty="$(mktemp -d "${TMPDIR:-/tmp}/cm-noproc.XXXXXX")"
  stub="$empty/lsof-stub"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$stub"
  chmod 700 "$stub"

  CLAUDE_MULTI_PROC="$empty" CLAUDE_MULTI_LSOF="$stub" \
    account_in_use personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "lsof status 1 with no hits means definitely free"
  rm -rf -- "$empty"
}

test_account_in_use_fails_closed_on_lsof_error() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local empty stub rc=0 err
  empty="$(mktemp -d "${TMPDIR:-/tmp}/cm-noproc.XXXXXX")"
  stub="$empty/lsof-stub"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "probe failed\n" >&2' 'exit 2' > "$stub"
  chmod 700 "$stub"

  err="$(CLAUDE_MULTI_PROC="$empty" CLAUDE_MULTI_LSOF="$stub" \
         account_in_use personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "2" "$rc" "an lsof probe error must be undeterminable"
  assert_contains "$err" "could not determine"
  rm -rf -- "$empty"
}

test_account_in_use_never_reads_credentials_or_prints_environments() {
  local body
  body="$(sed -n '/^account_in_use()/,/^}/p' "$LIB_ACCOUNTS")"
  assert_eq "" "$(printf '%s\n' "$body" | grep -F 'credentials' || true)" \
            "the in-use check must not reference the credentials file"
  local leaks
  leaks="$(printf '%s\n' "$body" | grep -nE '(log|warn|printf)[^#]*environ' || true)"
  assert_eq "" "$leaks" "process environments must never be printed"
  assert_contains "$body" 'grep -qxF'
}

test_check_headroom_passes_with_room_and_refuses_without() {
  fake_root >/dev/null
  add_account personal 2>/dev/null

  local rc=0 out
  out="$(check_headroom personal 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "a temp filesystem with room must pass"
  assert_eq "" "$out" "the headroom check writes nothing to stdout"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/.trash")" \
            "the headroom check creates the trash directory on its filesystem"

  # Deterministic refusal: a df stub reporting 1 free block.
  df() { printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n/fake 100 99 1 99%% /fake\n'; }
  local err
  rc=0
  err="$(check_headroom personal 2>&1 >/dev/null)" || rc=$?
  unset -f df
  assert_eq "1" "$rc" "1K free must refuse"
  assert_contains "$err" "free"
  assert_contains "$err" "2x"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "a refused headroom check must change nothing"
}

test_check_headroom_refuses_when_df_says_nothing() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  df() { return 1; }
  local rc=0 err
  err="$(check_headroom personal 2>&1 >/dev/null)" || rc=$?
  unset -f df
  assert_eq "1" "$rc" "an unusable df must refuse, not pass"
  assert_contains "$err" "cannot measure free space"
}

test_archive_account_stages_a_private_credential_free_archive() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'not-a-real-token\n' > "$CLAUDE_MULTI_ROOT/personal/.credentials.json"
  mkdir -p "$CLAUDE_MULTI_ROOT/personal/projects/slug"
  printf 'transcript\n' > "$CLAUDE_MULTI_ROOT/personal/projects/slug/a.jsonl"
  printf 'prompts\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"

  local tgz listing extracted shape="no"
  tgz="$(archive_account personal 2>/dev/null)"
  assert_eq "yes" "$(yesno test -f "$tgz")" \
            "archive_account must print the path of a file it created"
  case "$tgz" in
    "$CLAUDE_MULTI_ROOT/.trash/personal-"*.tgz) shape="yes" ;;
  esac
  assert_eq "yes" "$shape" "the archive must be published under .trash"
  assert_eq "600" "$(stat -c '%a' "$tgz")" "the archive is mode 600"
  assert_eq "700" "$(stat -c '%a' "$CLAUDE_MULTI_ROOT/.trash")" \
            ".trash is mode 700"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '.tmp.*' -print)" \
            "successful publication must leave no staging artifact"

  listing="$(tar -tzf "$tgz")"
  assert_eq "" "$(printf '%s\n' "$listing" | grep -F 'credentials.json' || true)" \
            "the archive must NOT contain .credentials.json"
  assert_eq "" "$(printf '%s\n' "$listing" | grep -F '.claude.json' || true)" \
            "the archive must NOT contain .claude.json"
  assert_contains "$listing" "history.jsonl"
  assert_contains "$listing" "projects/slug/a.jsonl"

  extracted="$(mktemp -d "${TMPDIR:-/tmp}/cm-archive.XXXXXX")"
  tar -xzf "$tgz" -C "$extracted"
  assert_link "$extracted/CLAUDE.md" "../shared/CLAUDE.md"
  rm -rf -- "$extracted"

  assert_eq "not-a-real-token" \
            "$(cat "$CLAUDE_MULTI_ROOT/personal/.credentials.json")" \
            "archiving must not alter the live credentials"
  assert_eq '{"hasCompletedOnboarding":true,"projects":{}}' \
            "$(cat "$CLAUDE_MULTI_ROOT/personal/.claude.json")" \
            "archiving must not alter the live stub"
  assert_eq "transcript" \
            "$(cat "$CLAUDE_MULTI_ROOT/personal/projects/slug/a.jsonl")" \
            "archiving must leave account data untouched"
}

test_archive_account_cleans_staging_when_tar_fails() {
  fake_root >/dev/null
  add_account personal 2>/dev/null

  # The stub creates a partial file at tar's requested output path before
  # failing. This proves cleanup without relying on permission behavior under
  # root, and catches implementations that expose the final name to tar.
  tar() {
    local arg output="" take_next=0
    for arg in "$@"; do
      if (( take_next )); then
        output="$arg"
        break
      fi
      if [[ "$arg" == "-czf" ]]; then
        take_next=1
      fi
    done
    if [[ -n "$output" ]]; then
      printf 'partial archive\n' > "$output"
    fi
    return 2
  }

  local out_file err_file out err rc=0
  out_file="$(mktemp "${TMPDIR:-/tmp}/cm-archive-out.XXXXXX")"
  err_file="$(mktemp "${TMPDIR:-/tmp}/cm-archive-err.XXXXXX")"
  set +e
  archive_account personal >"$out_file" 2>"$err_file"
  rc=$?
  set -e
  out="$(cat "$out_file")"
  err="$(cat "$err_file")"
  rm -f -- "$out_file" "$err_file"

  assert_eq "1" "$rc" "a tar failure must fail the archive"
  assert_eq "" "$out" "a failed archive must not publish a path"
  assert_contains "$err" "backup failed"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '.tmp.*' -print)" \
            "a failed tar must leave no staging artifact"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '*.tgz' -print)" \
            "a failed tar must leave no final archive"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "the account must survive a failed archive"
}

test_archive_account_cleans_staging_when_atomic_rename_fails() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'history\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  mv() { return 1; }

  local rc=0 out err
  out="$(archive_account personal 2>/dev/null)" || rc=$?
  assert_eq "1" "$rc" "an atomic rename failure must fail the archive"
  assert_eq "" "$out" "a failed rename must not publish a path"

  rc=0
  err="$(archive_account personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "1" "$rc" "the rename failure remains non-zero"
  assert_contains "$err" "backup failed"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '.tmp.*' -print)" \
            "a failed rename must clean the staging archive"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '*.tgz' -print)" \
            "a failed rename must never expose a final archive"
  assert_eq "history" "$(cat "$CLAUDE_MULTI_ROOT/personal/history.jsonl")" \
            "the account must survive a failed rename"
}

test_verify_archive_accepts_a_good_archive_without_rereading_it() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'prompts\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  local tgz rc=0 out
  tgz="$(archive_account personal 2>/dev/null)"

  out="$(verify_archive "$tgz" 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "a freshly written archive verifies"
  assert_eq "" "$out" "archive verification writes nothing to stdout"

  # A one-call tar seam protects the single-read contract independently of the
  # real-archive checks above and below. A verifier that lists the archive once
  # per check turns this literal call count into a failure.
  local probe="$CLAUDE_MULTI_ROOT/.trash/probe.tgz"
  local calls="$CLAUDE_MULTI_ROOT/.trash/tar.calls"
  printf 'nonempty\n' > "$probe"
  tar() {
    printf 'call\n' >> "$calls"
    printf './\n./history.jsonl\n'
  }
  verify_archive "$probe" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "one successful full listing is sufficient"
  assert_eq "1" "$(wc -l < "$calls" | tr -d '[:space:]')" \
            "verify_archive must read an untrusted archive only once"
}

test_verify_archive_rejects_missing_and_empty_archives() {
  fake_root >/dev/null
  mkdir -p "$CLAUDE_MULTI_ROOT/.trash"
  local missing="$CLAUDE_MULTI_ROOT/.trash/missing.tgz"
  local empty="$CLAUDE_MULTI_ROOT/.trash/empty.tgz"
  : > "$empty"

  local path rc err out
  for path in "$missing" "$empty"; do
    rc=0
    err="$(verify_archive "$path" 2>&1 >/dev/null)" || rc=$?
    assert_eq "1" "$rc" "a missing or empty archive must fail closed"
    assert_contains "$err" "missing or empty"

    rc=0
    out="$(verify_archive "$path" 2>/dev/null)" || rc=$?
    assert_eq "1" "$rc" "the missing or empty result remains non-zero"
    assert_eq "" "$out" "archive verification failures must not touch stdout"
  done
}

test_verify_archive_rejects_a_truncated_archive() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  head -c 200000 /dev/zero | tr '\0' 'z' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  local tgz size half rc=0 err
  tgz="$(archive_account personal 2>/dev/null)"
  size="$(stat -c '%s' "$tgz")"
  half=$(( size / 2 ))
  head -c "$half" "$tgz" > "$tgz.part"
  mv -- "$tgz.part" "$tgz"

  err="$(verify_archive "$tgz" 2>&1 >/dev/null)" || rc=$?
  assert_eq "1" "$rc" "a truncated archive must NOT verify"
  assert_contains "$err" "unreadable or truncated"
}

test_verify_archive_rejects_an_archive_carrying_excluded_files() {
  fake_root >/dev/null
  local creds_src="$CLAUDE_MULTI_ROOT/bad-creds-src"
  local stub_src="$CLAUDE_MULTI_ROOT/bad-stub-src"
  mkdir -p "$CLAUDE_MULTI_ROOT/.trash" "$creds_src" "$stub_src"
  printf 'not-a-real-token\n' > "$creds_src/.credentials.json"
  printf 'history\n' > "$creds_src/history.jsonl"
  printf '{}\n' > "$stub_src/.claude.json"
  printf 'history\n' > "$stub_src/history.jsonl"

  local bad_creds="$CLAUDE_MULTI_ROOT/.trash/credentials-bad.tgz"
  local bad_stub="$CLAUDE_MULTI_ROOT/.trash/stub-bad.tgz"
  tar -czf "$bad_creds" -C "$creds_src" .
  tar -czf "$bad_stub" -C "$stub_src" .

  local bad rc err
  for bad in "$bad_creds" "$bad_stub"; do
    rc=0
    err="$(verify_archive "$bad" 2>&1 >/dev/null)" || rc=$?
    assert_eq "1" "$rc" "each excluded file must independently fail verification"
    assert_contains "$err" "contains an excluded file"
  done
}

test_verify_archive_rejects_an_implausibly_empty_archive() {
  fake_root >/dev/null
  mkdir -p "$CLAUDE_MULTI_ROOT/.trash" "$CLAUDE_MULTI_ROOT/empty-src"
  local empty="$CLAUDE_MULTI_ROOT/.trash/implausible.tgz"
  tar -czf "$empty" -C "$CLAUDE_MULTI_ROOT/empty-src" .

  local rc=0 err
  err="$(verify_archive "$empty" 2>&1 >/dev/null)" || rc=$?
  assert_eq "1" "$rc" "a one-entry archive must NOT verify"
  assert_contains "$err" "too few entries"
}

test_prune_trash_keeps_newest_regular_archives_and_unrelated_entries() {
  fake_root >/dev/null
  local trash="$CLAUDE_MULTI_ROOT/.trash"
  mkdir -p "$trash/nested" "$trash/0000-directory.tgz"
  local n
  for n in 20260101T000000Z 20260202T000000Z 20260303T000000Z \
           20260404T000000Z 20260505T000000Z; do
    printf 'archive\n' > "$trash/personal-$n.tgz"
  done
  printf 'keep me\n' > "$trash/notes.txt"
  printf 'nested archive\n' > "$trash/nested/work-20200101T000000Z.tgz"
  printf 'outside\n' > "$CLAUDE_MULTI_ROOT/outside"
  ln -s ../outside "$trash/0000-link.tgz"

  local err out
  err="$(prune_trash 3 2>&1 >/dev/null)"
  out="$(prune_trash 3 2>/dev/null)"
  assert_eq "" "$out" "prune_trash writes nothing to stdout"
  assert_contains "$err" "20260101T000000Z"
  assert_contains "$err" "20260202T000000Z"

  assert_eq "yes" "$(yesno test -f "$trash/personal-20260505T000000Z.tgz")" \
            "the newest archive must be kept"
  assert_eq "yes" "$(yesno test -f "$trash/personal-20260404T000000Z.tgz")" \
            "the second-newest archive must be kept"
  assert_eq "yes" "$(yesno test -f "$trash/personal-20260303T000000Z.tgz")" \
            "the third-newest archive must be kept"
  assert_eq "no" "$(yesno test -e "$trash/personal-20260202T000000Z.tgz")" \
            "the fourth-newest archive must be pruned"
  assert_eq "no" "$(yesno test -e "$trash/personal-20260101T000000Z.tgz")" \
            "the oldest archive must be pruned"
  assert_eq "yes" "$(yesno test -f "$trash/notes.txt")" \
            "an unrelated file must be preserved"
  assert_eq "yes" "$(yesno test -f "$trash/nested/work-20200101T000000Z.tgz")" \
            "nested archives are outside the literal top-level glob"
  assert_eq "yes" "$(yesno test -d "$trash/0000-directory.tgz")" \
            "a directory ending in .tgz is not a regular archive entry"
  assert_eq "yes" "$(yesno test -L "$trash/0000-link.tgz")" \
            "a symlink ending in .tgz must never be pruned"
  assert_eq "outside" "$(cat "$CLAUDE_MULTI_ROOT/outside")" \
            "pruning must not alter a symlink target"
}

test_prune_trash_succeeds_when_absent_or_short() {
  fake_root >/dev/null
  local rc=0 out
  out="$(prune_trash 3 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "an absent .trash is not an error"
  assert_eq "" "$out" "the absent-trash case writes nothing to stdout"

  mkdir -p "$CLAUDE_MULTI_ROOT/.trash"
  printf 'a\n' > "$CLAUDE_MULTI_ROOT/.trash/personal-20260101T000000Z.tgz"
  rc=0
  prune_trash 3 >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "fewer archives than the keep count is not an error"
  assert_eq "yes" \
            "$(yesno test -f "$CLAUDE_MULTI_ROOT/.trash/personal-20260101T000000Z.tgz")" \
            "nothing may be pruned below the keep count"
}

test_prune_trash_uses_default_three_and_honors_env_override() {
  fake_root >/dev/null
  local trash="$CLAUDE_MULTI_ROOT/.trash" n
  mkdir -p "$trash"
  for n in 20260101T000000Z 20260202T000000Z 20260303T000000Z \
           20260404T000000Z; do
    printf 'archive\n' > "$trash/personal-$n.tgz"
  done

  prune_trash >/dev/null 2>&1
  assert_eq "no" "$(yesno test -e "$trash/personal-20260101T000000Z.tgz")" \
            "the default policy must retain exactly the newest three"
  assert_eq "yes" "$(yesno test -f "$trash/personal-20260202T000000Z.tgz")" \
            "the oldest of the default three must survive"

  CLAUDE_MULTI_TRASH_KEEP=1 prune_trash >/dev/null 2>&1
  assert_eq "yes" "$(yesno test -f "$trash/personal-20260404T000000Z.tgz")" \
            "the newest archive survives keep=1"
  assert_eq "no" "$(yesno test -e "$trash/personal-20260303T000000Z.tgz")" \
            "the environment keep=1 policy prunes the rest"
}

test_prune_trash_rejects_malformed_or_zero_retention_without_removing() {
  fake_root >/dev/null
  local trash="$CLAUDE_MULTI_ROOT/.trash" n bad rc err
  mkdir -p "$trash"
  for n in 20260101T000000Z 20260202T000000Z; do
    printf 'archive\n' > "$trash/work-$n.tgz"
  done

  for bad in '' 0 -1 +1 01 08 1.5 1x ' 1' '1 ' '1+1'; do
    rc=0
    err="$(prune_trash "$bad" 2>&1 >/dev/null)" || rc=$?
    assert_eq "1" "$rc" "retention '$bad' must fail closed"
    assert_contains "$err" "positive decimal integer"
    assert_eq "yes" "$(yesno test -f "$trash/work-20260101T000000Z.tgz")" \
              "invalid retention must not prune the oldest archive"
    assert_eq "yes" "$(yesno test -f "$trash/work-20260202T000000Z.tgz")" \
              "invalid retention must not prune the newest archive"
  done

  rc=0
  CLAUDE_MULTI_TRASH_KEEP=garbage prune_trash >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a malformed environment policy must fail closed"
  assert_eq "yes" "$(yesno test -f "$trash/work-20260101T000000Z.tgz")" \
            "a malformed environment policy must remove nothing"
}

test_prune_trash_handles_a_huge_canonical_keep_without_arithmetic_overflow() {
  fake_root >/dev/null
  local trash="$CLAUDE_MULTI_ROOT/.trash" rc=0
  mkdir -p "$trash"
  printf 'archive\n' > "$trash/work-20260101T000000Z.tgz"

  prune_trash 999999999999999999999999999999999999 >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "a huge canonical keep count safely means keep everything"
  assert_eq "yes" "$(yesno test -f "$trash/work-20260101T000000Z.tgz")" \
            "a huge keep count must not trigger arithmetic pruning"
}

test_purge_account_removes_only_the_literal_validated_account() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  add_account work 2>/dev/null
  mkdir -p "$CLAUDE_MULTI_ROOT/personal/projects/slug"
  printf 'private account data\n' > "$CLAUDE_MULTI_ROOT/personal/projects/slug/history.jsonl"

  local rc=0 out
  out="$(purge_account personal 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "a real validated account directory may be purged"
  assert_eq "" "$out" "purge_account writes nothing to stdout"
  assert_eq "no" "$(yesno test -e "$CLAUDE_MULTI_ROOT/personal")" \
            "purge must remove the selected account directory"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/work")" \
            "purge must not touch another account"
  assert_eq "yes" "$(yesno test -f "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md")" \
            "purge must not follow the account's links into shared"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/shared/agents")" \
            "shared directories must survive"
}

test_purge_account_refuses_reserved_invalid_missing_and_non_directory_targets() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local n rc out

  for n in shared .trash plugin-cache project-memory '' '..' '../../etc' \
           'no space' under_score '-leading' 'unicodé'; do
    rc=0
    out="$(purge_account "$n" 2>/dev/null)" || rc=$?
    assert_eq "1" "$rc" "purge_account must refuse '$n'"
    assert_eq "" "$out" "a purge refusal must not touch stdout"
  done
  assert_eq "yes" "$(yesno test -f "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md")" \
            "shared was damaged by a refused purge"

  rc=0
  purge_account ghost >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a nonexistent account is refused"

  printf 'not a directory\n' > "$CLAUDE_MULTI_ROOT/ordinary-file"
  rc=0
  purge_account ordinary-file >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a regular-file target is refused"

  ln -s "$CLAUDE_MULTI_ROOT/shared" "$CLAUDE_MULTI_ROOT/sneaky"
  rc=0
  purge_account sneaky >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a symlinked account target is refused"
  assert_eq "yes" "$(yesno test -L "$CLAUDE_MULTI_ROOT/sneaky")" \
            "the refused target symlink must remain"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "no refusal may delete an unrelated account"
}

test_purge_account_refuses_unsafe_or_ambiguous_roots_before_removal() {
  local base
  fake_root >/dev/null
  base="${HOME%/home}"
  add_account personal 2>/dev/null
  mkdir -p "$HOME/child" "$HOME/personal"
  printf 'home sentinel\n' > "$HOME/personal/sentinel"
  printf 'not a root directory\n' > "$HOME/root-file"
  ln -s "$CLAUDE_MULTI_ROOT" "$base/root-link"

  # Intercept rm in this refusal-only test so even a mutant missing every guard
  # cannot target /personal or another non-fixture path during the RED phase.
  local rm_calls="$base/rm.calls"
  rm() {
    printf 'called\n' >> "$rm_calls"
    return 0
  }
  multi_root() {
    printf '%s\n' "$PURGE_TEST_ROOT"
  }

  local unsafe rc out
  for unsafe in '' / "$HOME" relative/root "$HOME/child/.." \
                "$HOME/missing-root" "$HOME/root-file" "$base/root-link"; do
    PURGE_TEST_ROOT="$unsafe"
    rc=0
    out="$(purge_account personal 2>/dev/null)" || rc=$?
    assert_eq "1" "$rc" "unsafe root '$unsafe' must be refused"
    assert_eq "" "$out" "an unsafe-root refusal must keep stdout empty"
  done

  assert_eq "no" "$(yesno test -e "$rm_calls")" \
            "no unsafe or ambiguous root may reach rm"
  assert_eq "home sentinel" "$(cat "$HOME/personal/sentinel")" \
            "a root resolving to HOME must not delete a HOME child"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "a symlinked root refusal must leave its target account intact"
}

test_purge_account_has_exactly_one_structurally_guarded_recursive_rm() {
  local body recursive exact
  body="$(sed -n '/^purge_account()/,/^}/p' "$LIB_ACCOUNTS")"
  assert_contains "$body" 'validate_name'
  assert_contains "$body" 'is_reserved_name'
  assert_contains "$body" 'validate_root_path'
  assert_contains "$body" '[[ -L "$target" ]]'
  assert_contains "$body" '[[ ! -d "$target" ]]'

  recursive="$(grep -cE '\brm[[:space:]]+-rf\b' "$LIB_ACCOUNTS" || true)"
  exact="$(printf '%s\n' "$body" | grep -cF 'rm -rf -- "$root/$name"' || true)"
  assert_eq "1" "$recursive" \
            "accounts must contain exactly one recursive removal"
  assert_eq "1" "$exact" \
            "the only recursive removal must use the literal validated root/name path"
}

test_delete_account_happy_path_archives_data_then_removes_only_target() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  add_account work 2>/dev/null
  printf 'not-a-real-token\n' > "$CLAUDE_MULTI_ROOT/personal/.credentials.json"
  printf 'prompts\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  mkdir -p "$CLAUDE_MULTI_ROOT/personal/projects/slug"
  printf 'transcript\n' > "$CLAUDE_MULTI_ROOT/personal/projects/slug/a.jsonl"

  local out rc=0
  out="$(printf 'personal\n' | delete_account personal 2>/dev/null)" || rc=$?
  assert_eq "0" "$rc" "the fully guarded happy path succeeds"
  assert_eq "" "$out" "delete_account writes nothing to stdout"
  assert_eq "no" "$(yesno test -e "$CLAUDE_MULTI_ROOT/personal")" \
            "the selected account must be gone"
  assert_eq "work" "$(list_accounts)" "only the target account was deleted"
  assert_eq "yes" "$(yesno test -f "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md")" \
            "shared data must survive account removal"

  local tgz listing
  tgz="$(find "$CLAUDE_MULTI_ROOT/.trash" -maxdepth 1 -type f \
               -name 'personal-*.tgz' -print | head -n 1)"
  assert_eq "yes" "$(yesno test -n "$tgz")" "a verified backup archive must remain"
  listing="$(tar -tzf "$tgz")"
  assert_eq "" "$(printf '%s\n' "$listing" | grep -F 'credentials.json' || true)" \
            "the backup must exclude credentials"
  assert_eq "" "$(printf '%s\n' "$listing" | grep -F '.claude.json' || true)" \
            "the backup must exclude the onboarding stub"
  assert_contains "$listing" "history.jsonl"
  assert_contains "$listing" "projects/slug/a.jsonl"
}

test_delete_account_bare_y_refuses_before_archiving_with_zero_stdout() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local rc=0 err
  err="$(printf 'y\n' | delete_account personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "1" "$rc" "a bare y must fail the typed-name gate"
  assert_contains "$err" "does not match"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "a bare y must not delete the account"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '*.tgz' -print 2>/dev/null)" \
            "a confirmation refusal creates no archive"
  assert_stdout_empty_bytes feed y delete_account personal
}

test_delete_account_leaves_data_and_no_artifact_when_tar_fails() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'payload\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"

  tar() {
    local arg output="" take_next=0
    for arg in "$@"; do
      if (( take_next )); then output="$arg"; break; fi
      if [[ "$arg" == "-czf" ]]; then take_next=1; fi
    done
    if [[ -n "$output" ]]; then printf 'partial\n' > "$output"; fi
    return 2
  }

  local rc=0 err
  err="$(printf 'personal\n' | delete_account personal 2>&1 >/dev/null)" || rc=$?
  assert_eq "1" "$rc" "a deterministic tar failure fails the delete"
  assert_contains "$err" "NOT deleted"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "the account must survive a failed archive"
  assert_eq "payload" "$(cat "$CLAUDE_MULTI_ROOT/personal/history.jsonl")" \
            "account data must remain intact after tar failure"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" \
                         \( -name '*.tgz' -o -name '.tmp.*' \) -print 2>/dev/null)" \
            "a failed archive must leave neither final nor staging artifacts"
}

test_delete_account_refuses_a_real_in_use_process_before_archiving() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  if [[ ! -r /proc/self/environ ]]; then
    printf '  SKIP: /proc/<pid>/environ is not readable here\n' >&2
    return 0
  fi

  CLAUDE_CONFIG_DIR="$CLAUDE_MULTI_ROOT/personal" sleep 30 &
  local pid=$! tries=0
  trap "kill '$pid' 2>/dev/null || true; wait '$pid' 2>/dev/null || true" EXIT
  while [[ ! -r "/proc/$pid/environ" && $tries -lt 50 ]]; do
    tries=$(( tries + 1 ))
  done

  local rc=0 err
  err="$(printf 'personal\n' | delete_account personal 2>&1 >/dev/null)" || rc=$?
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  trap - EXIT

  assert_eq "1" "$rc" "a real process using the account must refuse deletion"
  assert_contains "$err" "in use"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "an in-use account must remain"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '*.tgz' -print 2>/dev/null)" \
            "in-use refusal must precede archiving"
}

test_delete_account_distinguishes_stubbed_free_in_use_and_unknown_statuses() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local USE_RC calls="$CLAUDE_MULTI_ROOT/use.calls"
  account_in_use() {
    printf '%s\n' "$USE_RC" >> "$calls"
    return "$USE_RC"
  }

  local rc status
  for status in 0 2; do
    USE_RC="$status"
    rc=0
    printf 'personal\n' | delete_account personal >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "account_in_use status $status must refuse deletion"
    assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
              "status $status must leave the account intact"
  done

  USE_RC=1
  rc=0
  printf 'wrong-name\n' | delete_account personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "free status 1 must continue to the typed-name gate"
  assert_eq "0
2
1" "$(cat "$calls")" \
            "the composed path must preserve all three status meanings"
}

test_delete_account_refuses_when_real_use_probe_is_undeterminable() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local empty rc=0 err
  empty="$(mktemp -d "${TMPDIR:-/tmp}/cm-noproc.XXXXXX")"
  err="$(printf 'personal\n' \
         | CLAUDE_MULTI_PROC="$empty" CLAUDE_MULTI_LSOF=cm-no-such-tool \
           delete_account personal 2>&1 >/dev/null)" || rc=$?
  rmdir "$empty"

  assert_eq "1" "$rc" "an undeterminable real use probe must refuse"
  assert_contains "$err" "could not determine"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "an unknown use state must leave the account intact"
}

test_delete_account_headroom_and_verification_failures_preserve_state() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'payload\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"

  df() {
    printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
    printf '/fake 100 99 1 99%% /fake\n'
  }
  local rc=0
  printf 'personal\n' | delete_account personal >/dev/null 2>&1 || rc=$?
  unset -f df
  assert_eq "1" "$rc" "insufficient headroom must refuse"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "headroom failure must leave the account"
  assert_eq "" "$(find "$CLAUDE_MULTI_ROOT/.trash" -name '*.tgz' -print 2>/dev/null)" \
            "headroom failure must precede archive creation"

  printf 'older backup\n' > "$CLAUDE_MULTI_ROOT/.trash/preexisting.tgz"
  verify_archive() {
    log "backup verification failed: forced"
    return 1
  }
  rc=0
  printf 'personal\n' | delete_account personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "forced archive verification failure must refuse"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "verification failure must leave the account"
  assert_eq "older backup" "$(cat "$CLAUDE_MULTI_ROOT/.trash/preexisting.tgz")" \
            "verification cleanup must preserve older archives"
  assert_eq "preexisting.tgz" \
            "$(find "$CLAUDE_MULTI_ROOT/.trash" -maxdepth 1 -type f -name '*.tgz' \
                    -printf '%f\n' | LC_ALL=C sort)" \
            "verification cleanup must remove only the newly created archive"
}

test_delete_account_never_prunes_when_purge_fails() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'payload\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  local marker="$CLAUDE_MULTI_ROOT/prune.called" archive
  purge_account() { return 1; }
  prune_trash() { printf 'called\n' > "$marker"; }

  local rc=0
  printf 'personal\n' | delete_account personal >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "purge failure must fail the composed delete"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "purge failure must leave the account intact"
  assert_eq "no" "$(yesno test -e "$marker")" \
            "pruning must occur only after a successful purge"
  archive="$(find "$CLAUDE_MULTI_ROOT/.trash" -maxdepth 1 -type f \
                  -name 'personal-*.tgz' -print -quit)"
  assert_eq "yes" "$(yesno test -n "$archive")" \
            "a verified archive must be kept when purge fails"
}

test_delete_account_refuses_nonexistent_reserved_and_symlink_targets() {
  fake_root >/dev/null
  add_account personal 2>/dev/null
  local rc n

  rc=0
  printf 'ghost\n' | delete_account ghost >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a nonexistent account is refused"
  for n in shared .trash plugin-cache project-memory; do
    rc=0
    printf '%s\n' "$n" | delete_account "$n" >/dev/null 2>&1 || rc=$?
    assert_eq "1" "$rc" "delete_account must refuse reserved name '$n'"
  done
  ln -s "$CLAUDE_MULTI_ROOT/personal" "$CLAUDE_MULTI_ROOT/sneaky"
  rc=0
  printf 'sneaky\n' | delete_account sneaky >/dev/null 2>&1 || rc=$?
  assert_eq "1" "$rc" "a symlinked account target must be refused before archiving"
  assert_eq "yes" "$(yesno test -d "$CLAUDE_MULTI_ROOT/personal")" \
            "all early refusals must leave real accounts intact"
  assert_stdout_empty_bytes feed ghost delete_account ghost
}

test_delete_account_stage_order_is_structural() {
  local body line_of
  body="$(sed -n '/^delete_account()/,/^}/p' "$LIB_ACCOUNTS")"
  line_of() {
    printf '%s\n' "$body" | grep -n "$1" | head -n 1 | cut -d: -f1
  }
  local valid reserved exists in_use describe confirm headroom archive verify purge prune
  valid="$(line_of 'validate_name')"
  reserved="$(line_of 'is_reserved_name')"
  exists="$(line_of '\[\[.*-d.*\$acct')"
  in_use="$(line_of 'account_in_use')"
  describe="$(line_of 'describe_account')"
  confirm="$(line_of 'confirm_exact_name')"
  headroom="$(line_of 'check_headroom')"
  archive="$(line_of 'archive_account')"
  verify="$(line_of 'verify_archive')"
  purge="$(line_of 'purge_account')"
  prune="$(line_of 'prune_trash')"
  assert_eq "yes" \
            "$(yesno test -n "$valid$reserved$exists$in_use$describe$confirm$headroom$archive$verify$purge$prune")" \
            "delete_account must call every required guard and stage"
  assert_eq "yes" "$(yesno test "$valid" -lt "$reserved")" "validate precedes reserved check"
  assert_eq "yes" "$(yesno test "$reserved" -lt "$exists")" "reserved check precedes existence"
  assert_eq "yes" "$(yesno test "$exists" -lt "$in_use")" "existence precedes in-use"
  assert_eq "yes" "$(yesno test "$in_use" -lt "$describe")" "in-use precedes description"
  assert_eq "yes" "$(yesno test "$describe" -lt "$confirm")" "description precedes confirmation"
  assert_eq "yes" "$(yesno test "$confirm" -lt "$headroom")" "confirmation precedes headroom"
  assert_eq "yes" "$(yesno test "$headroom" -lt "$archive")" "headroom precedes archiving"
  assert_eq "yes" "$(yesno test "$archive" -lt "$verify")" "archive precedes verification"
  assert_eq "yes" "$(yesno test "$verify" -lt "$purge")" "verification precedes purge"
  assert_eq "yes" "$(yesno test "$purge" -lt "$prune")" "purge precedes pruning"
}

test_entry_point_sources_memory_then_accounts_once_and_exports_the_surface() {
  local bin="$REPO_ROOT/bin/claude-multi" sources rc=0
  sources="$(grep -E '^source "\$CLAUDE_MULTI_LIB/(memory|accounts)\.sh"$' "$bin" || true)"
  assert_eq 'source "$CLAUDE_MULTI_LIB/memory.sh"
source "$CLAUDE_MULTI_LIB/accounts.sh"' "$sources" \
            "the entry point must source memory then accounts exactly once"

  bash -c 'set -euo pipefail
    source "$1"
    for f in list_accounts account_status add_account offer_launch \
             describe_account confirm_exact_name account_in_use check_headroom \
             archive_account verify_archive prune_trash purge_account \
             delete_account; do
      declare -F "$f" >/dev/null \
        || { printf "missing: %s\n" "$f" >&2; exit 1; }
    done' _ "$bin" || rc=$?
  assert_eq "0" "$rc" "the sourced entry point exports the complete account surface"
}

test_entry_point_account_wiring_is_canonical_and_credential_free() {
  local bin="$REPO_ROOT/bin/claude-multi" hits
  hits="$(grep -nE 'CM_LIB|LIB_DIR|\.credentials\.json' "$bin" || true)"
  assert_eq "" "$hits" \
            "entrypoint wiring must use CLAUDE_MULTI_LIB without credential handling"
}

test_no_account_cli_verbs_were_introduced() {
  local bin="$REPO_ROOT/bin/claude-multi" hits
  hits="$(grep -nE '^[[:space:]]*(add|delete|sync|doctor)\)' "$bin" || true)"
  assert_eq "" "$hits" "add/delete/sync/doctor must never become argv verbs"
}

test_accounts_lib_never_repairs_from_doctor() {
  local hits
  hits="$(grep -nE '(^|[^[:alnum:]_])doctor(_report)?[[:space:]]*\(' \
                 "$LIB_ACCOUNTS" || true)"
  assert_eq "" "$hits" "lib/accounts.sh must not invoke a doctor repair path"
  assert_contains "$(cat "$LIB_ACCOUNTS")" 'heal_account "$name"'
}

test_account_channels_keep_mutators_empty_and_data_producers_visible() {
  fake_root >/dev/null
  assert_stdout_empty_bytes add_account personal
  CLAUDE_MULTI_NO_LAUNCH=1
  assert_stdout_empty_bytes offer_launch personal
  unset CLAUDE_MULTI_NO_LAUNCH
  assert_stdout_empty_bytes describe_account personal
  assert_stdout_empty_bytes check_headroom personal
  assert_stdout_empty_bytes prune_trash 3

  assert_eq "personal" "$(list_accounts)" "list_accounts returns data on stdout"
  assert_eq "no-credentials" "$(account_status personal)" \
            "account_status returns its status word on stdout"
  printf 'prompts\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  local tgz
  tgz="$(archive_account personal 2>/dev/null)"
  assert_eq "yes" "$(yesno test -f "$tgz")" \
            "archive_account returns its archive path on stdout"
  assert_stdout_empty_bytes feed personal delete_account personal
}

test_account_operations_leave_the_runner_protected_root_unchanged() {
  local protected_root="$REAL_HOME/.claude-multi"
  assert_eq "no" "$(yesno test -e "$protected_root")" \
            "the runner's protected root starts absent"

  fake_root >/dev/null
  add_account personal 2>/dev/null
  printf 'fixture data\n' > "$CLAUDE_MULTI_ROOT/personal/history.jsonl"
  printf 'personal\n' | delete_account personal >/dev/null 2>&1

  assert_eq "no" "$(yesno test -e "$protected_root")" \
            "account operations must not create or mutate the protected root"
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
