# shellcheck shell=bash
# tests/test_util_confirm.sh — tests for confirm()/_confirm_reply() in
# lib/util.sh: yes/no prompting that has to survive having no terminal.
#
# Invoked as `bash tests/test_util_confirm.sh` (by tests/run.sh, or by hand)
# with REPO_ROOT exported. TEST_TMP is used when the runner exports it, and a
# temp dir of this file's own is created and removed when it does not, so a
# hand-run never drops fixtures into the source tree.
#
# What this file pins, and why each one matters to a later phase:
#   * the prompt goes to STDERR and stdout stays byte-empty — the finished tool
#     `exec`s claude with a byte-empty stdout so `claude-multi work -p "…" |
#     jq` is never corrupted;
#   * an interactive exchange needs a terminal on BOTH channels — stdin to read
#     the answer from and stderr to show the question on — so
#     `claude-multi … 2>log` degrades to the default instead of blocking on an
#     invisible prompt;
#   * with either channel redirected confirm takes the caller's default and
#     does NOT read a byte, because that stdin may be claude's input (Phase 6
#     drives the menu by piping into the tool);
#   * EOF is the default too, and the default is N unless the caller says
#     otherwise — so neither a closed stdin nor a lone Ctrl-D is ever read as
#     consent by a caller that did not ask for a Y default (Phase 5's delete
#     path) — while EOF on a partially typed line honours what was typed, so a
#     typed refusal is never converted into the caller's Y default.
#
# The interactive branch needs a real terminal on stdin and stderr, and a pipe
# cannot fake one, so the typed-input, whitespace and EOF cases run on a real
# pty via script(1). That dependency is a HARD REQUIREMENT enforced below, not
# a condition wrapped around the test definitions: see the guard's comment.
#
# Tests are functions named test_*; the dispatch block at the bottom discovers
# and runs every one of them. Each runs in its own `set +e; ( set -e; … )`
# subshell — NOT `if ! ( … )`, which suspends errexit throughout the condition
# and would let a function that fails early and passes later report PASS. That
# trap is itself pinned below by test_the_dispatch_construct_catches_an_early_failure.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"
source "$REPO_ROOT/lib/util.sh"

UTIL_SH="$REPO_ROOT/lib/util.sh"

# ── the pty harness dependencies are hard requirements ───────────────────────
# The interactive branch (`[ -t 0 ] && [ -t 2 ]`) is unreachable through a
# pipe, so every typed-answer, whitespace and EOF case runs on a real pty via
# script(1), under timeout(1) so a pty that never sees its terminating newline
# fails the run instead of hanging it.
#
# These tests used to be defined only inside `if command -v script`, which made
# the dependency's absence SILENT: on a host without it the file shrank from 35
# test functions to 28, the printed count was the only signal, nothing asserted
# it, and a mutation that made EOF return "yes" whatever the default SURVIVED
# with exit 0 — leaving the EOF guarantee, one of the two this task exists to
# provide, entirely uncovered by a green run. assert.sh has no `skip`, so the
# honest options are "fail" or "lie". A missing dependency now fails the file,
# and test_this_file_defines_the_expected_number_of_test_functions pins the
# count as well, so a group that vanishes for any other reason is also a
# failure rather than a smaller number.
_confirm_missing=""
for _confirm_dep in script timeout; do
  command -v "$_confirm_dep" >/dev/null 2>&1 \
    || _confirm_missing="$_confirm_missing $_confirm_dep"
done
if [[ -n "$_confirm_missing" ]]; then
  printf '  FAIL: tests/test_util_confirm.sh requires%s (util-linux / coreutils) to give confirm a real terminal; its interactive and EOF branches cannot be reached without a pty, and skipping them would leave a green run covering neither\n' \
    "$_confirm_missing" >&2
  exit 1
fi

# ── fixture directory ────────────────────────────────────────────────────────
# tests/run.sh exports TEST_TMP and cds into it. A hand-run without it must not
# scatter `in`, `in2`, `pty-body.sh` and `pty-status` across whatever directory
# the developer happened to be in, so this file makes and owns one instead of
# defaulting to `.`. Exported, because the pty bodies below run in a child bash.
if [[ -n "${TEST_TMP:-}" ]]; then
  CONFIRM_TMP="$TEST_TMP"
else
  CONFIRM_TMP="$(mktemp -d "${TMPDIR:-/tmp}/claude-multi-confirm.XXXXXX")"
  # Shape-checked before rm -rf even though mktemp composed the path.
  _confirm_cleanup_tmp() {
    case "${CONFIRM_TMP:-}" in
      */claude-multi-confirm.*) rm -rf -- "$CONFIRM_TMP" ;;
    esac
    return 0
  }
  trap _confirm_cleanup_tmp EXIT
fi
export CONFIRM_TMP

# The number of test_* functions this file must define. Pinned, because the
# interactive group is the only coverage of the EOF guarantee and a count that
# can silently shrink is not coverage. Bump it deliberately when adding or
# removing a test.
EXPECTED_TEST_FUNCTIONS=42

# ── helpers ──────────────────────────────────────────────────────────────────

# _confirm_err <prompt> [default] → confirm's stderr on stdout, with confirm's
# own stdout discarded and its exit status neutralised.
#
# A data producer: its return value reaches the caller through `$( )` on
# stdout, and it is a test helper, not part of the tool. The `|| true` is
# mandatory — confirm returns 1 for "no", which inside `$( )` under this file's
# `set -e` would abort the test with no diagnostic at all.
_confirm_err() {
  { confirm "$@" 2>&1 >/dev/null || true; } </dev/null
}

# _status <command> [args…] — runs the command with errexit off and leaves its
# exit status in the global _STATUS. Nothing is printed, so no substitution and
# no pipeline is involved and a non-zero status cannot abort the caller.
_STATUS=0
_status() {
  set +e
  "$@" >/dev/null 2>&1
  _STATUS=$?
  set -e
  return 0
}

# ── the pure parser: _confirm_reply <reply> <default> ────────────────────────

test_confirm_reply_accepts_the_yes_forms() {
  # `if ! …; then _assert_fail` rather than a bare call followed by
  # `assert_eq "0" "$?"`: under this file's `set -e` (and the dispatcher's
  # `( set -e; … )`) a bare failing call aborts the subshell before the
  # assertion could run, so its message could never print — a dead assertion
  # that looks like coverage.
  local reply
  for reply in y Y yes YES Yes yEs; do
    if ! _confirm_reply "$reply" N; then
      _assert_fail "_confirm_reply [$reply] must be yes"
      return 1
    fi
  done
}

test_confirm_reply_rejects_everything_else() {
  # Only y/yes count. "yep", "1", "true" and a space attached to an answer must
  # all be no: a yes/no gate that guesses is a gate that consents by accident.
  local reply
  for reply in n N no NO nope banana yep ye 1 0 true "y " " y" "-y"; do
    assert_fails _confirm_reply "$reply" Y
  done
}

test_confirm_reply_empty_takes_the_default() {
  _confirm_reply "" Y
  _confirm_reply "" y
  assert_fails _confirm_reply "" N
  assert_fails _confirm_reply "" n
}

test_confirm_reply_whitespace_only_takes_the_default() {
  # A line of nothing but whitespace is "no answer given", not an explicit
  # "no": an operator who read [Y/n] and pressed space-Return must get the
  # default they were shown, not its opposite. Same branch as empty input.
  local reply
  for reply in " " "   " $'\t' $' \t '; do
    if ! _confirm_reply "$reply" Y; then
      _assert_fail "whitespace-only reply [$reply] must take a Y default"
      return 1
    fi
    assert_fails _confirm_reply "$reply" N
    assert_fails _confirm_reply "$reply"
  done
  # A space ATTACHED to an answer is still no — that is a typo in an answer,
  # not a blank line.
  assert_fails _confirm_reply "y " Y
  assert_fails _confirm_reply " y" Y
}

test_confirm_reply_default_is_no_when_omitted() {
  # Silence must never be consent.
  assert_fails _confirm_reply ""
  assert_fails _confirm_reply
}

test_confirm_reply_treats_an_unknown_default_as_no() {
  # Fails closed: a caller that passes junk (or a variable that came out empty)
  # gets "no", not "yes".
  assert_fails _confirm_reply "" "banana"
  assert_fails _confirm_reply "" "yes"
}

test_confirm_reply_an_explicit_reply_beats_the_default() {
  _confirm_reply "y" N
  assert_fails _confirm_reply "n" Y
}

test_confirm_reply_is_silent_on_both_streams() {
  # Pure: no I/O at all, so it is safe to call from inside a `$( )` getter.
  assert_stdout_empty_bytes _confirm_reply "y" N
  assert_stdout_empty_bytes _confirm_reply "banana" Y
  assert_no_stdout _confirm_reply "y" N
  assert_eq "" "$(_confirm_reply "banana" Y 2>&1 >/dev/null || true)" \
    "_confirm_reply must not write to stderr either"
}

test_confirm_reply_survives_set_u_with_no_arguments() {
  # `$1`/`$2` unset under `set -u` must be a "no", not an unbound-variable
  # abort of the whole caller.
  local out code
  set +e
  out="$(bash -c 'set -euo pipefail; source "$1/lib/util.sh"
    _confirm_reply && printf "YES\n" || printf "NO\n"' _ "$REPO_ROOT" 2>&1)"
  code=$?
  set -e
  assert_eq "0" "$code" "_confirm_reply with no arguments must not abort a set -u caller"
  assert_eq "NO" "$out"
}

# ── confirm with a non-TTY stdin ─────────────────────────────────────────────

test_confirm_non_tty_puts_the_prompt_on_stderr() {
  local err
  err="$(_confirm_err "launch claude in 'work' now to log in?" Y)"
  assert_contains "$err" "launch claude in 'work' now to log in?"
}

test_confirm_non_tty_says_it_is_assuming_the_default() {
  # A default taken silently is indistinguishable from an answered question.
  local err
  err="$(_confirm_err "q" Y)"
  assert_contains "$err" "no terminal"
  assert_contains "$err" "assuming"
  assert_contains "$err" "Y"
  # One owner for the message format: the notice must be exactly what log()
  # renders, not a hand-rolled copy of its prefix that can drift away from it.
  assert_eq "$(log "q [Y/n] (no terminal; assuming Y)" 2>&1)" "$err" \
    "the no-terminal notice must be rendered by log(), not hand-formatted"
}

test_confirm_stdout_is_byte_empty() {
  # The binding guarantee of the whole project. Both defaults, because the
  # "no" branch is a different return path.
  assert_stdout_empty_bytes confirm "q" Y </dev/null
  assert_stdout_empty_bytes confirm "q" N </dev/null
  assert_stdout_empty_bytes confirm "q" </dev/null
  assert_no_stdout confirm "q" Y </dev/null
  assert_no_stdout confirm "q" N </dev/null
}

test_confirm_non_tty_takes_a_yes_default() {
  # `if !` rather than a bare call plus `assert_eq "0" "$?"`, which `set -e`
  # would never let run. See test_confirm_reply_accepts_the_yes_forms.
  if ! confirm "prompt?" Y </dev/null 2>/dev/null; then
    _assert_fail "default Y with no terminal must be yes"
    return 1
  fi
}

test_confirm_non_tty_takes_a_no_default() {
  assert_fails confirm "prompt?" N </dev/null
}

test_confirm_non_tty_with_no_default_is_no() {
  # The omitted default. Phase 5's destructive callers rely on this being the
  # unsafe answer's opposite.
  assert_fails confirm "prompt?" </dev/null
}

test_confirm_non_tty_treats_an_unknown_default_as_no() {
  assert_fails confirm "prompt?" banana </dev/null
  assert_fails confirm "prompt?" "" </dev/null
}

test_confirm_warns_about_an_unrecognised_default() {
  # Fail-closed is right, but the verdict channel is binary: without a
  # diagnostic naming the value, a caller cannot tell "the operator said no"
  # from "you passed me junk". A `warn`, never a `die` — the die-vs-warn
  # contract forbids killing a caller over a prompt argument.
  local err d
  err="$(_confirm_err "q" banana)"
  assert_contains "$err" "unrecognised default [banana]" \
    "a malformed default must name the offending value"
  assert_contains "$err" "warning:" "it must go through warn, not log"
  assert_contains "$err" "[y/N]" "and the verdict must still be the safe one"

  err="$(_confirm_err "q" "yes")"
  assert_contains "$err" "unrecognised default [yes]" \
    "the default is Y or N and nothing else, so 'yes' is malformed"

  err="$(_confirm_err "q" "")"
  assert_contains "$err" "unrecognised default []" \
    "an explicitly supplied empty default is a variable that came out empty"

  # An OMITTED default is the documented way to ask for N and must stay quiet,
  # or every well-behaved caller collects a spurious warning.
  err="$(_confirm_err "q")"
  assert_eq "" "$(printf '%s' "$err" | grep -F 'unrecognised' || true)" \
    "omitting the default must not warn"
  for d in Y y N n; do
    err="$(_confirm_err "q" "$d")"
    assert_eq "" "$(printf '%s' "$err" | grep -F 'unrecognised' || true)" \
      "a well-formed default [$d] must not warn"
  done

  # And it still fails closed, on both channels.
  assert_fails confirm "q" banana </dev/null
  assert_stdout_empty_bytes confirm "q" banana </dev/null
}

test_confirm_non_tty_returns_exactly_one_for_no() {
  _status confirm "prompt?" N </dev/null
  assert_eq "1" "$_STATUS" "no must be exit 1, not some other non-zero"
}

test_confirm_non_tty_does_not_consume_stdin() {
  # stdin may be claude's. A prompt that eats a line off it corrupts the
  # process we are about to exec.
  local got
  printf 'left-alone\n' >"$CONFIRM_TMP/in"
  got="$( { confirm "prompt?" Y >/dev/null 2>/dev/null; cat; } <"$CONFIRM_TMP/in" )"
  assert_eq "left-alone" "$got" "confirm must not consume a non-TTY stdin"
}

test_confirm_non_tty_ignores_a_waiting_answer() {
  # Stronger than "does not consume": with no terminal confirm must not READ,
  # so a "y" sitting in the pipe cannot flip a default of N. Anything else
  # would let piped data (Phase 6 pipes the menu) answer a destructive prompt.
  local got code
  printf 'y\nrest\n' >"$CONFIRM_TMP/in2"
  set +e
  got="$( { confirm "prompt?" N >/dev/null 2>/dev/null; printf 'code=[%s]\n' "$?"; cat; } \
    <"$CONFIRM_TMP/in2" )"
  code=$?
  set -e
  assert_eq "0" "$code" "the capture itself must not fail"
  # Bracketed: a bare "code=1" is a substring of "code=127", so an unfound
  # confirm would have satisfied this assertion.
  assert_contains "$got" "code=[1]" "a waiting 'y' must not override a default of N"
  assert_contains "$got" "y" "the waiting answer must still be on stdin"
  assert_contains "$got" "rest"
}

# ── the rendered prompt ──────────────────────────────────────────────────────

test_confirm_hint_shows_the_default() {
  assert_contains "$(_confirm_err "q" Y)" "[Y/n]"
  assert_contains "$(_confirm_err "q" N)" "[y/N]"
  assert_contains "$(_confirm_err "q")" "[y/N]"
  assert_contains "$(_confirm_err "q" y)" "[Y/n]"
  assert_contains "$(_confirm_err "q" banana)" "[y/N]" \
    "an unrecognised default must render as the safe one"
}

test_confirm_does_not_interpret_the_prompt() {
  # printf '%s' — a prompt containing % or a backslash escape is data.
  assert_contains "$(_confirm_err '100% \n sure?' Y)" '100% \n sure?'
}

test_confirm_with_no_prompt_is_not_an_error() {
  # `set -u` must not abort on a missing "$1".
  local err
  err="$(_confirm_err)"
  assert_contains "$err" "[y/N]"
}

# ── the interactive branch, on a real terminal ───────────────────────────────
# script(1) is the only hermetic way to give a child a pty. -e propagates the
# child's exit status; the body goes through a file so no quoting has to
# survive two shells; /dev/null takes the typescript.

# _pty_run <stdin-bytes> <bash-body> → the child's merged pty output (CR
# stripped) on stdout; the child's exit status is recorded for _pty_status.
#
# A data producer (stdout). The status goes to a FILE, not a variable: callers
# capture the output with `$( )`, which runs this function in a subshell, and a
# global assigned there is lost — the parent would then assert against a stale
# value from an earlier call and pass for the wrong reason. (Observed: the
# first RED run of this file reported 0 for a child that had exited 127.)
#
# Everything the child writes — prompt, terminal echo of the typed reply, any
# stdout — arrives merged, because a pty has one stream. The stdout-vs-stderr
# split is pinned by the non-TTY tests above and by
# test_confirm_tty_prompt_does_not_reach_stdout, which sends the child's stdout
# to a file and byte-counts it; stderr must stay on the pty, because confirm
# now requires a terminal there too.
#
# timeout(1) wraps script(1) because a pty reaches EOF only when the child
# exits: a body left blocked on an unterminated line would otherwise hang the
# whole suite with no output at all. Status 124 then says "the child never
# finished", which fails an assertion instead.
_pty_run() {
  local input="${1-}" body="${2-}" dir="$CONFIRM_TMP" out="" code=0
  {
    printf 'set -uo pipefail\n'
    printf 'source "$REPO_ROOT/lib/util.sh"\n'
    printf '%s\n' "$body"
  } >"$dir/pty-body.sh"

  set +e
  # `|| true` inside the braces, not after the pipeline: this file runs under
  # pipefail, so a child that exits non-zero (confirm's "no") would otherwise
  # fail the assignment and `set -e` would abort the file with no diagnostic.
  out="$( { printf '%s' "$input" \
    | timeout 30 script -qec "bash '$dir/pty-body.sh'" /dev/null; } 2>/dev/null )"
  code=$?
  set -e
  printf '%s' "$code" >"$dir/pty-status"
  printf '%s' "$out" | tr -d '\r'
}

# _pty_status → the exit status of the last _pty_run child. Reads the file
# written above, so it is correct even when _pty_run ran inside `$( )`.
_pty_status() {
  cat "$CONFIRM_TMP/pty-status" 2>/dev/null || printf 'no-pty-status'
}

test_confirm_tty_is_actually_a_tty() {
  # Guards the pty harness itself: if script(1) stopped handing the child a
  # terminal, every test below would silently be re-testing the non-TTY branch
  # and pass for the wrong reason. BOTH channels are checked, because confirm
  # requires both — a harness that gave the child a terminal on stdin alone
  # would put every interactive test back on the non-TTY branch.
  local out
  out="$(_pty_run '' '
    if [ -t 0 ]; then printf "TTY0\n"; else printf "NOTTY0\n"; fi
    if [ -t 2 ]; then printf "TTY2\n"; else printf "NOTTY2\n"; fi')"
  assert_contains "$out" "TTY0"
  assert_contains "$out" "TTY2"
  assert_eq "" "$(printf '%s' "$out" | grep -F 'NOTTY' || true)" \
    "the pty harness must not be exercising the non-TTY branch"
}

test_confirm_tty_accepts_a_typed_yes() {
  local reply out
  for reply in y Y yes YES; do
    out="$(_pty_run "$reply"$'\n' 'confirm "q" N')"
    assert_eq "0" "$(_pty_status)" "typed [$reply] on a terminal must be yes"
    assert_contains "$out" "[y/N]"
  done
}

test_confirm_tty_rejects_a_typed_no() {
  local reply
  for reply in n N no banana yep; do
    _pty_run "$reply"$'\n' 'confirm "q" Y' >/dev/null
    assert_eq "1" "$(_pty_status)" "typed [$reply] on a terminal must be no"
  done
}

test_confirm_tty_empty_input_takes_the_default() {
  # A bare Return.
  _pty_run $'\n' 'confirm "q" Y' >/dev/null
  assert_eq "0" "$(_pty_status)" "Return with default Y must be yes"
  _pty_run $'\n' 'confirm "q" N' >/dev/null
  assert_eq "1" "$(_pty_status)" "Return with default N must be no"
  _pty_run $'\n' 'confirm "q"' >/dev/null
  assert_eq "1" "$(_pty_status)" "Return with no default must be no"
}

test_confirm_tty_whitespace_only_takes_the_default() {
  # Spaces and a Return. The operator just read the hint; a blank-looking line
  # must take the default it advertised, not the opposite of it.
  local out
  out="$(_pty_run $'   \n' 'confirm "q" Y')"
  assert_eq "0" "$(_pty_status)" "a line of spaces must take the [Y/n] default"
  assert_contains "$out" "[Y/n]"
  _pty_run $'  \t \n' 'confirm "q" N' >/dev/null
  assert_eq "1" "$(_pty_status)" "a line of spaces and tabs must take the [y/N] default"
  _pty_run $'   \n' 'confirm "q"' >/dev/null
  assert_eq "1" "$(_pty_status)" "and with no default it is still no"
}

test_confirm_tty_eof_takes_the_default_and_says_so() {
  # Ctrl-D at the prompt with nothing typed. EOF means "no answer", so it lands
  # on the same branch as empty input — the caller's default — and never on an
  # unconditional yes.
  local out
  out="$(_pty_run '' 'confirm "q" N')"
  assert_eq "1" "$(_pty_status)" "EOF with default N must be no"
  assert_contains "$out" "EOF"
  assert_contains "$out" "assuming"

  _pty_run '' 'confirm "q"' >/dev/null
  assert_eq "1" "$(_pty_status)" "EOF with no default must be no"

  _pty_run '' 'confirm "q" Y' >/dev/null
  assert_eq "0" "$(_pty_status)" "EOF with default Y must be the default, i.e. yes"

  # The real keystroke too: a bare Ctrl-D (0x04) on an empty line, which is
  # what an operator actually presses.
  out="$(_pty_run $'\004' 'confirm "q" Y')"
  assert_eq "0" "$(_pty_status)" "a bare Ctrl-D must take the default"
  assert_contains "$out" "EOF"
  _pty_run $'\004' 'confirm "q" N' >/dev/null
  assert_eq "1" "$(_pty_status)" "a bare Ctrl-D with default N must be no"
}

test_confirm_tty_eof_on_a_partial_line_honours_what_was_typed() {
  # "n" then Ctrl-D twice, which is how an unterminated line ends in canonical
  # mode: the first hands the partial line to read(2), the second is the EOF.
  # `read` therefore returns 1 with the typed answer still in $reply. Throwing
  # it away would let a caller's Y default overrule a human who explicitly
  # typed "n" — a prompt must never manufacture consent.
  local out
  out="$(_pty_run $'n\004\004' 'confirm "q" Y')"
  assert_eq "1" "$(_pty_status)" \
    "typed [n] then Ctrl-D at a [Y/n] prompt must be NO, not the Y default"
  assert_contains "$out" "[Y/n]"
  # A typed answer is not "no answer", so it must not be reported as one.
  assert_eq "" "$(printf '%s' "$out" | grep -F 'no answer' || true)" \
    "a typed answer must not be announced as EOF/no answer"

  _pty_run $'y\004\004' 'confirm "q" N' >/dev/null
  assert_eq "0" "$(_pty_status)" "typed [y] then Ctrl-D at a [y/N] prompt must be yes"

  _pty_run $'yes\004\004' 'confirm "q" N' >/dev/null
  assert_eq "0" "$(_pty_status)" "typed [yes] then Ctrl-D must be yes"

  _pty_run $'banana\004\004' 'confirm "q" Y' >/dev/null
  assert_eq "1" "$(_pty_status)" "an unrecognised partial answer is still no"

  # Whitespace on a partial line is still "no answer": the same rule as a
  # whitespace-only complete line, so the two cannot disagree.
  out="$(_pty_run $' \004\004' 'confirm "q" Y')"
  assert_eq "0" "$(_pty_status)" "a whitespace-only partial line takes the default"
  assert_contains "$out" "EOF"
}

test_confirm_needs_a_terminal_on_stderr_too() {
  # stdin IS a terminal; stderr is a file. The prompt would land where the
  # operator cannot see it while confirm blocked on input they have no reason
  # to type — `claude-multi … 2>log` looks like a hang. So the gate is both
  # channels: this must degrade to the default and read NOTHING, leaving the
  # typed answer and the rest of stdin for whatever runs next.
  local out err
  out="$(_pty_run $'y\nleftover-line\n' \
    'confirm "q" N 2>"$CONFIRM_TMP/gate-err"; printf "code=[%s]\\n" "$?"; cat')"
  assert_contains "$out" "code=[1]" \
    "with stderr redirected confirm must take the default, not read the typed 'y'"
  assert_contains "$out" "leftover-line" "the rest of stdin must survive untouched"

  err="$(cat "$CONFIRM_TMP/gate-err")"
  assert_contains "$err" "no terminal" \
    "the redirected prompt must say it took the default rather than wait for one"
  assert_contains "$err" "assuming N"

  # And the other way round for a Y default, so the notice is not the only
  # thing that changed.
  _pty_run $'n\n' 'confirm "q" Y 2>"$CONFIRM_TMP/gate-err2"' >/dev/null
  assert_eq "0" "$(_pty_status)" \
    "with stderr redirected a Y default must be taken, not the typed 'n'"
}

test_confirm_tty_prompt_does_not_reach_stdout() {
  # The child's stdout goes to a file and is byte-counted; stderr stays on the
  # pty, where confirm needs a terminal, so the prompt must show up in the
  # merged pty stream and nowhere else.
  local out bytes
  out="$(_pty_run $'y\n' \
    'confirm "an unmistakable question?" N >"$CONFIRM_TMP/tty-stdout"')"
  assert_eq "0" "$(_pty_status)" \
    "the child must have run confirm and answered yes, not failed to find it"
  bytes="$(wc -c <"$CONFIRM_TMP/tty-stdout" | tr -d '[:space:]')"
  assert_eq "0" "$bytes" "confirm must write zero bytes to stdout on a terminal"
  assert_contains "$out" "an unmistakable question?" \
    "the prompt must be on stderr, which is the pty here"
  assert_contains "$out" "[y/N]"
}

test_confirm_tty_reads_exactly_one_line() {
  # On a terminal confirm does read — but only the answer. The rest of the
  # session's input must survive for whatever runs next. Only stdout is
  # redirected: stderr has to stay on the pty for the interactive branch.
  local out
  out="$(_pty_run $'y\nleftover-line\n' \
    'confirm "q" N >/dev/null; printf "code=[%s]\\n" "$?"; cat')"
  assert_contains "$out" "code=[0]" "the typed 'y' must have been the line confirm read"
  assert_contains "$out" "leftover-line" "confirm must leave the rest of stdin alone"
}

# ── lib/util.sh must still be the library it was ─────────────────────────────

test_util_sh_is_still_safe_to_source_twice() {
  # confirm and _confirm_reply must add no `readonly`, no top-level state and
  # no output at source time.
  local out code
  set +e
  out="$(bash -c '
    set -euo pipefail
    source "$1/lib/util.sh"
    source "$1/lib/util.sh"
    source "$1/lib/util.sh"
    _confirm_reply "y" N || exit 9
    confirm "q" Y </dev/null 2>/dev/null || exit 8
    confirm "q" N </dev/null 2>/dev/null && exit 7
    exit 0
  ' _ "$REPO_ROOT" 2>&1)"
  code=$?
  set -e
  assert_eq "0" "$code" "lib/util.sh must stay safe to source repeatedly"
  assert_eq "" "$out" "re-sourcing must be silent"
}

test_util_sh_still_sets_no_errexit() {
  # A sourced library that sets -e leaks errexit into every caller.
  assert_eq "" "$(grep -nE '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$UTIL_SH" || true)" \
    "a sourced library must not set -e"
}

test_util_sh_still_parses() {
  bash -n "$UTIL_SH"
}

test_confirm_reads_stdin_and_not_dev_tty() {
  # `read </dev/tty` would reopen the terminal and defeat both the terminal
  # guard and every test in this file, while hanging a cron run instead of
  # taking the default.
  assert_eq "" "$(grep -nF '/dev/tty' "$UTIL_SH" || true)" \
    "confirm must read stdin, never reopen /dev/tty"
}

test_confirm_warns_and_never_dies() {
  # The die-vs-warn contract: confirm must let its caller continue past every
  # path, the malformed default included, so nothing below the confirm banner
  # may call die or exit.
  local block
  # Comment lines are stripped first: the prose below the banner discusses the
  # die-vs-warn contract by name, and a grep that read prose as code would
  # report the documentation as a violation.
  block="$( { sed -n '/confirm: yes\/no prompting/,$p' "$UTIL_SH" \
    | grep -v '^[[:space:]]*#'; } || true)"
  if [[ -z "$block" ]]; then
    printf '  FAIL: could not find the confirm section of lib/util.sh\n' >&2
    return 1
  fi
  assert_eq "" "$(printf '%s\n' "$block" \
    | grep -nE '(^|[^[:alnum:]_])(die|exit)([^[:alnum:]_]|$)' || true)" \
    "confirm must warn and return, never die or exit"
  assert_contains "$block" "warn " "the malformed-default path must warn"
}

# Extracts confirm's documentation block from lib/util.sh by its own delimiter
# line, stopping at the first line that is not a comment — the same technique
# tests/test_util_log.sh uses for the die-vs-warn banner, and for the same
# reason: a fixed line window is satisfiable by whatever prose happens to drift
# into it, while extracting by delimiter makes a deleted block an empty string.
_confirm_doc_block() {
  awk '
    /confirm: yes\/no prompting/ { inb = 1 }
    inb && $0 !~ /^#/            { exit }
    inb                          { sub(/^#[ ]?/, ""); print }
  ' "$UTIL_SH" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' '
}

test_confirm_documents_its_non_tty_and_eof_behaviour() {
  # Phases 5 and 6 both depend on these answers, and not one of them is
  # guessable from the code without reading it twice. Deleting the block must
  # turn this test red.
  local doc
  doc="$(_confirm_doc_block)"

  if [[ -z "$doc" ]]; then
    printf '  FAIL: lib/util.sh has no confirm documentation block\n' >&2
    return 1
  fi

  assert_contains "$doc" "no terminal for the exchange" \
    "the block must state what a missing terminal means"
  assert_contains "$doc" "both channels must be usable" \
    "the block must state that stdin AND stderr are required"
  assert_contains "$doc" "without reading a byte of stdin" \
    "the block must state that a non-interactive stdin is not consumed"
  assert_contains "$doc" "eof is not consent" \
    "the block must state what EOF means"
  assert_contains "$doc" "eof on a partially typed line honours what was typed" \
    "the block must state that a typed answer survives EOF"
  assert_contains "$doc" "nothing but whitespace is no answer" \
    "the block must state what a blank-looking line means"
  assert_contains "$doc" "not the deletion gate" \
    "the block must state the boundary against phase 5's typed-name gate"
  assert_contains "$doc" "typed-name" \
    "the block must name the typed-name confirmation as the destructive gate"
}

test_the_confirm_doc_phrases_are_unique_to_the_block() {
  # The guard above is only meaningful if its phrases live in that block alone.
  local phrase hits whole doc
  whole="$(sed -e 's/^#[ ]\{0,1\}//' "$UTIL_SH" \
    | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ')"
  doc="$(_confirm_doc_block)"
  while IFS= read -r phrase; do
    [[ -n "$phrase" ]] || continue
    # `|| true` inside the braces: a zero-match grep under pipefail would fail
    # the assignment and `set -e` would abort this test with no diagnostic.
    hits="$( { printf '%s' "$whole" | grep -o -F -- "$phrase" || true; } \
      | wc -l | tr -d '[:space:]')"
    assert_eq "1" "$hits" "[$phrase] must appear exactly once in lib/util.sh"
    case "$doc" in
      *"$phrase"*) ;;
      *) printf '  FAIL: [%s] is not inside the confirm doc block\n' "$phrase" >&2
         return 1 ;;
    esac
  done <<'PHRASES'
no terminal for the exchange
both channels must be usable
without reading a byte of stdin
eof is not consent
eof on a partially typed line honours what was typed
nothing but whitespace is no answer
not the deletion gate
PHRASES
}

# ── the dispatcher must have teeth ───────────────────────────────────────────

# Fails on its FIRST assertion and returns 0 from its LAST statement. Run
# through `if ! ( … )` it reports success; run through the construct the
# dispatch block below actually uses, it fails.
_early_fail_then_pass() {
  assert_eq "a" "b" "deliberate failure — this message is expected"
  return 0
}

test_the_dispatch_construct_catches_an_early_failure() {
  local strict=0 naive=1
  set +e
  ( set -e; _early_fail_then_pass ) >/dev/null 2>&1
  strict=$?
  set -e
  assert_eq "1" "$strict" \
    "the dispatch construct must fail a function that fails early and passes later"

  # And the form this file must never use. Bash suspends errexit for the whole
  # of an `if` condition, subshells included, so the failed assertion above is
  # masked by the later `return 0` and the function reports PASS. If a future
  # bash changed that, this assertion is where it would surface.
  if ( set -euo pipefail; _early_fail_then_pass ) >/dev/null 2>&1; then
    naive=0
  fi
  assert_eq "0" "$naive" \
    "documents the trap: errexit is suspended inside an if condition, so \`if ! ( … )\` masks early failures"
}

test_this_file_defines_the_expected_number_of_test_functions() {
  # A test group that disappears must be a FAILURE, not a smaller number in the
  # summary line. This is the second half of the script(1) guard at the top of
  # the file: it catches a group lost to a conditional definition, an editing
  # accident or a bad merge, whatever the reason.
  local count
  count="$(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p' \
    | wc -l | tr -d '[:space:]')"
  assert_eq "$EXPECTED_TEST_FUNCTIONS" "$count" \
    "tests/test_util_confirm.sh must define exactly $EXPECTED_TEST_FUNCTIONS test functions; if you added or removed one on purpose, bump EXPECTED_TEST_FUNCTIONS"
}

# ── dispatch: run every test_* function defined above ────────────────────────
# This must be the file's last statement. A test file that defines tests and
# never runs them reports success while testing nothing.

_tests=()
while IFS= read -r _fn; do
  _tests+=("$_fn")
done < <(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p' | sort)

if ((${#_tests[@]} == 0)); then
  printf '  FAIL: no test_* functions discovered in tests/test_util_confirm.sh\n' >&2
  exit 1
fi

_failed=0
for _fn in "${_tests[@]}"; do
  # NOT `if ! ( … )`: errexit is suspended inside an if condition, so a
  # function that fails an early assertion and returns 0 later would pass.
  set +e
  ( set -e; "$_fn" )
  _code=$?
  set -e
  if ((_code != 0)); then
    printf '  FAIL: %s (exit %d)\n' "$_fn" "$_code" >&2
    _failed=$((_failed + 1))
  fi
done

printf '  %s: %d test functions, %d failed\n' \
  "tests/test_util_confirm.sh" "${#_tests[@]}" "$_failed" >&2
((_failed == 0))
