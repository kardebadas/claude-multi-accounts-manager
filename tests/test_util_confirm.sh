# shellcheck shell=bash
# tests/test_util_confirm.sh — tests for confirm()/_confirm_reply() in
# lib/util.sh: yes/no prompting that has to survive having no terminal.
#
# Invoked as `bash tests/test_util_confirm.sh` (by tests/run.sh, or by hand)
# with REPO_ROOT and TEST_TMP exported. Not executable, no shebang.
#
# What this file pins, and why each one matters to a later phase:
#   * the prompt goes to STDERR and stdout stays byte-empty — the finished tool
#     `exec`s claude with a byte-empty stdout so `claude-multi work -p "…" |
#     jq` is never corrupted;
#   * with a non-TTY stdin confirm takes the caller's default and does NOT read
#     a byte, because that stdin may be claude's input (Phase 6 drives the menu
#     by piping into the tool);
#   * EOF is the default too, and the default is N unless the caller says
#     otherwise — so neither a closed stdin nor a lone Ctrl-D is ever read as
#     consent by a caller that did not ask for a Y default (Phase 5's delete
#     path).
#
# The interactive branch only runs when `[[ -t 0 ]]`, and a pipe cannot fake a
# terminal, so the typed-input cases run on a real pty via script(1). Those
# test functions are defined only when script(1) exists; the pure-parser and
# non-TTY cases cover the same accept/reject table without it.
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
  local reply
  for reply in y Y yes YES Yes yEs; do
    _confirm_reply "$reply" N
    assert_eq "0" "$?" "_confirm_reply [$reply] must be yes"
  done
}

test_confirm_reply_rejects_everything_else() {
  # Only y/yes count. "yep", "1", "true" and a stray space must all be no: a
  # yes/no gate that guesses is a gate that consents by accident.
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
  confirm "prompt?" Y </dev/null 2>/dev/null
  assert_eq "0" "$?" "default Y with no terminal must be yes"
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

test_confirm_non_tty_returns_exactly_one_for_no() {
  _status confirm "prompt?" N </dev/null
  assert_eq "1" "$_STATUS" "no must be exit 1, not some other non-zero"
}

test_confirm_non_tty_does_not_consume_stdin() {
  # stdin may be claude's. A prompt that eats a line off it corrupts the
  # process we are about to exec.
  local got
  printf 'left-alone\n' >"${TEST_TMP:-.}/in"
  got="$( { confirm "prompt?" Y >/dev/null 2>/dev/null; cat; } <"${TEST_TMP:-.}/in" )"
  assert_eq "left-alone" "$got" "confirm must not consume a non-TTY stdin"
}

test_confirm_non_tty_ignores_a_waiting_answer() {
  # Stronger than "does not consume": with no terminal confirm must not READ,
  # so a "y" sitting in the pipe cannot flip a default of N. Anything else
  # would let piped data (Phase 6 pipes the menu) answer a destructive prompt.
  local got code
  printf 'y\nrest\n' >"${TEST_TMP:-.}/in2"
  set +e
  got="$( { confirm "prompt?" N >/dev/null 2>/dev/null; printf 'code=[%s]\n' "$?"; cat; } \
    <"${TEST_TMP:-.}/in2" )"
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
# stdout — arrives merged, because a pty has one stream; the stdout-vs-stderr
# split is pinned by the non-TTY tests above and by
# test_confirm_tty_prompt_does_not_reach_stdout, which drops stderr inside the
# child.
_pty_run() {
  local input="${1-}" body="${2-}" dir="${TEST_TMP:-.}" out="" code=0
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
    | script -qec "bash '$dir/pty-body.sh'" /dev/null; } 2>/dev/null )"
  code=$?
  set -e
  printf '%s' "$code" >"$dir/pty-status"
  printf '%s' "$out" | tr -d '\r'
}

# _pty_status → the exit status of the last _pty_run child. Reads the file
# written above, so it is correct even when _pty_run ran inside `$( )`.
_pty_status() {
  cat "${TEST_TMP:-.}/pty-status" 2>/dev/null || printf 'no-pty-status'
}

if command -v script >/dev/null 2>&1; then

  test_confirm_tty_is_actually_a_tty() {
    # Guards the pty harness itself: if script(1) stopped handing the child a
    # terminal, every test below would silently be re-testing the non-TTY
    # branch and pass for the wrong reason.
    local out
    out="$(_pty_run '' 'if [ -t 0 ]; then printf "TTY\n"; else printf "NOTTY\n"; fi')"
    assert_contains "$out" "TTY"
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

  test_confirm_tty_eof_takes_the_default_and_says_so() {
    # Ctrl-D at the prompt. EOF means "no answer", so it lands on the same
    # branch as empty input — the caller's default — and never on an
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
  }

  test_confirm_tty_prompt_does_not_reach_stdout() {
    # stderr dropped inside the child, so anything left in the pty stream is
    # stdout (plus the terminal's echo of the typed reply, which the child
    # never wrote).
    local out
    out="$(_pty_run $'y\n' 'confirm "an unmistakable question?" N 2>/dev/null')"
    assert_eq "0" "$(_pty_status)" \
      "the child must have run confirm and answered yes, not failed to find it"
    assert_eq "" "$(printf '%s' "$out" | grep -F 'an unmistakable question?' || true)" \
      "the prompt must go to stderr, never stdout"
    assert_eq "" "$(printf '%s' "$out" | grep -F '[y/N]' || true)" \
      "the hint must go to stderr, never stdout"
  }

  test_confirm_tty_reads_exactly_one_line() {
    # On a terminal confirm does read — but only the answer. The rest of the
    # session's input must survive for whatever runs next.
    local out
    out="$(_pty_run $'y\nleftover-line\n' \
      'confirm "q" N >/dev/null 2>&1; printf "code=[%s]\\n" "$?"; cat')"
    assert_contains "$out" "code=[0]" "the typed 'y' must have been the line confirm read"
    assert_contains "$out" "leftover-line" "confirm must leave the rest of stdin alone"
  }

fi

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
  # `read </dev/tty` would reopen the terminal and defeat both the -t 0 guard
  # and every test in this file, while hanging a cron run instead of taking the
  # default.
  assert_eq "" "$(grep -nF '/dev/tty' "$UTIL_SH" || true)" \
    "confirm must read stdin, never reopen /dev/tty"
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
  # Phases 5 and 6 both depend on these two answers, and neither is guessable
  # from the code without reading it twice. Deleting the block must turn this
  # test red.
  local doc
  doc="$(_confirm_doc_block)"

  if [[ -z "$doc" ]]; then
    printf '  FAIL: lib/util.sh has no confirm documentation block\n' >&2
    return 1
  fi

  assert_contains "$doc" "no terminal on stdin" \
    "the block must state what a non-TTY stdin means"
  assert_contains "$doc" "without reading a byte of stdin" \
    "the block must state that a non-TTY stdin is not consumed"
  assert_contains "$doc" "eof is not consent" \
    "the block must state what EOF means"
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
no terminal on stdin
without reading a byte of stdin
eof is not consent
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
