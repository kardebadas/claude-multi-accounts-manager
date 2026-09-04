# shellcheck shell=bash
# tests/test_util_log.sh — tests for lib/util.sh, the project's output
# primitives.
#
# Invoked as `bash tests/test_util_log.sh` (by tests/run.sh, or by hand) with
# REPO_ROOT exported. Not executable, no shebang: nothing runs it as
# `./tests/test_util_log.sh`.
#
# What this file is really pinning: **stdout belongs to claude.** The finished
# tool `exec`s claude with a byte-empty stdout so `claude-multi work -p "…" |
# jq` is never corrupted by our own narration. Every diagnostic primitive is
# therefore checked with assert_stdout_empty_bytes (byte-exact) and not only
# with assert_no_stdout (which a command substitution makes blind to a leak
# that is *only* a newline).
#
# Tests are functions named test_*; the dispatch block at the bottom discovers
# and runs every one of them. Each runs in its own `( set -e; … )` subshell so
# that a mid-function assertion failure aborts that function — `if ! test_x`
# alone would suspend errexit and let a failed assertion be masked by a later
# passing one.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"
source "$REPO_ROOT/lib/util.sh"

UTIL_SH="$REPO_ROOT/lib/util.sh"

# ── the message prefix ───────────────────────────────────────────────────────

test_prog_default_is_claude_multi() {
  assert_eq "claude-multi" "$CLAUDE_MULTI_PROG"
}

test_prog_prefix_is_overridable_and_used() {
  CLAUDE_MULTI_PROG="other"
  assert_eq "other: hi" "$(log "hi" 2>&1 >/dev/null)"
  assert_eq "other: warning: hi" "$(warn "hi" 2>&1 >/dev/null)"
}

# ── log ──────────────────────────────────────────────────────────────────────

test_log_writes_the_message_to_stderr() {
  assert_eq "claude-multi: hello" "$(log "hello" 2>&1 >/dev/null)"
}

test_log_joins_its_arguments_with_spaces() {
  assert_eq "claude-multi: two words" "$(log two words 2>&1 >/dev/null)"
}

test_log_stdout_is_byte_empty() {
  assert_stdout_empty_bytes log "hello"
  assert_no_stdout log "hello"
}

test_log_returns_zero() {
  # log/warn must be safe to place anywhere in a `set -e` script.
  log "x" 2>/dev/null
  assert_eq "0" "$?"
}

test_log_does_not_interpret_the_message() {
  # printf '%s' — a message containing % or a backslash escape is data.
  assert_eq 'claude-multi: 100% \n done' "$(log '100% \n done' 2>&1 >/dev/null)"
}

test_log_with_no_arguments_is_not_an_error() {
  # `set -u` must not abort on an empty "$*".
  assert_eq "claude-multi: " "$(log 2>&1 >/dev/null)"
}

# ── warn ─────────────────────────────────────────────────────────────────────

test_warn_writes_a_warning_to_stderr() {
  assert_eq "claude-multi: warning: careful" "$(warn "careful" 2>&1 >/dev/null)"
}

test_warn_stdout_is_byte_empty() {
  assert_stdout_empty_bytes warn "careful"
  assert_no_stdout warn "careful"
}

test_warn_returns_zero() {
  warn "x" 2>/dev/null
  assert_eq "0" "$?"
}

# ── die ──────────────────────────────────────────────────────────────────────
# die terminates the process, so it is exercised in a child bash. The child
# prints UNREACHABLE after the die: nothing must come out of it.

_die_child() {
  bash -c 'set -euo pipefail; source "$1/lib/util.sh"; die "boom"; printf "UNREACHABLE\n"' \
    _ "$REPO_ROOT"
}

# assert_stdout_empty_bytes counts bytes through a pipeline. This file runs
# under `pipefail`, so a non-zero left-hand element makes the helper's internal
# assignment fail and `set -e` aborts the test with no diagnostic at all — and
# die exits 1 by design. Normalising the status here keeps the assertion
# measuring the one thing it is for: stdout. (The `|| true` inside the helper
# cannot do this itself, because `exit` bypasses `||`; only a child process
# boundary turns die's exit back into a status a caller can catch.)
_die_child_status0() {
  _die_child || true
  return 0
}

test_die_writes_the_error_to_stderr() {
  assert_contains "$(_die_child 2>&1 >/dev/null || true)" "claude-multi: error: boom"
}

test_die_stdout_is_byte_empty() {
  # Byte-exact, not merely "no content": the launch path must leave stdout
  # empty to the byte, and a lone newline is invisible to a command
  # substitution. die cannot be measured in-process — it terminates the shell
  # doing the measuring — so it is measured in a child.
  assert_stdout_empty_bytes _die_child_status0
  assert_no_stdout _die_child
}

test_die_exits_non_zero() {
  assert_fails _die_child
}

test_die_exits_exactly_one() {
  set +e
  _die_child >/dev/null 2>&1
  local code=$?
  set -e
  assert_eq "1" "$code" "die must exit exactly 1"
}

test_nothing_after_die_runs() {
  assert_eq "" "$(_die_child 2>&1 | grep UNREACHABLE || true)"
}

test_die_terminates_even_without_errexit() {
  # Every other die test runs under `set -e`, where a die written as
  # `return 1` is indistinguishable from one that exits: errexit aborts the
  # caller either way. Mutation-tested, and `return 1` survived all of them.
  # With errexit off the two diverge — a `return` lets the caller carry on
  # past an unrecoverable error — so this is where die's contract is actually
  # pinned.
  local out code
  set +e
  out="$(bash -c 'set +e; source "$1/lib/util.sh"; die "boom"; printf "AFTER\n"' \
    _ "$REPO_ROOT" 2>/dev/null)"
  code=$?
  set -e
  assert_eq "" "$out" "die must terminate, not return, when errexit is off"
  assert_eq "1" "$code" "die must still exit 1 with errexit off"
}

# ── require_bash4 ────────────────────────────────────────────────────────────

test_require_bash4_accepts_this_shell() {
  require_bash4
  assert_eq "0" "$?"
}

test_require_bash4_accepts_four_and_newer() {
  require_bash4 4
  require_bash4 5
  require_bash4 10
}

test_require_bash4_rejects_older_majors() {
  assert_fails require_bash4 3
  assert_fails require_bash4 0
}

test_require_bash4_diagnostic_names_bash_4() {
  local err
  err="$(require_bash4 3 2>&1 >/dev/null || true)"
  assert_contains "$err" "bash 4"
  assert_contains "$err" "claude-multi: error:"
  assert_contains "$err" "3" "the diagnostic must report what was found"
}

test_require_bash4_stdout_is_byte_empty() {
  assert_stdout_empty_bytes require_bash4 3
  assert_stdout_empty_bytes require_bash4 5
  assert_no_stdout require_bash4 3
}

test_require_bash4_refuses_a_non_numeric_major() {
  # `(( major < 4 ))` on a non-numeric value aborts a `set -u` caller with a
  # raw "unbound variable" instead of a diagnostic. It must be validated first.
  local out code
  set +e
  out="$(bash -c 'set -euo pipefail; source "$1/lib/util.sh"; require_bash4 abc' \
    _ "$REPO_ROOT" 2>&1)"
  code=$?
  set -e
  assert_eq "1" "$code" "a non-numeric major must return 1, not abort"
  assert_contains "$out" "claude-multi: error:"
  assert_eq "" "$(printf '%s\n' "$out" | grep -F 'unbound variable' || true)" \
    "a non-numeric major must not surface as a raw set -u abort"
}

# ── require_bash4 must itself run on the bash it rejects ─────────────────────
# A version check written with bash-4-only syntax cannot report a bash-3
# failure: sourcing lib/util.sh would be a syntax error before require_bash4
# ever ran. Only bash 5 is installed here, so the guarantee is pinned
# statically — the file must contain no construct that bash 3 cannot parse.

test_util_sh_uses_no_bash4_only_syntax() {
  local pattern desc found
  # pattern<TAB>description
  while IFS=$'\t' read -r pattern desc; do
    [[ -n "$pattern" ]] || continue
    found="$(grep -nE -- "$pattern" "$UTIL_SH" || true)"
    assert_eq "" "$found" "lib/util.sh must not use $desc (bash 4+ only)"
  done <<'PATTERNS'
(declare|local|typeset)[[:space:]]+-[A-Za-z]*A	associative arrays
\$\{[A-Za-z_][A-Za-z_0-9]*(\[[^]]*\])?(\^|,,|,)	case modification ${v^^} / ${v,,}
(^|[^[:alnum:]_])(mapfile|readarray|coproc)([^[:alnum:]_]|$)	mapfile/readarray/coproc
&>>	the &>> append redirection
\|&	the |& pipe-stderr shorthand
;;&	the ;;& case fallthrough
\[\[[[:space:]]+-v[[:space:]]	[[ -v var ]]
\$\{[A-Za-z_][A-Za-z_0-9]*\[-[0-9]	negative array indices
PATTERNS
}

test_util_sh_parses() {
  bash -n "$UTIL_SH"
}

test_util_sh_works_at_a_lowered_compat_level() {
  # Partial-fidelity simulation of an old bash: BASH_COMPAT=3.1 restores
  # bash-3 semantics for the constructs bash still gates on it (notably [[ =~ ]]
  # quoting). It cannot remove bash-4 syntax — that is what the static scan
  # above is for — but a regression that depends on modern semantics shows up
  # here.
  local out code
  set +e
  out="$(BASH_COMPAT=3.1 bash -c \
    'source "$1/lib/util.sh"; require_bash4 5 || exit 9; require_bash4 3 && exit 8; exit 0' \
    _ "$REPO_ROOT" 2>/dev/null)"
  code=$?
  set -e
  assert_eq "0" "$code" "require_bash4 must behave the same at compat level 3.1"
  assert_eq "" "$out" "nothing may reach stdout at compat level 3.1"
}

# ── the library contract ─────────────────────────────────────────────────────

test_util_sh_is_safe_to_source_twice() {
  # No `readonly`/`declare -r` may make a second source fail, and a caller's
  # override must survive it.
  local out code
  set +e
  out="$(bash -c '
    set -euo pipefail
    source "$1/lib/util.sh"
    source "$1/lib/util.sh"
    source "$1/lib/util.sh"
    [[ "$CLAUDE_MULTI_PROG" == "claude-multi" ]] || exit 9
    CLAUDE_MULTI_PROG="kept"
    source "$1/lib/util.sh"
    [[ "$CLAUDE_MULTI_PROG" == "kept" ]] || exit 8
    log "still works" 2>/dev/null
  ' _ "$REPO_ROOT" 2>&1)"
  code=$?
  set -e
  assert_eq "0" "$code" "lib/util.sh must be safe to source repeatedly"
  assert_eq "" "$out" "re-sourcing must be silent"
}

test_util_sh_is_a_sourced_library() {
  # Sourced, never executed: no shebang, not executable, and — critically — no
  # `set -euo pipefail`, which would leak into every caller that sources it.
  local first
  first="$(head -n 1 "$UTIL_SH")"
  assert_eq "" "$(printf '%s\n' "$first" | grep -F '#!' || true)" \
    "a sourced library must carry no shebang"
  if [[ -x "$UTIL_SH" ]]; then
    printf '  FAIL: lib/util.sh must not be executable\n' >&2
    return 1
  fi
  assert_eq "" "$(grep -nE '^[[:space:]]*set[[:space:]]+-[a-z]*e' "$UTIL_SH" || true)" \
    "a sourced library must not set -e"
}

test_util_sh_documents_the_die_versus_warn_contract() {
  # Later phases depend on this distinction being stated, not inferred: Phase 4
  # originally called die on a recoverable condition, which would have aborted
  # an add_account that should merely warn.
  local header
  header="$(sed -n '1,40p' "$UTIL_SH" | tr '[:upper:]' '[:lower:]')"
  assert_contains "$header" "unrecoverable" "the header must say die is for unrecoverable conditions"
  assert_contains "$header" "warn" "the header must name warn as the alternative"
  assert_contains "$header" "non-zero" "the header must say the caller returns non-zero instead"
}

test_util_sh_writes_nothing_to_stdout_when_sourced() {
  assert_stdout_empty_bytes bash -c 'source "$1/lib/util.sh"' _ "$REPO_ROOT"
}

# ── dispatch: run every test_* function defined above ────────────────────────
# This must be the file's last statement. A test file that defines tests and
# never runs them reports success while testing nothing.

_tests=()
while IFS= read -r _fn; do
  _tests+=("$_fn")
done < <(declare -F | sed -n 's/^declare -f \(test_[A-Za-z0-9_]*\)$/\1/p' | sort)

if ((${#_tests[@]} == 0)); then
  printf '  FAIL: no test_* functions discovered in tests/test_util_log.sh\n' >&2
  exit 1
fi

_failed=0
for _fn in "${_tests[@]}"; do
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
  "tests/test_util_log.sh" "${#_tests[@]}" "$_failed" >&2
((_failed == 0))
