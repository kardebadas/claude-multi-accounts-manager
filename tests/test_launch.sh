#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/assert.sh"

REAL_HOME="${REAL_HOME_GUARD:-$HOME}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cm-launch.XXXXXX")"

cleanup_launch_tmp() {
  case "${TMP:-}" in
    */cm-launch.*) rm -rf -- "$TMP" ;;
    *) printf 'FATAL: refusing to remove unexpected launch-test path: %s\n' \
         "${TMP:-<unset>}" >&2 ;;
  esac
}
trap cleanup_launch_tmp EXIT

export HOME="$TMP/home"
export CLAUDE_MULTI_ROOT="$HOME/.claude-multi"
mkdir -p "$HOME"

# Every fixture mutator calls this first. A typo may therefore fail a test, but
# can never redirect setup into the developer's real Claude directories.
guard_fake_root() {
  case "${HOME:-}" in
    ""|/|"$REAL_HOME")
      printf 'FATAL: launch test refused unsafe HOME\n' >&2
      exit 99 ;;
    "$TMP"/*) ;;
    *)
      printf 'FATAL: launch test HOME is outside its temporary tree\n' >&2
      exit 99 ;;
  esac
  case "${CLAUDE_MULTI_ROOT:-}" in
    ""|/|"$REAL_HOME"|"$REAL_HOME/.claude"|"$REAL_HOME/.claude-multi")
      printf 'FATAL: launch test refused unsafe multi root\n' >&2
      exit 99 ;;
    "$TMP"/*) ;;
    *)
      printf 'FATAL: launch test multi root is outside its temporary tree\n' >&2
      exit 99 ;;
  esac
}

# A seeded fake multi root. Accounts are deliberately created separately and
# initially unlinked so later launch tests exercise the real healing path.
mk_root() {
  guard_fake_root
  local shared="$CLAUDE_MULTI_ROOT/shared"
  mkdir -p "$shared/agents" \
           "$shared/hooks" \
           "$shared/commands" \
           "$shared/agent-memory" \
           "$shared/project-memory" \
           "$shared/plugin-cache" \
           "$TMP/codex-skills"
  printf '%s\n' '# shared rules' > "$shared/CLAUDE.md"
  printf '%s\n' '{}' > "$shared/settings.json"
  ln -s "$TMP/codex-skills" "$shared/skills"
}

mk_account() {
  guard_fake_root
  local name="${1:?mk_account needs an account name}"
  mkdir -p "$CLAUDE_MULTI_ROOT/$name/projects"
  printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{}}' \
    > "$CLAUDE_MULTI_ROOT/$name/.claude.json"
}

# The PATH seam used by every launch test.
stub_bin_dir() {
  local dir="$TMP/stub-bin"
  mkdir -p "$dir"
  ln -sfn "$REPO_ROOT/tests/fake-claude" "$dir/claude"
  printf '%s' "$dir"
}

STUB_BIN="$(stub_bin_dir)"
export PATH="$STUB_BIN:$PATH"
export FAKE_CLAUDE_LOG="$TMP/invocation"

# Copied from tests/test_fake_claude.sh: compare fully resolved identities, not
# path strings, and fail before dispatch if PATH could reach a real Claude.
canonical_path() {
  local p="${1-}" dir base
  [[ -n "$p" && -e "$p" ]] || return 1
  if p="$(readlink -f -- "$1" 2>/dev/null)" && [[ -n "$p" ]]; then
    printf '%s' "$p"
    return 0
  fi
  dir="$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P)" || return 1
  base="$(basename -- "$1")"
  printf '%s/%s' "$dir" "$base"
}

require_fake_claude_wiring() {
  local stub="${1-}" on_path="" want="" got=""
  hash -r 2>/dev/null || true
  if [[ ! -f "$stub" ]]; then
    printf '  FAIL: %s does not exist; refusing to run (PATH would resolve the real claude)\n' \
      "$stub" >&2
    return 1
  fi
  if [[ ! -x "$stub" ]]; then
    printf '  FAIL: %s is not executable; refusing to run (PATH would resolve the real claude)\n' \
      "$stub" >&2
    return 1
  fi
  on_path="$(command -v claude 2>/dev/null || true)"
  if [[ -z "$on_path" ]]; then
    printf '  FAIL: PATH resolves no claude at all; refusing to run (the stub is not on PATH)\n' >&2
    return 1
  fi
  if ! want="$(canonical_path "$stub")" || [[ -z "$want" ]]; then
    printf '  FAIL: cannot resolve the stub [%s]; refusing to run\n' "$stub" >&2
    return 1
  fi
  if ! got="$(canonical_path "$on_path")" || [[ -z "$got" ]]; then
    printf '  FAIL: PATH resolves claude to [%s], which does not resolve; refusing to run\n' \
      "$on_path" >&2
    return 1
  fi
  if [[ "$want" != "$got" ]]; then
    printf '  FAIL: PATH does not resolve claude to the stub; refusing to run (want [%s], got [%s] via [%s])\n' \
      "$want" "$got" "$on_path" >&2
    return 1
  fi
  return 0
}

# This precondition deliberately precedes test discovery and dispatch.
require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude" || exit 1

# Sidecar readers. The readable line log is never an assertion authority.
rec_argv() {
  local file="$1.argv" arg index=0
  [[ -f "$file" ]] || return 0
  while IFS= read -r -d '' arg; do
    printf '%d\t%s\n' "$index" "$arg"
    index=$(( index + 1 ))
  done < "$file"
}

rec_argc() {
  local file="$1.argv" arg count=0
  [[ -f "$file" ]] || { printf '0'; return 0; }
  while IFS= read -r -d '' arg; do count=$(( count + 1 )); done < "$file"
  printf '%s' "$count"
}

rec_arg() {
  local file="$1.argv" wanted="$2" arg index=0
  [[ -f "$file" ]] || return 1
  while IFS= read -r -d '' arg; do
    if [[ "$index" == "$wanted" ]]; then
      printf '%s' "$arg"
      return 0
    fi
    index=$(( index + 1 ))
  done < "$file"
  return 1
}

rec_env_val() {
  local file="$1.env" wanted="$2" entry
  [[ -f "$file" ]] || return 1
  while IFS= read -r -d '' entry; do
    if [[ "${entry%%=*}" == "$wanted" ]]; then
      printf '%s' "${entry#*=}"
      return 0
    fi
  done < "$file"
  return 1
}

declare -a REC_ENV_ENTRIES=()
read_env_record() {
  REC_ENV_ENTRIES=()
  local entry
  while IFS= read -r -d '' entry; do
    REC_ENV_ENTRIES+=("$entry")
  done < "$1.env"
}

# A test-only library seam lets the next argv-contract task mutate a private
# copy without ever changing the working tree.
LAUNCH_LIB="${LAUNCH_LIB:-$REPO_ROOT/lib/launch.sh}"

# launch_in_subshell <record-prefix> <account> [claude-args...]
# `exec` replaces only this child. The identity guard runs inside it after the
# final PATH assignment, immediately before any launch code can dispatch.
launch_in_subshell() {
  local rec="$1"
  shift
  (
    set -euo pipefail
    export PATH="$(stub_bin_dir):$PATH"
    export FAKE_CLAUDE_LOG="$rec"
    require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude"
    . "$REPO_ROOT/lib/util.sh"
    . "$REPO_ROOT/lib/config.sh"
    . "$REPO_ROOT/lib/links.sh"
    . "$REPO_ROOT/lib/memory.sh"
    if [[ -n "${LAUNCH_REPAIR_TRACE:-}" ]]; then
      heal_account() {
        printf 'heal\n' >> "$LAUNCH_REPAIR_TRACE"
        return "${LAUNCH_HEAL_RC:-0}"
      }
      sync_project_memory() {
        printf 'sync\n' >> "$LAUNCH_REPAIR_TRACE"
        return "${LAUNCH_SYNC_RC:-0}"
      }
    fi
    . "$LAUNCH_LIB"
    launch_account "$@"
    printf 'FATAL: launch_account returned after a successful Claude invocation\n' >&2
    return 98
  )
}

# entrypoint_in_subshell <record-prefix> [claude-multi-args...]
# Unlike launch_in_subshell, this crosses main and dispatch_args. The identity
# guard runs after the final PATH assignment and immediately before exec.
entrypoint_in_subshell() {
  local rec="$1"
  shift
  (
    set -euo pipefail
    export PATH="$(stub_bin_dir):$PATH"
    export FAKE_CLAUDE_LOG="$rec"
    require_fake_claude_wiring "$REPO_ROOT/tests/fake-claude"
    exec "$REPO_ROOT/bin/claude-multi" "$@"
  )
}

test_fixture_guard_refuses_real_home_and_root() {
  local rc=0 err
  set +e
  err="$( (
    export HOME="$REAL_HOME"
    export CLAUDE_MULTI_ROOT="$REAL_HOME/.claude-multi"
    mk_root
  ) 2>&1 >/dev/null )"
  rc=$?
  set -e
  assert_eq "99" "$rc" "fixture setup must refuse the real HOME and multi root"
  assert_contains "$err" "FATAL: launch test refused unsafe HOME"
}

test_harness_resolves_the_executable_stub_before_dispatch() {
  local want got decoy rc=0 err
  want="$(canonical_path "$REPO_ROOT/tests/fake-claude")"
  got="$(canonical_path "$(command -v claude)")"
  assert_eq "$want" "$got" "PATH must select the canonical fake Claude"
  assert_eq "yes" "$(if [[ -x "$(command -v claude)" ]]; then printf yes; else printf no; fi)" \
    "the selected stub must be executable"

  # Mutation proof for the dangerous PATH-append typo: an earlier executable
  # must make the guard refuse instead of dispatching it.
  decoy="$TMP/decoy-bin"
  mkdir -p "$decoy"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$decoy/claude"
  chmod 700 "$decoy/claude"
  set +e
  err="$(PATH="$decoy:$PATH" require_fake_claude_wiring \
    "$REPO_ROOT/tests/fake-claude" 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "1" "$rc" "a decoy ahead of the stub must be refused"
  assert_contains "$err" "does not resolve claude to the stub"
}

test_sidecar_readers_ignore_the_forgeable_line_log() {
  local rec="$TMP/line-log-mutant"
  printf '%s\n' 'ARGC=2' 'ARG=forged-one' 'ARG=forged-two' \
    'CLAUDE_CONFIG_DIR=/forged' > "$rec"
  printf '%s\0' 'real-sidecar-argument' > "$rec.argv"
  printf '%s\0' 'CLAUDE_CONFIG_DIR=' \
    'CLAUDE_CODE_PLUGIN_CACHE_DIR=' "HOME=$HOME" "PWD=$PWD" > "$rec.env"

  assert_eq "1" "$(rec_argc "$rec")" \
    "argv assertions must use the NUL sidecar, not the readable log"
  assert_eq "real-sidecar-argument" "$(rec_arg "$rec" 0)"
  assert_eq "" "$(rec_env_val "$rec" CLAUDE_CONFIG_DIR)" \
    "environment assertions must use the NUL sidecar"
}

test_stub_contract_records_nul_argv_four_env_entries_and_exit() {
  mk_root
  mk_account work
  local rec="$TMP/headline" out="$TMP/headline.out" rc=0
  set +e
  env -u CLAUDE_CODE_PLUGIN_CACHE_DIR \
    PATH="$PATH" HOME="$HOME" FAKE_CLAUDE_LOG="$rec" FAKE_CLAUDE_EXIT=7 \
    CLAUDE_CONFIG_DIR="$CLAUDE_MULTI_ROOT/work" \
    claude --resume "two words" '' > "$out"
  rc=$?
  set -e

  assert_eq "7" "$rc" "a validated fake-Claude status must propagate"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the stub writes zero stdout bytes by default"
  assert_eq "3" "$(rec_argc "$rec")"
  assert_eq "--resume" "$(rec_arg "$rec" 0)"
  assert_eq "two words" "$(rec_arg "$rec" 1)"
  assert_eq "" "$(rec_arg "$rec" 2)" "the empty third argument must survive"

  read_env_record "$rec"
  assert_eq "4" "${#REC_ENV_ENTRIES[@]}" "the env sidecar has exactly four entries"
  assert_eq "CLAUDE_CONFIG_DIR=$CLAUDE_MULTI_ROOT/work" "${REC_ENV_ENTRIES[0]}"
  assert_eq "CLAUDE_CODE_PLUGIN_CACHE_DIR=" "${REC_ENV_ENTRIES[1]}"
  assert_eq "HOME=$HOME" "${REC_ENV_ENTRIES[2]}"
  assert_eq "PWD=$PWD" "${REC_ENV_ENTRIES[3]}"
  assert_eq "no" "$(if [[ -e "$rec.rejected" ]]; then printf yes; else printf no; fi)" \
    "an accepted exit value must not leave a rejection marker"
}

test_stub_stdout_knob_and_invalid_exit_are_byte_exact() {
  local rec="$TMP/knobs" out="$TMP/knobs.out" err="$TMP/knobs.err" rc=0
  FAKE_CLAUDE_LOG="$rec" FAKE_CLAUDE_STDOUT=$'one\ntwo\n' \
    claude > "$out"
  assert_eq "8" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "FAKE_CLAUDE_STDOUT must be emitted verbatim"
  assert_eq "$(printf 'one\ntwo')" "$(cat "$out")"

  set +e
  FAKE_CLAUDE_LOG="$rec" FAKE_CLAUDE_EXIT=256 FAKE_CLAUDE_STDOUT=leak \
    claude > "$out" 2> "$err"
  rc=$?
  set -e
  assert_eq "64" "$rc" "an invalid exit value must be rejected out of band"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "invalid exit validation must happen before stdout"
  assert_eq "256" "$(cat "$rec.rejected")"
  assert_contains "$(cat "$err")" "FAKE_CLAUDE_EXIT must be an integer 0-255"
}

test_entrypoint_sources_the_launch_library() {
  local rc=0
  set +e
  (
    unset -f launch_account 2>/dev/null || true
    . "$REPO_ROOT/bin/claude-multi"
    declare -F launch_account >/dev/null
  )
  rc=$?
  set -e
  assert_eq "0" "$rc" "sourcing the entrypoint must export launch_account"
}

test_launch_sets_env_preserves_home_pwd_and_execs_the_stub() {
  mk_root
  mk_account work
  local rec="$TMP/launch-env" caller="$TMP/caller" out="$TMP/launch-env.out" rc=0
  mkdir -p "$caller"
  set +e
  (
    cd "$caller"
    launch_in_subshell "$rec" work --resume
  ) > "$out" 2> "$TMP/launch-env.err"
  rc=$?
  set -e

  assert_eq "0" "$rc" "the launch must end with the stub's success status"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "a silent Claude launch must add no stdout bytes"
  assert_eq "1" "$(rec_argc "$rec")" "the PATH-selected stub must execute"
  assert_eq "--resume" "$(rec_arg "$rec" 0)"
  read_env_record "$rec"
  assert_eq "4" "${#REC_ENV_ENTRIES[@]}"
  assert_eq "CLAUDE_CONFIG_DIR=$CLAUDE_MULTI_ROOT/work" "${REC_ENV_ENTRIES[0]}"
  assert_eq "CLAUDE_CODE_PLUGIN_CACHE_DIR=$CLAUDE_MULTI_ROOT/shared/plugin-cache" \
    "${REC_ENV_ENTRIES[1]}"
  assert_eq "HOME=$HOME" "${REC_ENV_ENTRIES[2]}" "launch must preserve HOME"
  assert_eq "PWD=$caller" "${REC_ENV_ENTRIES[3]}" "launch must preserve PWD"
}

test_launch_validates_and_uses_the_canonical_account_name() {
  mk_root
  mk_account work
  local rec="$TMP/canonical" rc=0 err
  set +e
  err="$(launch_in_subshell "$rec" WORK 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "0" "$rc" "uppercase input must launch its canonical account"
  assert_contains "$err" "lowercase"
  assert_contains "$err" "using 'work'"
  assert_eq "$CLAUDE_MULTI_ROOT/work" \
    "$(rec_env_val "$rec" CLAUDE_CONFIG_DIR)"
}

test_launch_rejects_invalid_and_unknown_accounts_before_exec() {
  mk_root
  mk_account work
  local invalid="$TMP/invalid-account" unknown="$TMP/unknown-account"
  local rc=0 err out

  set +e
  out="$(launch_in_subshell "$invalid" '../work' 2> "$TMP/invalid-account.err")"
  rc=$?
  set -e
  assert_eq "1" "$rc" "invalid account grammar must be rejected"
  assert_eq "" "$out" "invalid input must leave stdout empty"
  assert_eq "no" "$(if [[ -e "$invalid.argv" ]]; then printf yes; else printf no; fi)" \
    "invalid input must not reach Claude"

  rc=0
  set +e
  err="$(launch_in_subshell "$unknown" missing 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "1" "$rc" "a valid but absent account must be rejected"
  assert_contains "$err" "unknown account"
  assert_contains "$err" "missing"
  assert_eq "no" "$(if [[ -e "$unknown.argv" ]]; then printf yes; else printf no; fi)" \
    "an unknown account must not reach Claude"
}

test_launch_heals_and_syncs_before_exec() {
  mk_root
  mk_account work
  local rec="$TMP/repairs" rc=0
  set +e
  launch_in_subshell "$rec" work >/dev/null 2> "$TMP/repairs.err"
  rc=$?
  set -e
  assert_eq "0" "$rc"
  assert_link "$CLAUDE_MULTI_ROOT/work/CLAUDE.md" "../shared/CLAUDE.md"
  assert_link "$CLAUDE_MULTI_ROOT/work/agents" "../shared/agents"
  assert_eq "no" "$(if [[ -L "$CLAUDE_MULTI_ROOT/work/security" ]]; then printf yes; else printf no; fi)" \
    "security must never be linked"
  assert_eq "yes" "$(if [[ -f "$rec.argv" && -f "$rec.env" ]]; then printf yes; else printf no; fi)" \
    "the stub sidecars must exist after repairs"
  assert_eq "0" "$(rec_argc "$rec")" "a zero-argument launch remains valid"
}

test_launch_warns_but_continues_when_both_repairs_fail() {
  mk_root
  mk_account work
  local rec="$TMP/repair-fail" trace="$TMP/repair.trace"
  local rc=0 err out="$TMP/repair-fail.out"
  set +e
  err="$(LAUNCH_REPAIR_TRACE="$trace" LAUNCH_HEAL_RC=1 LAUNCH_SYNC_RC=1 \
    launch_in_subshell "$rec" work 2>&1 > "$out")"
  rc=$?
  set -e
  assert_eq "0" "$rc" "repair failures must not prevent the Claude exec"
  assert_eq $'heal\nsync' "$(cat "$trace")" \
    "heal must run before memory sync"
  assert_contains "$err" "launching anyway"
  assert_contains "$err" "memory"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')"
  assert_eq "$CLAUDE_MULTI_ROOT/work" \
    "$(rec_env_val "$rec" CLAUDE_CONFIG_DIR)" \
    "the stub must still run after both repair failures"
}

test_argv_passthrough_is_byte_faithful() {
  mk_root
  mk_account work
  # A leaked, unquoted glob would expand to both of these files in launch's CWD.
  mkdir -p "$TMP/globdir"
  : > "$TMP/globdir/decoy-a.txt"
  : > "$TMP/globdir/decoy-b.txt"

  local rec="$TMP/argv-fidelity" rc=0
  set +e
  (
    cd "$TMP/globdir"
    launch_in_subshell "$rec" work \
      --resume \
      -p 'two words' \
      "quoted 'single' and \"double\"" \
      '*.txt' \
      '' \
      'trailing space ' \
      'semi;colon|pipe&amp' \
      '$HOME/not-expanded' \
      '--' \
      -
  ) >/dev/null 2> "$TMP/argv-fidelity.err"
  rc=$?
  set -e

  assert_eq "0" "$rc" "the launch must reach the recording stub"
  assert_eq "11" "$(rec_argc "$rec")" "all eleven arguments must arrive"
  assert_eq "--resume" "$(rec_arg "$rec" 0)" "argv[0] leading dashes"
  assert_eq "-p" "$(rec_arg "$rec" 1)" "argv[1] short flag"
  assert_eq "two words" "$(rec_arg "$rec" 2)" "argv[2] one argument with a space"
  assert_eq "quoted 'single' and \"double\"" "$(rec_arg "$rec" 3)" \
    "argv[3] quote characters"
  assert_eq '*.txt' "$(rec_arg "$rec" 4)" "argv[4] unexpanded glob"
  assert_eq "" "$(rec_arg "$rec" 5)" "argv[5] empty argument"
  assert_eq "trailing space " "$(rec_arg "$rec" 6)" "argv[6] trailing space"
  assert_eq 'semi;colon|pipe&amp' "$(rec_arg "$rec" 7)" "argv[7] shell metacharacters"
  assert_eq '$HOME/not-expanded' "$(rec_arg "$rec" 8)" "argv[8] literal dollar expansion"
  assert_eq "--" "$(rec_arg "$rec" 9)" "argv[9] bare double dash"
  assert_eq "-" "$(rec_arg "$rec" 10)" "argv[10] bare dash"
}

test_launch_with_zero_claude_arguments_records_an_empty_sidecar() {
  mk_root
  mk_account personal
  local rec="$TMP/argv-empty" rc=0
  set +e
  launch_in_subshell "$rec" personal >/dev/null 2> "$TMP/argv-empty.err"
  rc=$?
  set -e

  assert_eq "0" "$rc" "the zero-argument launch must reach the stub"
  assert_eq "0" "$(rec_argc "$rec")" "no Claude arguments means no argv elements"
  assert_eq "$CLAUDE_MULTI_ROOT/personal" \
    "$(rec_env_val "$rec" CLAUDE_CONFIG_DIR)" "the intended account must still launch"
}

test_dispatch_treats_verb_words_as_account_names() {
  mk_root
  local word rec
  for word in add delete sync doctor list menu help version; do
    mk_account "$word"
  done

  for word in add delete sync doctor list menu help version; do
    rec="$TMP/dispatch-word-$word"
    entrypoint_in_subshell "$rec" "$word" --resume >/dev/null 2> "$rec.err"
    assert_eq "$CLAUDE_MULTI_ROOT/$word" \
      "$(rec_env_val "$rec" CLAUDE_CONFIG_DIR)" \
      "'$word' must remain an account name"
    assert_eq "1" "$(rec_argc "$rec")" "'$word' must forward one Claude argument"
    assert_eq "--resume" "$(rec_arg "$rec" 0)" "'$word' must forward its argument"
  done
}

test_dispatch_forwards_following_argv_unchanged_and_keeps_stdout_empty() {
  mk_root
  mk_account work
  local rec="$TMP/dispatch-argv" out="$TMP/dispatch-argv.out" rc=0
  set +e
  entrypoint_in_subshell "$rec" WORK \
    -p 'two words' '*.txt' '' '--' - > "$out" 2> "$rec.err"
  rc=$?
  set -e

  assert_eq "0" "$rc" "dispatch must reach the recording stub"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "normal dispatch must leave stdout byte-empty"
  assert_contains "$(cat "$rec.err")" "using 'work'" \
    "uppercase account canonicalization must remain on stderr"
  assert_eq "6" "$(rec_argc "$rec")" "dispatch must preserve argument count and order"
  assert_eq "-p" "$(rec_arg "$rec" 0)"
  assert_eq "two words" "$(rec_arg "$rec" 1)"
  assert_eq '*.txt' "$(rec_arg "$rec" 2)"
  assert_eq "" "$(rec_arg "$rec" 3)"
  assert_eq "--" "$(rec_arg "$rec" 4)"
  assert_eq "-" "$(rec_arg "$rec" 5)"
}

test_dispatch_rejects_absent_reserved_and_unrecognized_flag_names() {
  mk_root
  local input slug rec rc out err
  for input in doctor shared --bogus; do
    slug="${input//[^a-zA-Z0-9]/_}"
    rec="$TMP/dispatch-refuse-$slug"
    rc=0
    set +e
    out="$(entrypoint_in_subshell "$rec" "$input" 2> "$rec.err")"
    rc=$?
    set -e
    err="$(cat "$rec.err")"
    assert_eq "1" "$rc" "'$input' must be refused as an account, not handled as a verb"
    assert_eq "" "$out" "'$input' refusal must leave stdout empty"
    assert_eq "no" "$(if [[ -e "$rec.argv" ]]; then printf yes; else printf no; fi)" \
      "'$input' must not reach Claude"
    assert_contains "$err" "${input#--}" "'$input' refusal must identify the input"
  done
}

test_dispatch_handles_only_help_and_version_flags_before_root_state() {
  local flag slug rec rc out err
  export CLAUDE_MULTI_ROOT="$TMP/root-does-not-exist"
  for flag in --help -h --version; do
    slug="${flag//[^a-zA-Z0-9]/_}"
    rec="$TMP/dispatch-flag-$slug"
    rc=0
    set +e
    out="$(entrypoint_in_subshell "$rec" "$flag" 2> "$rec.err")"
    rc=$?
    set -e
    err="$(cat "$rec.err")"
    assert_eq "0" "$rc" "$flag must succeed before root or account resolution"
    assert_eq "" "$out" "$flag must write no stdout"
    assert_eq "yes" "$(if [[ -s "$rec.err" ]]; then printf yes; else printf no; fi)" \
      "$flag must emit wrapper UI on stderr"
    assert_eq "no" "$(if [[ -e "$rec.argv" ]]; then printf yes; else printf no; fi)" \
      "$flag must not dispatch Claude"
  done
}

test_dispatch_version_names_the_program_and_version() {
  local rec="$TMP/dispatch-version" err
  err="$(entrypoint_in_subshell "$rec" --version 2>&1 >/dev/null)"
  assert_contains "$err" "claude-multi" "version output must name the program"
  assert_contains "$err" "0.1.0" "version output must include the current version"
}

test_dispatch_with_no_arguments_enters_the_menu() {
  mk_root
  mk_account personal
  local rec="$TMP/dispatch-menu" out="$TMP/dispatch-menu.out" err rc=0
  set +e
  entrypoint_in_subshell "$rec" </dev/null > "$out" 2> "$rec.err"
  rc=$?
  set -e
  err="$(cat "$rec.err")"

  assert_eq "0" "$rc" "EOF at a bare invocation must leave the menu cleanly"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the menu path must leave stdout byte-empty"
  assert_contains "$err" "Claude accounts" "bare invocation must render the menu"
  assert_contains "$err" "personal" "the menu must list the account"
  assert_eq "no" "$(if [[ -e "$rec.argv" ]]; then printf yes; else printf no; fi)" \
    "EOF at the menu must not launch Claude"
}

# Harness-teeth mutation proof: copy this file's real dispatcher beneath an
# early-failing test whose later assertion would pass if errexit were masked.
test_runner_dispatch_reports_an_early_failing_assertion() {
  local dir probe rc=0 err
  dir="$(mktemp -d "${TMPDIR:-/tmp}/cm-launch-teeth.XXXXXX")"
  probe="$dir/probe.sh"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '. %q\n' "$REPO_ROOT/tests/assert.sh"
    printf '%s\n' \
      'test_early_fail_then_pass() {' \
      '  assert_eq "expected" "actual" "the first assertion must abort"' \
      '  printf "LAUNCH-TEETH-SENTINEL\n" >&2' \
      '  assert_eq "same" "same" "a later pass must not rescue the test"' \
      '}' \
      'test_clean_control() { assert_eq "a" "a"; }'
    sed -n '/^# ── RUNNER ──/,$p' "$REPO_ROOT/tests/test_launch.sh"
  } > "$probe"

  set +e
  err="$(env -u CM_ONE_TEST bash -- "$probe" 2>&1 >/dev/null)"
  rc=$?
  set -e
  rm -rf -- "$dir"
  assert_eq "1" "$rc" "the dispatcher must report an early failed assertion"
  assert_contains "$err" "FAIL  test_early_fail_then_pass"
  assert_contains "$err" "pass  test_clean_control"
  assert_contains "$err" "2 test(s), 1 failure(s)"
  assert_eq "" "$(printf '%s\n' "$err" | grep -F 'LAUNCH-TEETH-SENTINEL' || true)" \
    "the failing test must stop before its later passing assertion"
}

# ── RUNNER ── KEEP THIS BLOCK LAST IN THE FILE ───────────────────────────────
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
  printf 'FATAL: tests/test_launch.sh defined no tests — refusing false green\n' >&2
  exit 1
fi
if (( _cm_failed > 0 )); then
  exit 1
fi
