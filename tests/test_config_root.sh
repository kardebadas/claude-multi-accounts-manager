# shellcheck shell=bash
# tests/test_config_root.sh — where things live. Pure getters: no side effects,
# no exits, no stdout leaks outside a command substitution.
#
# Invoked as `bash tests/test_config_root.sh` (by tests/run.sh, or by hand) with
# REPO_ROOT and TEST_TMP exported. Not executable, no shebang.
#
# Every test lives in a function named test_*, and the dispatcher at the bottom
# runs each one in its own subshell so a failure is reported rather than
# aborting the file, and so a test's exported CLAUDE_MULTI_ROOT / HOME cannot
# leak into the next one.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"
source "$REPO_ROOT/lib/config.sh"

# byte-exact size of a file, digits only
_bytes() {
  local n
  n="$(wc -c <"$1")"
  printf '%s' "${n//[[:space:]]/}"
}

# ── multi_root: CLAUDE_MULTI_ROOT wins ───────────────────────────────────────
test_multi_root_honours_the_override() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r1"
  assert_eq "$TEST_TMP/r1" "$(multi_root)"
}

test_multi_root_strips_trailing_slashes() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r1/"
  assert_eq "$TEST_TMP/r1" "$(multi_root)" "a trailing slash is stripped"
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r1///"
  assert_eq "$TEST_TMP/r1" "$(multi_root)" "several trailing slashes are stripped"
  # "/" is a legitimate absolute path and must not be stripped to "".
  export CLAUDE_MULTI_ROOT="/"
  assert_eq "/" "$(multi_root)" "the root directory survives stripping"
}

test_multi_root_survives_a_space() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/with space"
  assert_eq "$TEST_TMP/with space" "$(multi_root)"
}

# ── multi_root: the HOME fallback, proved rather than inspected ──────────────
test_multi_root_falls_back_to_home() {
  export CLAUDE_MULTI_ROOT=""
  assert_eq "$HOME/.claude-multi" "$(multi_root)" "empty falls back to HOME"
  unset CLAUDE_MULTI_ROOT
  assert_eq "$HOME/.claude-multi" "$(multi_root)" "unset falls back to HOME"
}

# The value must be read from $HOME at call time, not captured when the library
# was sourced: two calls under two different HOMEs must give two answers.
test_multi_root_reads_home_at_call_time() {
  unset CLAUDE_MULTI_ROOT
  local a b
  a="$(HOME="$TEST_TMP/home-a"; multi_root)"
  b="$(HOME="$TEST_TMP/home-b"; multi_root)"
  assert_eq "$TEST_TMP/home-a/.claude-multi" "$a"
  assert_eq "$TEST_TMP/home-b/.claude-multi" "$b" "HOME must not be cached at source time"
}

test_multi_root_normalises_a_home_with_trailing_slashes() {
  unset CLAUDE_MULTI_ROOT
  assert_eq "$TEST_TMP/home-a/.claude-multi" "$(HOME="$TEST_TMP/home-a//"; multi_root)"
  assert_eq "/.claude-multi" "$(HOME="/"; multi_root)" "HOME=/ must not double the slash"
}

# Nothing in this project may resolve against the developer's real home.
test_multi_root_never_points_at_the_real_home() {
  unset CLAUDE_MULTI_ROOT
  local root
  root="$(multi_root)"
  assert_eq "$HOME/.claude-multi" "$root"
  if [[ -n "${REAL_HOME_GUARD:-}" && "$root" == "$REAL_HOME_GUARD/"* ]]; then
    printf '  FAIL: multi_root resolved into the real home: [%s]\n' "$root" >&2
    return 1
  fi
  return 0
}

# ── multi_root is a DATA PRODUCER ────────────────────────────────────────────
# Its value is consumed as "$(multi_root)", so it belongs on stdout and nowhere
# else. This test fails if the value is ever moved to stderr, and fails if a
# diagnostic is ever added to the happy path.
test_multi_root_writes_its_value_to_stdout_only() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/chan"
  local out="$TEST_TMP/chan.out" err="$TEST_TMP/chan.err"
  multi_root >"$out" 2>"$err"
  assert_eq "$TEST_TMP/chan" "$(cat "$out")" "the root must arrive on stdout"
  assert_eq "0" "$(_bytes "$err")" "multi_root must write nothing to stderr"
}

test_derived_getters_write_their_value_to_stdout_only() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/chan"
  local out="$TEST_TMP/d.out" err="$TEST_TMP/d.err"
  shared_dir >"$out" 2>"$err"
  assert_eq "$TEST_TMP/chan/shared" "$(cat "$out")"
  assert_eq "0" "$(_bytes "$err")" "shared_dir must write nothing to stderr"
  trash_dir >"$out" 2>"$err"
  assert_eq "$TEST_TMP/chan/.trash" "$(cat "$out")"
  assert_eq "0" "$(_bytes "$err")" "trash_dir must write nothing to stderr"
  account_dir work >"$out" 2>"$err"
  assert_eq "$TEST_TMP/chan/work" "$(cat "$out")"
  assert_eq "0" "$(_bytes "$err")" "account_dir must write nothing to stderr"
}

# ── derived paths ────────────────────────────────────────────────────────────
test_derived_paths() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r1"
  assert_eq "$TEST_TMP/r1/shared" "$(shared_dir)"
  assert_eq "$TEST_TMP/r1/.trash" "$(trash_dir)"
  assert_eq "$TEST_TMP/r1/work" "$(account_dir work)"
  assert_eq "$TEST_TMP/r1/personal-mother" "$(account_dir personal-mother)"
  assert_fails account_dir ""
  assert_fails account_dir
  assert_no_stdout account_dir ""
}

test_derived_paths_track_the_override() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r2"
  assert_eq "$TEST_TMP/r2/shared" "$(shared_dir)" "shared_dir must follow the seam"
  assert_eq "$TEST_TMP/r2/.trash" "$(trash_dir)"
  unset CLAUDE_MULTI_ROOT
  assert_eq "$HOME/.claude-multi/shared" "$(shared_dir)"
}

# A root of "/" is pathological but legitimate, and multi_root already pins it
# (test_multi_root_strips_trailing_slashes). The derived getters must apply the
# same normalisation multi_root applies to HOME=/, so composing a suffix onto
# it yields "/shared" and not "//shared". Cosmetic on Linux, which collapses
# the two, but a path that is compared as a string rather than resolved makes
# the inconsistency a real defect.
test_derived_paths_do_not_double_the_slash_at_the_filesystem_root() {
  export CLAUDE_MULTI_ROOT="/"
  assert_eq "/" "$(multi_root)" "the root directory survives stripping"
  assert_eq "/shared" "$(shared_dir)" "a root of / must not produce //shared"
  assert_eq "/.trash" "$(trash_dir)" "a root of / must not produce //.trash"
  assert_eq "/work" "$(account_dir work)" "a root of / must not produce //work"
}

# The same composition, one level down: a root given with trailing slashes is
# normalised once, in multi_root, and every derived getter inherits that.
test_derived_paths_normalise_a_root_given_with_a_trailing_slash() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r1/"
  assert_eq "$TEST_TMP/r1/shared" "$(shared_dir)" "one trailing slash"
  assert_eq "$TEST_TMP/r1/.trash" "$(trash_dir)"
  assert_eq "$TEST_TMP/r1/work" "$(account_dir work)"
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r1///"
  assert_eq "$TEST_TMP/r1/shared" "$(shared_dir)" "several trailing slashes"
  assert_eq "$TEST_TMP/r1/.trash" "$(trash_dir)"
  assert_eq "$TEST_TMP/r1/work" "$(account_dir work)"
}

# ── account_dir's precondition ────────────────────────────────────────────────
# account_dir performs NO validation of its name beyond refusing an empty one:
# the name grammar and the traversal guard live in validate_name (T8), and
# Phase 5's destructive paths call validate_name before they compose a path.
# This test documents the pass-through as it stands, so that changing it is a
# deliberate decision rather than an accident. It is NOT a licence to add
# validation here — that would duplicate T8's gate and give the project two
# places to keep in sync.
test_account_dir_does_not_validate_its_name() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/r1"
  assert_eq "$TEST_TMP/r1/.." "$(account_dir "..")" "traversal is passed through"
  assert_eq "$TEST_TMP/r1/../../etc" "$(account_dir "../../etc")"
  assert_eq "$TEST_TMP/r1//abs" "$(account_dir "/abs")" "an absolute name is appended, not honoured"
  assert_eq "$TEST_TMP/r1/shared" "$(account_dir shared)" "a reserved name is the caller's business"
  assert_eq "$TEST_TMP/r1/Not A Name" "$(account_dir "Not A Name")"
}

# ── a getter must never touch the filesystem ─────────────────────────────────
test_getters_create_nothing() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/never-created"
  multi_root >/dev/null
  shared_dir >/dev/null
  trash_dir >/dev/null
  account_dir work >/dev/null
  if [[ -e "$TEST_TMP/never-created" ]]; then
    printf '  FAIL: a getter created the root\n' >&2
    return 1
  fi
  return 0
}

# ── validate_root_path ───────────────────────────────────────────────────────
# A getter can never die: inside $( ) an exit kills only the subshell and the
# caller sails on with an empty string. So validation is a separate predicate.
test_validate_root_path() {
  validate_root_path "/abs/ok"
  validate_root_path "$HOME/.claude-multi"
  validate_root_path "/"
  assert_fails validate_root_path "relative/path"
  assert_fails validate_root_path ""
  assert_fails validate_root_path
  assert_contains "$(validate_root_path "rel" 2>&1 >/dev/null || true)" "absolute"
  assert_no_stdout validate_root_path "rel"
  assert_no_stdout validate_root_path ""
  assert_stdout_empty_bytes validate_root_path "rel"
}

test_validate_root_path_is_silent_when_it_passes() {
  local err="$TEST_TMP/v.err"
  validate_root_path "/abs/ok" 2>"$err"
  assert_eq "0" "$(_bytes "$err")" "a passing validation must say nothing"
}

# ── reserved names ───────────────────────────────────────────────────────────
# Phase 5's list_accounts and add_account both hang off this table. A missing
# entry means a shared directory is listed and launched as if it were an
# account, so every name is asserted individually.
test_reserved_table_is_exhaustive() {
  assert_eq "4" "${#CLAUDE_MULTI_RESERVED_NAMES[@]}"
  assert_eq "shared" "${CLAUDE_MULTI_RESERVED_NAMES[0]}"
  assert_eq ".trash" "${CLAUDE_MULTI_RESERVED_NAMES[1]}"
  assert_eq "plugin-cache" "${CLAUDE_MULTI_RESERVED_NAMES[2]}"
  assert_eq "project-memory" "${CLAUDE_MULTI_RESERVED_NAMES[3]}"
}

test_every_reserved_name_is_rejected() {
  is_reserved_name shared
  is_reserved_name .trash
  is_reserved_name plugin-cache
  is_reserved_name project-memory
  # and every entry in the table, so adding one without testing it is not a
  # silent hole
  local n
  for n in "${CLAUDE_MULTI_RESERVED_NAMES[@]}"; do
    if ! is_reserved_name "$n"; then
      printf '  FAIL: table entry [%s] is not reported as reserved\n' "$n" >&2
      return 1
    fi
  done
  return 0
}

test_an_ordinary_name_is_not_reserved() {
  assert_fails is_reserved_name work
  assert_fails is_reserved_name personal
  assert_fails is_reserved_name personal-mother
  assert_fails is_reserved_name ""
  assert_fails is_reserved_name
}

# Containing a reserved word is not being one.
test_near_misses_are_not_reserved() {
  assert_fails is_reserved_name share
  assert_fails is_reserved_name shared-work
  assert_fails is_reserved_name work-shared
  assert_fails is_reserved_name sharedwork
  assert_fails is_reserved_name trash
  assert_fails is_reserved_name .trashed
  assert_fails is_reserved_name plugin
  assert_fails is_reserved_name plugin-cache-2
  assert_fails is_reserved_name project
  assert_fails is_reserved_name project-memories
}

# Case-sensitive by design: validate_name lowercases before asking.
test_reserved_names_are_case_sensitive() {
  assert_fails is_reserved_name Shared
  assert_fails is_reserved_name SHARED
  assert_fails is_reserved_name Plugin-Cache
}

# The table is matched literally, not as a glob or a regex.
test_reserved_matching_is_literal() {
  assert_fails is_reserved_name '*'
  assert_fails is_reserved_name 'shar?d'
  assert_fails is_reserved_name 'shared*'
}

test_is_reserved_name_is_a_silent_predicate() {
  assert_no_stdout is_reserved_name shared
  assert_no_stdout is_reserved_name work
  assert_stdout_empty_bytes is_reserved_name shared
  local err="$TEST_TMP/res.err"
  is_reserved_name shared 2>"$err" || true
  assert_eq "0" "$(_bytes "$err")" "a predicate must not narrate"
  is_reserved_name work 2>"$err" || true
  assert_eq "0" "$(_bytes "$err")" "a predicate must not narrate"
}

# ── the library must be safe to source twice ─────────────────────────────────
test_config_is_safe_to_source_twice() {
  local err="$TEST_TMP/twice.err"
  (
    set -euo pipefail
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/config.sh"
    export CLAUDE_MULTI_ROOT="$TEST_TMP/twice"
    [[ "$(multi_root)" == "$TEST_TMP/twice" ]]
    # re-sourcing must replace the table, never append to it
    ((${#CLAUDE_MULTI_RESERVED_NAMES[@]} == 4))
    is_reserved_name shared
    ! is_reserved_name shared-work
  ) 2>"$err"
  assert_eq "0" "$(_bytes "$err")" "re-sourcing must be silent"
}

# The library itself must not set -e / -u / pipefail: those leak into whatever
# sourced it.
test_config_does_not_leak_shell_options() {
  assert_eq "" "$(grep -n 'set -[euo]' "$REPO_ROOT/lib/config.sh" | grep -v '^[0-9]*:#' || true)" \
    "a sourced library must not set shell options"
}

# ── dispatcher ───────────────────────────────────────────────────────────────
_run_all_tests() {
  local -a names=()
  while IFS= read -r fn; do
    names+=("$fn")
  done < <(declare -F | awk '{print $3}' | grep '^test_' | sort)

  if ((${#names[@]} == 0)); then
    printf '  FAIL: no test_* functions were discovered — the dispatcher is broken\n' >&2
    exit 1
  fi

  # Each test runs in its own subshell so a failure is reported instead of
  # aborting the file, and so an exported CLAUDE_MULTI_ROOT / HOME cannot leak
  # into the next test.
  #
  # The subshell must NOT be the condition of an `if`: bash suppresses `set -e`
  # for everything inside an if-condition, nested subshells included, and an
  # explicit `set -e` in there does not restore it. A test function would then
  # keep running after its first failing assertion and report the status of
  # whichever assertion happened to be last. So the status is captured from a
  # standalone subshell, with the caller's `-e` lifted only across that one
  # line.
  local failed=0 fn status=0
  for fn in "${names[@]}"; do
    set +e
    ( set -euo pipefail; "$fn" )
    status=$?
    set -e
    if ((status != 0)); then
      printf '  FAIL: %s\n' "$fn" >&2
      failed=$((failed + 1))
    fi
  done

  printf '%d test function(s), %d failed\n' "${#names[@]}" "$failed" >&2
  if ((failed > 0)); then
    exit 1
  fi
}

_run_all_tests
