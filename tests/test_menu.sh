#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/assert.sh"
. "$REPO_ROOT/lib/util.sh"
. "$REPO_ROOT/lib/config.sh"
. "$REPO_ROOT/lib/accounts.sh"
. "$REPO_ROOT/lib/menu.sh"

REAL_HOME="$HOME"

make_menu_fixture() {
  MENU_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cm-menu.XXXXXX")"
  export HOME="$MENU_BASE/home"
  export CLAUDE_MULTI_ROOT="$HOME/.claude-multi"
  case "$CLAUDE_MULTI_ROOT" in
    ""|"/"|"$REAL_HOME"|"$REAL_HOME/.claude-multi"|"$REAL_HOME/.claude")
      printf 'FATAL: unsafe menu fixture root: %s\n' "$CLAUDE_MULTI_ROOT" >&2
      exit 99
      ;;
  esac
  mkdir -p -- "$HOME" "$CLAUDE_MULTI_ROOT"
  trap 'rm -rf -- "$MENU_BASE"' EXIT
}

mk_menu_account() {
  local name="$1" credentials="${2:-}"
  mkdir -p -- "$CLAUDE_MULTI_ROOT/$name"
  if [[ "$credentials" == "credentials" ]]; then
    printf 'fixture-present\n' > "$CLAUDE_MULTI_ROOT/$name/.credentials.json"
  fi
}

render_capture() {
  local stdout_file="$1" stderr_file="$2"
  shift 2
  render_menu "$@" >"$stdout_file" 2>"$stderr_file"
}

spaces_visible() {
  sed 's/ /·/g'
}

t_menu_helpers_are_nounset_safe_and_choose_locale_glyphs() {
  make_menu_fixture
  unset LC_ALL LC_CTYPE LANG
  menu_glyphs
  assert_eq "*|-|-|>" "$G_ON|$G_OFF|$G_RULE|$G_ARROW" \
    "unset locale variables select the complete ASCII glyph set"

  LANG=C.UTF-8
  menu_glyphs
  assert_eq "●|○|─|▸" "$G_ON|$G_OFF|$G_RULE|$G_ARROW" \
    "a UTF-8 locale selects the complete Unicode glyph set"

  LC_ALL=C
  LC_CTYPE=C.UTF-8
  menu_glyphs
  assert_eq "*|-|-|>" "$G_ON|$G_OFF|$G_RULE|$G_ARROW" \
    "LC_ALL takes precedence over the other locale variables"
}

t_repeat_char_returns_exact_data_without_a_trailing_newline() {
  make_menu_fixture
  local out="$MENU_BASE/repeat.out"
  repeat_char x 5 > "$out"
  assert_eq "xxxxx" "$(cat "$out")" "repeat_char returns the requested bytes"
  assert_eq "5" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "repeat_char adds no newline"
  assert_eq "" "$(repeat_char x 0)" "a zero count returns the empty string"
}

t_home_relative_shortens_only_home_and_its_descendants() {
  make_menu_fixture
  assert_eq "~" "$(home_relative "$HOME")" "HOME itself collapses to tilde"
  assert_eq "~/.claude-multi" "$(home_relative "$CLAUDE_MULTI_ROOT")" \
    "the managed root is shown relative to HOME"
  assert_eq "$HOME-other/project" "$(home_relative "$HOME-other/project")" \
    "a lexical HOME prefix without a slash boundary is not collapsed"
  assert_eq "/srv/claude-multi" "$(home_relative /srv/claude-multi)" \
    "a path outside HOME is preserved"
}

t_status_line_maps_real_credential_presence_to_current_glyphs() {
  make_menu_fixture
  mk_menu_account personal credentials
  mk_menu_account work
  G_ON='ON'
  G_OFF='OFF'
  assert_eq "ON logged in" "$(status_line personal)" \
    "a non-empty credential fixture maps to the on status"
  assert_eq "OFF no credentials" "$(status_line work)" \
    "an absent credential fixture maps to the off status"
}

t_render_menu_preserves_input_order_and_exact_ascii_frame() {
  make_menu_fixture
  mk_menu_account work
  mk_menu_account personal credentials
  mk_menu_account personal-mother credentials
  export LC_ALL=C
  export LANG=C
  local out="$MENU_BASE/menu.out" err="$MENU_BASE/menu.err"
  render_capture "$out" "$err" work personal personal-mother

  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the entire rendered menu leaves stdout byte-empty"
  assert_eq "  Claude accounts   (~/.claude-multi)" "$(sed -n '2p' "$err")" \
    "the title contains the home-relative root"
  assert_eq "" "$(grep -F "$MENU_BASE" "$err" || true)" \
    "the rendered frame never exposes the absolute fixture path"

  local rule
  rule="$(sed -n '3p' "$err")"
  assert_eq "37" "${#rule}" "the rule width follows the title width"
  assert_eq "" "$(printf '%s' "$rule" | tr -d ' -')" \
    "the ASCII rule contains only spaces and hyphens"
  assert_eq "  " "${rule:0:2}" "the rule retains the frame indentation"

  assert_eq "···1)·work·············-·no·credentials" \
    "$(sed -n '4p' "$err" | spaces_visible)" \
    "the first supplied account remains first and is padded exactly"
  assert_eq "···2)·personal·········*·logged·in" \
    "$(sed -n '5p' "$err" | spaces_visible)" \
    "the second supplied account remains second with its real status"
  assert_eq "···3)·personal-mother··*·logged·in" \
    "$(sed -n '6p' "$err" | spaces_visible)" \
    "the longest supplied account fixes the shared column width"
  assert_eq "   a) add    d) delete" "$(sed -n '8p' "$err")" \
    "the first action row is exact"
  assert_eq "   s) sync   x) doctor    q) quit" "$(sed -n '9p' "$err")" \
    "the second action row is exact"
  assert_eq "  Select > " "$(sed -n '11p' "$err")" \
    "the ASCII prompt is part of the stderr frame"
  assert_eq "10" "$(wc -l < "$err" | tr -d '[:space:]')" \
    "the prompt has no trailing newline and no extra frame lines follow it"
}

t_render_menu_uses_unicode_without_ansi_or_stdout() {
  make_menu_fixture
  mk_menu_account personal credentials
  mk_menu_account work
  export LC_ALL=C.UTF-8
  export LANG=C.UTF-8
  local out="$MENU_BASE/unicode.out" err="$MENU_BASE/unicode.err"
  render_capture "$out" "$err" personal work

  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the Unicode frame leaves stdout byte-empty"
  assert_contains "$(cat "$err")" "● logged in" \
    "the filled Unicode dot marks a credentialed account"
  assert_contains "$(cat "$err")" "○ no credentials" \
    "the hollow Unicode dot marks an account without credentials"
  assert_eq "  Select ▸ " "$(sed -n '10p' "$err")" \
    "the Unicode prompt is emitted to stderr"
  assert_eq "" "$(grep $'\033' "$err" || true)" \
    "the menu contains no ANSI escape sequences"
}

run_all_menu_tests() {
  local fn test_status status=0 ran=0
  while IFS= read -r fn; do
    ran=$((ran + 1))
    set +e
    ( set -e; "$fn" )
    test_status=$?
    set -e
    if (( test_status == 0 )); then
      printf 'ok   %s\n' "$fn" >&2
    else
      status=1
      printf 'FAIL %s\n' "$fn" >&2
    fi
  done < <(declare -F | awk '{print $3}' | grep '^t_' | sort)
  if (( ran == 0 )); then
    printf 'FAIL %s: no t_* tests were discovered\n' "${BASH_SOURCE[0]##*/}" >&2
    return 1
  fi
  printf '%s: %d test(s) run\n' "${BASH_SOURCE[0]##*/}" "$ran" >&2
  return "$status"
}

run_all_menu_tests
