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
