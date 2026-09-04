# shellcheck shell=bash
# tests/test_config_items.sh — the shared-item table.
#
# The table is the single source of truth for what lives in shared/ and is
# symlinked into every account. If it drifts, Phase 2 creates and verifies the
# wrong links and Phase 3 seeds the wrong things, so it is pinned exactly here:
# the names, their order, their kind, their origin, and the relative link
# target each one gets inside an account.
#
# Phase 2 consumes `shared_item_names` and `account_link_target` — never the
# raw rows — precisely so that no consumer ever splits "<name>|<kind>|<origin>"
# itself. An earlier draft had Phase 2 treating a whole row as a bare name,
# which would have produced a link literally called "CLAUDE.md|file|copy". The
# accessors below are the contract that makes that shape unreachable.
#
# Invoked as `bash tests/test_config_items.sh` (by tests/run.sh, or by hand)
# with REPO_ROOT and TEST_TMP exported. Not executable, no shebang.
#
# Every test lives in a function named test_*, and the dispatcher at the bottom
# runs each one in its own subshell so a failure is reported rather than
# aborting the file.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"
source "$REPO_ROOT/lib/config.sh"

# ── helpers ──────────────────────────────────────────────────────────────────
# byte-exact size of a file, digits only
_bytes() {
  local n
  n="$(wc -c <"$1")"
  printf '%s' "${n//[[:space:]]/}"
}

# _count_lines <text> -> the number of lines in <text>, digits only.
#
# Deliberately NOT `something_under_test | wc -l`: under `pipefail` a command
# under test that exits non-zero aborts the whole file with no diagnostic, and
# a zero-match `grep` in such a pipeline does the same. The value is captured
# and its status asserted separately; only `printf | wc` runs here, and both
# always succeed. An empty string is zero lines, not one.
_count_lines() {
  local text="${1-}" n
  if [[ -z "$text" ]]; then
    printf '0'
    return 0
  fi
  n="$(printf '%s\n' "$text" | wc -l)"
  printf '%s' "${n//[[:space:]]/}"
}

# _has_line <text> <exact-line> -> 0 if <text> has a line equal to it.
# A read loop rather than `grep -Fx`, so there is no pipeline whose zero-match
# exit status can kill the file.
_has_line() {
  local text="${1-}" want="${2-}" line
  while IFS= read -r line; do
    if [[ "$line" == "$want" ]]; then
      return 0
    fi
  done <<<"$text"
  return 1
}

# _channels_block -> the CHANNELS comment block from lib/config.sh.
# Read with a redirect, not a pipeline, for the same reason as above.
_channels_block() {
  local line inside=0
  while IFS= read -r line; do
    if ((inside == 0)); then
      if [[ "$line" == *CHANNELS* ]]; then
        inside=1
        printf '%s\n' "$line"
      fi
      continue
    fi
    if [[ "$line" != "#"* ]]; then
      return 0
    fi
    printf '%s\n' "$line"
  done <"$REPO_ROOT/lib/config.sh"
  return 0
}

# the seven names, in the order shared/ is seeded
_expected_names=(CLAUDE.md skills agents hooks commands agent-memory settings.json)

# ── the names, and their order ───────────────────────────────────────────────
test_shared_item_names_lists_the_seven_items() {
  local names
  names="$(shared_item_names)"
  assert_contains "$names" "CLAUDE.md"
  assert_contains "$names" "skills"
  assert_contains "$names" "agents"
  assert_contains "$names" "hooks"
  assert_contains "$names" "commands"
  assert_contains "$names" "agent-memory"
  assert_contains "$names" "settings.json"
  assert_eq "7" "$(_count_lines "$names")" "exactly seven items are linked"
}

# One name per line, and in seed order: Phase 3 seeds in this order and Phase 2
# links in it, so the order is part of the contract, not an accident of the
# array literal.
test_shared_item_names_are_in_seed_order() {
  local names i=0 line
  names="$(shared_item_names)"
  while IFS= read -r line; do
    assert_eq "${_expected_names[$i]}" "$line" "name $i is out of order"
    i=$((i + 1))
  done <<<"$names"
  assert_eq "7" "$i" "seven lines, one name each"
}

# Things that must never be linked into an account. plugin-cache is delivered
# by CLAUDE_CODE_PLUGIN_CACHE_DIR, project-memory by per-slug links, plugins
# cannot be shared at all, security/ is deliberately per-account, and the rest
# are real per-account state.
test_unshared_things_are_absent_from_the_table() {
  local names absent
  names="$(shared_item_names)"
  for absent in plugin-cache project-memory plugins security \
                .credentials.json .claude.json history.jsonl projects sessions \
                jobs daemon remote-settings.json policy-limits.json; do
    if _has_line "$names" "$absent"; then
      printf '  FAIL: [%s] must not be in the shared-item table\n' "$absent" >&2
      return 1
    fi
  done
  return 0
}

# The two tables are disjoint by construction: a reserved name is a directory
# in the managed root or a shared/ subdirectory that is never an account, and
# none of them is an account-side link.
test_no_shared_item_is_a_reserved_name() {
  local name
  for name in "${_expected_names[@]}"; do
    if is_reserved_name "$name"; then
      printf '  FAIL: [%s] is both a shared item and a reserved name\n' "$name" >&2
      return 1
    fi
  done
  return 0
}

# ── kinds: what shared/<name> must be ────────────────────────────────────────
test_shared_item_kind() {
  assert_eq "file" "$(shared_item_kind CLAUDE.md)"
  assert_eq "file" "$(shared_item_kind settings.json)"
  assert_eq "dir" "$(shared_item_kind skills)"
  assert_eq "dir" "$(shared_item_kind agents)"
  assert_eq "dir" "$(shared_item_kind hooks)"
  assert_eq "dir" "$(shared_item_kind commands)"
  assert_eq "dir" "$(shared_item_kind agent-memory)"
}

# ── origins: how shared/<name> comes into being (Phase 3 reads this) ─────────
test_shared_item_origin() {
  assert_eq "copy" "$(shared_item_origin CLAUDE.md)"
  assert_eq "copy" "$(shared_item_origin agents)"
  assert_eq "copy" "$(shared_item_origin hooks)"
  assert_eq "copy" "$(shared_item_origin agent-memory)"
  assert_eq "create" "$(shared_item_origin commands)" "~/.claude/commands does not exist"
  assert_eq "link" "$(shared_item_origin skills)" "resolved absolute link, not a copy"
  assert_eq "rewrite" "$(shared_item_origin settings.json)" "hook path is rewritten"
}

# ── every account-side link is relative, so the root can be moved ────────────
test_account_link_target_is_relative() {
  assert_eq "../shared/CLAUDE.md" "$(account_link_target CLAUDE.md)"
  assert_eq "../shared/skills" "$(account_link_target skills)"
  assert_eq "../shared/agents" "$(account_link_target agents)"
  assert_eq "../shared/hooks" "$(account_link_target hooks)"
  assert_eq "../shared/commands" "$(account_link_target commands)"
  assert_eq "../shared/agent-memory" "$(account_link_target agent-memory)"
  assert_eq "../shared/settings.json" "$(account_link_target settings.json)"
}

# The link target must never depend on the root: it is relative precisely so
# the whole managed root can be moved without rewriting a single symlink.
test_account_link_target_ignores_the_root() {
  local a b
  a="$(CLAUDE_MULTI_ROOT="$TEST_TMP/r1" account_link_target skills)"
  b="$(CLAUDE_MULTI_ROOT="/somewhere/else" account_link_target skills)"
  assert_eq "../shared/skills" "$a"
  assert_eq "../shared/skills" "$b" "the target must not embed the root"
}

# This is the shape the corrected Phase 2 plan depends on: expected_links is
# built from shared_item_names + account_link_target, so a link can never be
# named after a whole row.
test_phase_two_link_shape_cannot_embed_a_row() {
  local name target
  while IFS= read -r name; do
    target="$(account_link_target "$name")"
    assert_eq "../shared/$name" "$target"
    if [[ "$name" == *"|"* || "$target" == *"|"* ]]; then
      printf '  FAIL: a raw row leaked into a link name: [%s] -> [%s]\n' "$name" "$target" >&2
      return 1
    fi
    if [[ "$name" == */* ]]; then
      printf '  FAIL: item name [%s] contains a slash\n' "$name" >&2
      return 1
    fi
  done <<<"$(shared_item_names)"
  return 0
}

# ── an unknown item is an error, not an empty string ─────────────────────────
test_an_unknown_item_fails() {
  assert_fails shared_item_kind nope
  assert_fails shared_item_origin nope
  assert_fails account_link_target nope
  assert_fails shared_item_kind ""
  assert_fails shared_item_origin ""
  assert_fails account_link_target ""
  assert_fails shared_item_kind
  assert_fails shared_item_origin
  assert_fails account_link_target
}

# A near miss is not a hit: matching is literal, not a prefix or a glob.
test_a_near_miss_is_not_an_item() {
  assert_fails shared_item_kind CLAUDE
  assert_fails shared_item_kind claude.md
  assert_fails shared_item_kind skill
  assert_fails shared_item_kind skills2
  assert_fails shared_item_kind "*"
  assert_fails shared_item_kind "skill?"
  assert_fails account_link_target "CLAUDE.md|file|copy"
  assert_fails account_link_target "shared/skills"
}

# A refusal is silent on both channels: these are getters, not reporters, and
# the caller decides what to say. A stray line here would land on claude's
# stdout via the launch path.
test_an_unknown_item_is_silent() {
  local err="$TEST_TMP/unknown.err"
  assert_no_stdout shared_item_kind nope
  assert_no_stdout shared_item_origin nope
  assert_no_stdout account_link_target nope
  assert_stdout_empty_bytes shared_item_kind nope
  assert_stdout_empty_bytes shared_item_origin nope
  assert_stdout_empty_bytes account_link_target nope
  shared_item_kind nope 2>"$err" || true
  assert_eq "0" "$(_bytes "$err")" "shared_item_kind must not narrate a refusal"
  shared_item_origin nope 2>"$err" || true
  assert_eq "0" "$(_bytes "$err")" "shared_item_origin must not narrate a refusal"
  account_link_target nope 2>"$err" || true
  assert_eq "0" "$(_bytes "$err")" "account_link_target must not narrate a refusal"
}

# ── the raw table is iterable ────────────────────────────────────────────────
test_shared_items_prints_every_raw_row() {
  local rows
  rows="$(shared_items)"
  assert_eq "7" "$(_count_lines "$rows")"
  assert_contains "$rows" "CLAUDE.md|file|copy"
  assert_contains "$rows" "skills|dir|link"
  assert_contains "$rows" "agents|dir|copy"
  assert_contains "$rows" "hooks|dir|copy"
  assert_contains "$rows" "commands|dir|create"
  assert_contains "$rows" "agent-memory|dir|copy"
  assert_contains "$rows" "settings.json|file|rewrite"
}

# Every row is well formed, and every row's accessors agree with it. This is
# the test that catches a hand-edited table with a typo'd kind or a missing
# field, without any consumer ever having to split a row itself.
test_every_row_is_well_formed_and_agrees_with_the_accessors() {
  local row name kind origin fields
  while IFS= read -r row; do
    fields="${row//[!|]/}"
    assert_eq "||" "$fields" "row [$row] must have exactly three fields"
    name="${row%%|*}"
    origin="${row##*|}"
    kind="${row#*|}"
    kind="${kind%%|*}"
    if [[ -z "$name" || -z "$kind" || -z "$origin" ]]; then
      printf '  FAIL: row [%s] has an empty field\n' "$row" >&2
      return 1
    fi
    case "$kind" in
      file | dir) ;;
      *)
        printf '  FAIL: row [%s] has an unknown kind [%s]\n' "$row" "$kind" >&2
        return 1
        ;;
    esac
    case "$origin" in
      copy | create | link | rewrite) ;;
      *)
        printf '  FAIL: row [%s] has an unknown origin [%s]\n' "$row" "$origin" >&2
        return 1
        ;;
    esac
    assert_eq "$kind" "$(shared_item_kind "$name")" "shared_item_kind disagrees with row [$row]"
    assert_eq "$origin" "$(shared_item_origin "$name")" "shared_item_origin disagrees with row [$row]"
  done <<<"$(shared_items)"
  return 0
}

test_the_table_has_no_duplicate_names() {
  local names name seen=""
  names="$(shared_item_names)"
  while IFS= read -r name; do
    if _has_line "$seen" "$name"; then
      printf '  FAIL: [%s] appears twice in the table\n' "$name" >&2
      return 1
    fi
    seen="${seen:+$seen$'\n'}$name"
  done <<<"$names"
  return 0
}

# The array itself is pinned index by index, so reordering it is a deliberate
# decision that shows up as a test change.
test_the_array_is_pinned_in_seed_order() {
  assert_eq "7" "${#CLAUDE_MULTI_SHARED_ITEMS[@]}"
  assert_eq "CLAUDE.md|file|copy" "${CLAUDE_MULTI_SHARED_ITEMS[0]}"
  assert_eq "skills|dir|link" "${CLAUDE_MULTI_SHARED_ITEMS[1]}"
  assert_eq "agents|dir|copy" "${CLAUDE_MULTI_SHARED_ITEMS[2]}"
  assert_eq "hooks|dir|copy" "${CLAUDE_MULTI_SHARED_ITEMS[3]}"
  assert_eq "commands|dir|create" "${CLAUDE_MULTI_SHARED_ITEMS[4]}"
  assert_eq "agent-memory|dir|copy" "${CLAUDE_MULTI_SHARED_ITEMS[5]}"
  assert_eq "settings.json|file|rewrite" "${CLAUDE_MULTI_SHARED_ITEMS[6]}"
}

# ── the accessors are DATA PRODUCERS ─────────────────────────────────────────
# Their values are consumed via $( ), so a value moved to stderr breaks every
# caller, and a diagnostic added to the happy path corrupts claude's stdout.
# This test fails in both directions.
test_the_accessors_write_their_value_to_stdout_only() {
  local out="$TEST_TMP/p.out" err="$TEST_TMP/p.err"
  shared_items >"$out" 2>"$err"
  assert_eq "7" "$(_count_lines "$(cat "$out")")" "shared_items writes rows to stdout"
  assert_eq "0" "$(_bytes "$err")" "shared_items must write nothing to stderr"
  shared_item_names >"$out" 2>"$err"
  assert_eq "7" "$(_count_lines "$(cat "$out")")" "shared_item_names writes names to stdout"
  assert_eq "0" "$(_bytes "$err")" "shared_item_names must write nothing to stderr"
  local name
  for name in "${_expected_names[@]}"; do
    shared_item_kind "$name" >"$out" 2>"$err"
    assert_contains "file dir" "$(cat "$out")" "shared_item_kind $name on stdout"
    assert_eq "0" "$(_bytes "$err")" "shared_item_kind must write nothing to stderr"
    shared_item_origin "$name" >"$out" 2>"$err"
    assert_contains "copy create link rewrite" "$(cat "$out")" "shared_item_origin $name on stdout"
    assert_eq "0" "$(_bytes "$err")" "shared_item_origin must write nothing to stderr"
    account_link_target "$name" >"$out" 2>"$err"
    assert_eq "../shared/$name" "$(cat "$out")" "account_link_target $name on stdout"
    assert_eq "0" "$(_bytes "$err")" "account_link_target must write nothing to stderr"
  done
}

# The CHANNELS block in lib/config.sh is the defence against a later phase's
# blanket "purge stdout" sweep. Every function added to the library has to be
# declared in it, on the correct side.
test_every_accessor_is_declared_in_the_channels_block() {
  local block fn
  block="$(_channels_block)"
  assert_contains "$block" "CHANNELS"
  for fn in shared_items shared_item_names shared_item_kind shared_item_origin \
            account_link_target; do
    assert_contains "$block" "$fn" "$fn must be declared in the CHANNELS block"
  done
}

# ── reading the table must not touch the filesystem ──────────────────────────
test_reading_the_table_creates_nothing() {
  export CLAUDE_MULTI_ROOT="$TEST_TMP/items-never-created"
  shared_items >/dev/null
  shared_item_names >/dev/null
  shared_item_kind skills >/dev/null
  shared_item_origin skills >/dev/null
  account_link_target skills >/dev/null
  if [[ -e "$TEST_TMP/items-never-created" ]]; then
    printf '  FAIL: reading the table created the root\n' >&2
    return 1
  fi
  if [[ -e "$(multi_root)" ]]; then
    printf '  FAIL: reading the table created [%s]\n' "$(multi_root)" >&2
    return 1
  fi
  return 0
}

# Nothing here may resolve against the developer's real home.
test_the_table_never_reaches_the_real_home() {
  local root
  root="$(multi_root)"
  if [[ -n "${REAL_HOME_GUARD:-}" && "$root" == "$REAL_HOME_GUARD/"* ]]; then
    printf '  FAIL: multi_root resolved into the real home: [%s]\n' "$root" >&2
    return 1
  fi
  return 0
}

# ── the library must still be safe to source twice ───────────────────────────
# Re-sourcing must REPLACE the table, never append to it: a `+=` would give
# fourteen rows and Phase 2 would create every link twice.
test_the_table_survives_being_sourced_twice() {
  local err="$TEST_TMP/items-twice.err"
  (
    set -euo pipefail
    source "$REPO_ROOT/lib/config.sh"
    source "$REPO_ROOT/lib/config.sh"
    ((${#CLAUDE_MULTI_SHARED_ITEMS[@]} == 7))
    [[ "$(shared_item_kind skills)" == "dir" ]]
    [[ "$(account_link_target settings.json)" == "../shared/settings.json" ]]
    ! shared_item_kind nope
  ) 2>"$err"
  assert_eq "0" "$(_bytes "$err")" "re-sourcing must be silent"
}

# ── the dispatcher below must actually have teeth ────────────────────────────
# bash suppresses errexit for everything inside an `if` condition, nested
# subshells included, so `if ! ( set -e; "$fn" )` lets a test keep running past
# its first failing assertion and report whichever assertion happened to be
# last. This function fails on its first line and then returns 0; the exact
# construct the dispatcher uses must still report failure.
_early_fail_then_pass() {
  assert_eq "one" "two" "deliberate early failure"
  return 0
}

test_the_dispatcher_construct_catches_an_early_failure() {
  local status=0
  set +e
  ( set -euo pipefail; _early_fail_then_pass ) 2>/dev/null
  status=$?
  set -e
  if ((status == 0)); then
    printf '  FAIL: the dispatcher construct reported success for a function that failed on its first line\n' >&2
    return 1
  fi
  # and the broken construct really is broken, which is why it is banned
  local bad=0
  if ( set -euo pipefail; _early_fail_then_pass ) 2>/dev/null; then
    bad=1
  fi
  if ((bad == 0)); then
    printf '  FAIL: expected an if-condition subshell to swallow the early failure\n' >&2
    return 1
  fi
  return 0
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
  # explicit `set -e` in there does not restore it — a test would keep running
  # after its first failing assertion. So the status is captured from a
  # standalone subshell, with the caller's `-e` lifted only across that one
  # line. test_the_dispatcher_construct_catches_an_early_failure proves it.
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
