#!/usr/bin/env bash
# tests/test_links.sh — lib/links.sh: create, verify, repair, heal, doctor.
#
# Every test runs against a throwaway HOME and a throwaway CLAUDE_MULTI_ROOT.
# Nothing here may read or write the real ~/.claude or the real ~/.claude-multi,
# and no path in this file is absolute-with-a-username: the repo is public.
set -euo pipefail

# REPO_ROOT is exported by tests/run.sh; the fallback lets the file be run
# directly during development.
REPO_ROOT="${REPO_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)}"

# shellcheck source=tests/assert.sh
source "$REPO_ROOT/tests/assert.sh"
# shellcheck source=lib/util.sh
source "$REPO_ROOT/lib/util.sh"
# shellcheck source=lib/config.sh
source "$REPO_ROOT/lib/config.sh"
# shellcheck source=lib/links.sh
source "$REPO_ROOT/lib/links.sh"

FIXTURE_TMP=""

# new_fixture — build a temp HOME + multi root with a populated shared/ and one
# account folder named `personal`. Sets FIXTURE_TMP. Exports HOME and
# CLAUDE_MULTI_ROOT, so it must NOT be called in a command substitution.
#
# shared/ is built FROM THE TABLE (shared_item_names + shared_item_kind), not
# from a hand-written list, so the fixture cannot drift from lib/config.sh.
new_fixture() {
  FIXTURE_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-multi-links.XXXXXX")"
  export HOME="$FIXTURE_TMP/home"
  export CLAUDE_MULTI_ROOT="$HOME/.claude-multi"
  mkdir -p "$HOME" "$CLAUDE_MULTI_ROOT/personal" "$CLAUDE_MULTI_ROOT/shared" \
           "$FIXTURE_TMP/codex-skills"
  local item kind
  while IFS= read -r item; do
    if [[ -z "$item" ]]; then continue; fi
    if [[ "$item" == "skills" ]]; then
      # shared/skills is itself an ABSOLUTE link to the resolved Codex dir.
      ln -s "$FIXTURE_TMP/codex-skills" "$CLAUDE_MULTI_ROOT/shared/skills"
      continue
    fi
    kind="$(shared_item_kind "$item")"
    if [[ "$kind" == "dir" ]]; then
      mkdir -p "$CLAUDE_MULTI_ROOT/shared/$item"
    else
      printf 'shared %s\n' "$item" > "$CLAUDE_MULTI_ROOT/shared/$item"
    fi
  done < <(shared_item_names)
  # Two contents the tests below assert on by name.
  printf 'shared rules\n' > "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md"
  printf '{}\n'           > "$CLAUDE_MULTI_ROOT/shared/settings.json"
}

# ── local shape helpers ──────────────────────────────────────────────────────
# assert.sh has no directory/existence assertions and this phase must not edit
# it, so these live here. Same contract: FAIL line to stderr, return 1.
assert_is_dir() { [[ -d "$1" ]] || { printf '  FAIL: expected a directory: %s\n' "$1" >&2; return 1; }; }
assert_present() { [[ -e "$1" || -L "$1" ]] || { printf '  FAIL: expected to exist: %s\n' "$1" >&2; return 1; }; }
assert_absent() { [[ ! -e "$1" && ! -L "$1" ]] || { printf '  FAIL: expected absent: %s\n' "$1" >&2; return 1; }; }

# item_count — how many entries the shared-item table has.
item_count() { shared_item_names | wc -l | tr -d '[:space:]'; }

test_expected_links_has_one_row_per_shared_item() {
  new_fixture
  assert_eq "$(item_count)" \
            "$(expected_links personal | wc -l | tr -d '[:space:]')" \
            "one expected link per shared item"
}

test_expected_links_rows_are_path_tab_relative_target() {
  new_fixture
  local rows
  rows="$(expected_links personal)"
  assert_contains "$rows" "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md"$'\t'"../shared/CLAUDE.md"
  assert_contains "$rows" "$CLAUDE_MULTI_ROOT/personal/skills"$'\t'"../shared/skills"
  assert_contains "$rows" "$CLAUDE_MULTI_ROOT/personal/settings.json"$'\t'"../shared/settings.json"
}

# THE row-format regression. lib/config.sh's shared_items emits
# "<name>|<kind>|<origin>"; a consumer that treats a row as a bare name would
# name this account's links "CLAUDE.md|file|copy" and every one of them would
# be wrong while looking plausible in a listing.
test_expected_links_never_leaks_a_shared_items_row_field_separator() {
  new_fixture
  local rows
  rows="$(expected_links personal)"
  assert_eq "0" "$(printf '%s\n' "$rows" | grep -c '|' || true)" \
    "no expected link path or target contains a | — the table rows are not names"
  assert_eq "0" "$(printf '%s\n' "$rows" | grep -c 'file|copy' || true)" \
    "expected_links parses names, not raw <name>|<kind>|<origin> rows"
}

# Every produced name must be a real table name, and every table name produced.
test_expected_links_matches_the_table_name_for_name() {
  new_fixture
  local item rows
  rows="$(expected_links personal)"
  while IFS= read -r item; do
    if [[ -z "$item" ]]; then continue; fi
    assert_contains "$rows" \
      "$CLAUDE_MULTI_ROOT/personal/$item"$'\t'"$(account_link_target "$item")" \
      "row for $item uses account_link_target's text"
  done < <(shared_item_names)
}

# C3 pin: expected_links is a DATA PRODUCER. A later "purge stdout from lib/"
# pass must not add >&2 to its printf. With stderr discarded the rows must
# still arrive on stdout, or every `< <(expected_links …)` caller sees nothing.
test_expected_links_returns_its_rows_on_stdout_not_stderr() {
  new_fixture
  assert_eq "$(item_count)" \
            "$(expected_links personal 2>/dev/null | wc -l | tr -d '[:space:]')" \
            "the rows are the return value and live on stdout"
}

test_link_create_makes_a_relative_link_that_resolves() {
  new_fixture
  link_create "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md" "../shared/CLAUDE.md"
  assert_link "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md" "../shared/CLAUDE.md"
  assert_eq "shared rules" "$(cat "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md")" \
    "the relative link resolves to the shared file"
}

test_link_create_creates_the_parent_directory() {
  new_fixture
  link_create "$CLAUDE_MULTI_ROOT/fresh/agents" "../shared/agents"
  assert_link "$CLAUDE_MULTI_ROOT/fresh/agents" "../shared/agents"
  assert_is_dir "$CLAUDE_MULTI_ROOT/fresh/agents"
}

test_link_create_replaces_an_existing_symlink() {
  new_fixture
  ln -sfn "../shared/agent-memory" "$CLAUDE_MULTI_ROOT/personal/agents"
  link_create "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents"
  assert_link "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents"
}

test_link_create_refuses_to_clobber_a_real_file() {
  new_fixture
  printf 'local override\n' > "$CLAUDE_MULTI_ROOT/personal/settings.json"
  assert_fails link_create "$CLAUDE_MULTI_ROOT/personal/settings.json" "../shared/settings.json"
  assert_eq "local override" "$(cat "$CLAUDE_MULTI_ROOT/personal/settings.json")" \
    "a real file is never destroyed by link_create"
}

test_link_create_refusal_explains_itself_on_stderr() {
  new_fixture
  printf 'local override\n' > "$CLAUDE_MULTI_ROOT/personal/settings.json"
  local err
  err="$(link_create "$CLAUDE_MULTI_ROOT/personal/settings.json" "../shared/settings.json" 2>&1 >/dev/null || true)"
  assert_contains "$err" "settings.json" "the refusal names the path it refused"
}

test_link_create_stdout_is_byte_empty() {
  new_fixture
  assert_stdout_empty_bytes link_create "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents"
}

test_link_create_abs_points_shared_skills_at_the_resolved_codex_dir() {
  new_fixture
  rm "$CLAUDE_MULTI_ROOT/shared/skills"
  link_create "$CLAUDE_MULTI_ROOT/shared/skills" "$FIXTURE_TMP/codex-skills" abs
  assert_link "$CLAUDE_MULTI_ROOT/shared/skills" "$FIXTURE_TMP/codex-skills"
  assert_is_dir "$CLAUDE_MULTI_ROOT/shared/skills"
}

test_link_create_abs_rejects_a_relative_target() {
  new_fixture
  rm "$CLAUDE_MULTI_ROOT/shared/skills"
  # This is exactly the link text `cp -a ~/.claude/skills` would carry over.
  assert_fails link_create "$CLAUDE_MULTI_ROOT/shared/skills" "../.codex-skills" abs
  assert_absent "$CLAUDE_MULTI_ROOT/shared/skills"
}

test_link_create_rejects_an_unknown_kind() {
  new_fixture
  assert_fails link_create "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents" sideways
  assert_absent "$CLAUDE_MULTI_ROOT/personal/agents"
}

test_link_create_abs_stdout_is_byte_empty() {
  new_fixture
  rm "$CLAUDE_MULTI_ROOT/shared/skills"
  assert_stdout_empty_bytes link_create "$CLAUDE_MULTI_ROOT/shared/skills" "$FIXTURE_TMP/codex-skills" abs
}

test_link_verify_reports_ok_for_a_correct_resolving_link() {
  new_fixture
  link_create "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md" "../shared/CLAUDE.md"
  assert_eq "ok" "$(link_verify "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md" "../shared/CLAUDE.md")"
}

test_link_verify_reports_ok_for_a_directory_link() {
  new_fixture
  link_create "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents"
  assert_eq "ok" "$(link_verify "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents")"
}

test_link_verify_reports_missing_when_nothing_is_there() {
  new_fixture
  assert_eq "missing" "$(link_verify "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents")"
}

test_link_verify_always_returns_zero_whatever_the_status() {
  new_fixture
  # The status is the return VALUE; the exit code carries no information, so
  # heal_account can call it under `set -e` without a guard.
  link_verify "$CLAUDE_MULTI_ROOT/personal/agents" "../shared/agents" >/dev/null
}

# C3 pin: link_verify is a DATA PRODUCER. A later "purge stdout from lib/" pass
# must not add >&2 to these printfs. With stderr discarded the status must
# still arrive on stdout — otherwise every `status="$(link_verify …)"` becomes
# the empty string, heal_account repairs nothing, and it still exits 0.
test_link_verify_returns_the_status_on_stdout_not_stderr() {
  new_fixture
  link_create "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md" "../shared/CLAUDE.md"
  assert_eq "ok" \
    "$(link_verify "$CLAUDE_MULTI_ROOT/personal/CLAUDE.md" "../shared/CLAUDE.md" 2>/dev/null)" \
    "with stderr discarded the status still arrives — it is a stdout return value"
}

# ── run ──────────────────────────────────────────────────────────────────────
# Every test defined above is invoked here, BARE. Under `set -euo pipefail` a
# failing assertion returns 1, which aborts this file with a non-zero status and
# tests/run.sh reports it as FAIL. Nothing is swallowed: no `|| true`, and no
# `if run_test …` — `set -e` is suspended inside an `if` condition and for
# everything it calls, so a mid-function assertion failure would be ignored
# there and the file could still exit 0.
declare -a RAN=()
run_test() { RAN+=("$1"); "$1"; }

run_test test_expected_links_has_one_row_per_shared_item
run_test test_expected_links_rows_are_path_tab_relative_target
run_test test_expected_links_never_leaks_a_shared_items_row_field_separator
run_test test_expected_links_matches_the_table_name_for_name
run_test test_expected_links_returns_its_rows_on_stdout_not_stderr
run_test test_link_create_makes_a_relative_link_that_resolves
run_test test_link_create_creates_the_parent_directory
run_test test_link_create_replaces_an_existing_symlink
run_test test_link_create_refuses_to_clobber_a_real_file
run_test test_link_create_refusal_explains_itself_on_stderr
run_test test_link_create_stdout_is_byte_empty
run_test test_link_create_abs_points_shared_skills_at_the_resolved_codex_dir
run_test test_link_create_abs_rejects_a_relative_target
run_test test_link_create_rejects_an_unknown_kind
run_test test_link_create_abs_stdout_is_byte_empty
run_test test_link_verify_reports_ok_for_a_correct_resolving_link
run_test test_link_verify_reports_ok_for_a_directory_link
run_test test_link_verify_reports_missing_when_nothing_is_there
run_test test_link_verify_always_returns_zero_whatever_the_status
run_test test_link_verify_returns_the_status_on_stdout_not_stderr

# ── completeness guard ───────────────────────────────────────────────────────
# A test function that is defined and never invoked reports success while
# testing nothing. Every test_* function must appear in the run block above.
_never_run=""
while IFS= read -r _fn; do
  case " ${RAN[*]-} " in
    *" $_fn "*) ;;
    *) _never_run="$_never_run $_fn" ;;
  esac
done < <(declare -F | sed -n 's/^declare -f \(test_.*\)$/\1/p' | sort)
if [[ -n "$_never_run" ]]; then
  printf '  FAIL: test functions defined but never run:%s\n' "$_never_run" >&2
  exit 1
fi
printf 'ok tests/test_links.sh (%d tests)\n' "${#RAN[@]}" >&2
