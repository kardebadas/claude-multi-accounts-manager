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
  unset CLAUDE_MULTI_NO_UNICODE
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

# Drive the real menu loop while replacing only launch_account's external exec
# boundary. The stub records every argument as NUL-delimited data, then exits
# the pipeline child just as a successful exec would replace it.
menu_drive() {
  local input="$1" record="$2" stdout_file="$3" stderr_file="$4" rc
  set +e
  (
    set -euo pipefail
    launch_account() {
      printf '%s\0' "$@" > "$record.argv"
      exit 0
    }
    printf '%s' "$input" | menu_loop
  ) >"$stdout_file" 2>"$stderr_file"
  rc=$?
  set -e
  printf '%s' "$rc"
}

recorded_launch_args() {
  local record="$1" arg
  while IFS= read -r -d '' arg; do
    printf '[%s]\n' "$arg"
  done < "$record.argv"
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

t_render_menu_handles_zero_accounts_under_nounset() {
  make_menu_fixture
  export LC_ALL=C
  local out="$MENU_BASE/empty.out" err="$MENU_BASE/empty.err"
  render_capture "$out" "$err"

  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the empty-account frame leaves stdout byte-empty"
  assert_contains "$(cat "$err")" "no accounts yet" \
    "the empty-account frame explains how to proceed"
  assert_contains "$(cat "$err")" "a) add" \
    "the add action remains available with no accounts"
  assert_contains "$(cat "$err")" "q) quit" \
    "the quit action remains available with no accounts"
  assert_eq "" "$(grep -E '^ +[0-9]+\)' "$err" || true)" \
    "an empty account list emits no numbered rows"
  assert_eq "  Select > " "$(sed -n '10p' "$err")" \
    "the empty-account menu still ends with a usable prompt"
}

t_render_menu_keeps_all_forty_accounts_in_supplied_order_without_clipping() {
  make_menu_fixture
  export LC_ALL=C
  local -a names=()
  local pad
  for pad in {01..39}; do
    mk_menu_account "acct-$pad" credentials
    names+=("acct-$pad")
  done
  mk_menu_account account-40-with-extra-width credentials
  names+=(account-40-with-extra-width)

  local out="$MENU_BASE/forty.out" err="$MENU_BASE/forty.err"
  render_capture "$out" "$err" "${names[@]}"

  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the forty-account frame leaves stdout byte-empty"
  assert_eq "40" "$(grep -cE '^ +[0-9]+\) ' "$err")" \
    "all forty accounts render as individual rows without paging"
  assert_contains "$(sed -n '4p' "$err")" " 1) acct-01" \
    "the first supplied account remains row one"
  assert_contains "$(sed -n '23p' "$err")" "20) acct-20" \
    "the twentieth supplied account remains row twenty"
  assert_contains "$(sed -n '42p' "$err")" "39) acct-39" \
    "the thirty-ninth supplied account remains row thirty-nine"
  assert_contains "$(sed -n '43p' "$err")" "40) account-40-with-extra-width" \
    "the long final account remains complete and last"
}

t_unicode_opt_out_forces_ascii_glyphs_in_a_utf8_locale() {
  make_menu_fixture
  mk_menu_account personal credentials
  mk_menu_account work
  export LC_ALL=C.UTF-8
  export CLAUDE_MULTI_NO_UNICODE=1
  local out="$MENU_BASE/ascii-opt-out.out" err="$MENU_BASE/ascii-opt-out.err"
  render_capture "$out" "$err" personal work

  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the ASCII opt-out frame leaves stdout byte-empty"
  assert_contains "$(cat "$err")" "* logged in" \
    "the opt-out uses the ASCII credentialed marker"
  assert_contains "$(cat "$err")" "- no credentials" \
    "the opt-out uses the ASCII missing-credential marker"
  assert_eq "  Select > " "$(sed -n '10p' "$err")" \
    "the opt-out uses the ASCII prompt arrow"
  assert_eq "" "$(grep -E '[●○─▸]' "$err" || true)" \
    "the opt-out emits no Unicode menu glyphs"
}

t_menu_number_delegates_the_same_stably_displayed_account() {
  make_menu_fixture
  mk_menu_account zeta credentials
  mk_menu_account alpha credentials
  mk_menu_account middle credentials
  export LC_ALL=C
  local record="$MENU_BASE/selected"
  local out="$MENU_BASE/selected.out" err="$MENU_BASE/selected.err" rc
  rc="$(menu_drive $'2\n' "$record" "$out" "$err")"

  assert_eq "0" "$rc" "a successful delegated launch ends the menu cleanly"
  assert_contains "$(sed -n '4p' "$err")" " 1) alpha" \
    "the first displayed account follows list_accounts byte order"
  assert_contains "$(sed -n '5p' "$err")" " 2) middle" \
    "the selected display row follows the same stable account list"
  assert_contains "$(sed -n '6p' "$err")" " 3) zeta" \
    "the last displayed account follows the same stable account list"
  assert_eq "[middle]" "$(recorded_launch_args "$record")" \
    "selection two delegates exactly the second displayed account"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "selection and delegation leave stdout byte-empty"
}

t_menu_number_tolerates_surrounding_whitespace() {
  make_menu_fixture
  mk_menu_account personal credentials
  export LC_ALL=C
  local record="$MENU_BASE/whitespace"
  local out="$MENU_BASE/whitespace.out" err="$MENU_BASE/whitespace.err"
  local rc
  rc="$(menu_drive $'  1  \n' "$record" "$out" "$err")"

  assert_eq "0" "$rc" "a padded valid selection launches successfully"
  assert_eq "[personal]" "$(recorded_launch_args "$record")" \
    "surrounding whitespace does not change the selected account"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "a padded selection leaves stdout byte-empty"
}

t_menu_q_quits_without_launching_or_writing_stdout() {
  make_menu_fixture
  mk_menu_account personal credentials
  export LC_ALL=C
  local record="$MENU_BASE/quit"
  local out="$MENU_BASE/quit.out" err="$MENU_BASE/quit.err" rc
  rc="$(menu_drive $'q\n' "$record" "$out" "$err")"

  assert_eq "0" "$rc" "q exits the menu cleanly"
  assert_eq "no" "$(if [[ -e "$record.argv" ]]; then printf yes; else printf no; fi)" \
    "quit never delegates to launch_account"
  assert_contains "$(cat "$err")" "Select >" \
    "quit occurs only after the stderr menu prompt is displayed"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "quit leaves stdout byte-empty"
}

t_menu_invalid_choices_warn_redraw_then_allow_a_valid_selection() {
  make_menu_fixture
  mk_menu_account personal credentials
  export LC_ALL=C
  local record="$MENU_BASE/invalid"
  local out="$MENU_BASE/invalid.out" err="$MENU_BASE/invalid.err" rc
  rc="$(menu_drive $'zz\n0\n99\n-1\n1\n' "$record" "$out" "$err")"

  assert_eq "0" "$rc" "the menu recovers and launches after invalid choices"
  assert_contains "$(cat "$err")" "invalid selection: 'zz'" \
    "non-numeric input is rejected on stderr"
  assert_contains "$(cat "$err")" "invalid selection: '0'" \
    "zero is rejected as out of range"
  assert_contains "$(cat "$err")" "invalid selection: '99'" \
    "a number above the list is rejected"
  assert_contains "$(cat "$err")" "invalid selection: '-1'" \
    "a negative choice is rejected before arithmetic"
  assert_eq "5" "$(grep -c 'Claude accounts' "$err")" \
    "the menu redraws after each rejected choice and before the accepted one"
  assert_eq "[personal]" "$(recorded_launch_args "$record")" \
    "invalid choices never change the later valid delegation"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "invalid-choice warnings never leak to stdout"
}

t_menu_eof_exits_once_without_spinning_or_leaking_stdout() {
  make_menu_fixture
  mk_menu_account personal credentials
  export LC_ALL=C
  local out="$MENU_BASE/eof.out" err="$MENU_BASE/eof.err" rc
  set +e
  timeout 5 bash -c '
    set -euo pipefail
    repo_root="$1"
    . "$repo_root/lib/util.sh"
    . "$repo_root/lib/config.sh"
    . "$repo_root/lib/accounts.sh"
    . "$repo_root/lib/menu.sh"
    launch_account() { exit 97; }
    menu_loop </dev/null
  ' _ "$REPO_ROOT" >"$out" 2>"$err"
  rc=$?
  set -e

  assert_eq "0" "$rc" "EOF exits zero rather than spinning until timeout"
  assert_eq "1" "$(grep -c 'Claude accounts' "$err")" \
    "the menu renders exactly once before EOF"
  assert_eq "9" "$(wc -l < "$err" | tr -d '[:space:]')" \
    "EOF closes the unterminated prompt line on stderr"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "EOF handling leaves stdout byte-empty"
}

t_menu_invalid_input_then_eof_warns_and_terminates() {
  make_menu_fixture
  mk_menu_account personal credentials
  export LC_ALL=C
  local record="$MENU_BASE/invalid-eof"
  local out="$MENU_BASE/invalid-eof.out" err="$MENU_BASE/invalid-eof.err" rc
  rc="$(menu_drive $'nope\nalso-nope\n' "$record" "$out" "$err")"

  assert_eq "0" "$rc" "input exhaustion after invalid choices ends the loop"
  assert_contains "$(cat "$err")" "invalid selection: 'nope'" \
    "the first exhausted-stream choice is judged"
  assert_contains "$(cat "$err")" "invalid selection: 'also-nope'" \
    "the final line before EOF is judged"
  assert_eq "no" "$(if [[ -e "$record.argv" ]]; then printf yes; else printf no; fi)" \
    "invalid input followed by EOF never launches"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "invalid input followed by EOF leaves stdout byte-empty"
}

t_menu_accepts_non_tty_piped_input_without_terminal_controls() {
  make_menu_fixture
  mk_menu_account personal credentials
  export LC_ALL=C
  local record="$MENU_BASE/non-tty"
  local out="$MENU_BASE/non-tty.out" err="$MENU_BASE/non-tty.err" rc
  rc="$(menu_drive $'1\n' "$record" "$out" "$err")"

  assert_eq "0" "$rc" "piped non-TTY input is a supported selection source"
  assert_eq "[personal]" "$(recorded_launch_args "$record")" \
    "a piped selection delegates normally"
  assert_eq "" "$(grep $'\033' "$err" || true)" \
    "non-TTY rendering emits no terminal escape sequences"
  assert_eq "" "$(grep -i 'requires a terminal' "$err" || true)" \
    "the menu does not reject a non-TTY input stream"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "non-TTY selection leaves stdout byte-empty"
}

t_menu_zero_accounts_rejects_number_without_array_underflow() {
  make_menu_fixture
  export LC_ALL=C
  local record="$MENU_BASE/zero-choice"
  local out="$MENU_BASE/zero-choice.out" err="$MENU_BASE/zero-choice.err" rc
  rc="$(menu_drive $'1\nq\n' "$record" "$out" "$err")"

  assert_eq "0" "$rc" "an out-of-range choice with no accounts does not abort"
  assert_contains "$(cat "$err")" "invalid selection: '1'" \
    "one is rejected when the stable account list is empty"
  assert_eq "no" "$(if [[ -e "$record.argv" ]]; then printf yes; else printf no; fi)" \
    "an empty list cannot accidentally delegate a launch"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "empty-list rejection and quit leave stdout byte-empty"
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
