#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/tests/assert.sh"
. "$REPO_ROOT/tests/fixtures/main-folder.sh"

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
CLAUDE_MULTI_ENTRYPOINT="${CLAUDE_MULTI_ENTRYPOINT:-$REPO_ROOT/bin/claude-multi}"

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
    exec "$CLAUDE_MULTI_ENTRYPOINT" "$@"
  )
}

# first_run_drive <record-prefix> <input> <out> <err> [claude-multi-args...]
# Drive the complete wrapper with scripted stdin while retaining its real exit
# status. The caller controls only temporary HOME/root/PATH values.
first_run_drive() {
  local rec="$1" input="$2" out="$3" err="$4" rc=0
  shift 4
  set +e
  printf '%s' "$input" | entrypoint_in_subshell "$rec" "$@" > "$out" 2> "$err"
  rc=$?
  set -e
  printf '%s' "$rc"
}

# wizard_direct <input> <out> <err>
# Exercise refusal paths that normal dispatch cannot reach once a root exists.
wizard_direct() {
  local input="$1" out="$2" err="$3" rc=0
  set +e
  printf '%s' "$input" | (
    set -euo pipefail
    . "$CLAUDE_MULTI_ENTRYPOINT"
    first_run_wizard
  ) > "$out" 2> "$err"
  rc=$?
  set -e
  printf '%s' "$rc"
}

# Install a deterministic mv boundary for the outer first-run publication.
# Inner seed/settings renames still execute the real mv unchanged.
install_first_run_mv_gate() {
  local mode gate real_mv
  mode="$1"
  gate="$TMP/mv-gate-$mode"
  real_mv="$(command -v mv)"
  mkdir -p "$gate"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'REAL_MV=%q\n' "$real_mv"
    cat <<'GATE'
args=("$@")
argc=${#args[@]}
source_path="${args[$((argc - 2))]}"
target_path="${args[$((argc - 1))]}"
if [[ "$target_path" == "$FIRST_RUN_GATE_TARGET" ]]; then
  case "$FIRST_RUN_GATE_MODE" in
    inspect)
      [[ ! -e "$target_path" && ! -L "$target_path" ]] || exit 91
      [[ "$(dirname -- "$source_path")" == "$(dirname -- "$target_path")" ]] || exit 92
      [[ -f "$source_path/shared/CLAUDE.md" ]] || exit 93
      find "$source_path/shared/project-memory" -type f -name MEMORY.md -print -quit |
        grep -q . || exit 94
      printf 'complete-staged-root\n' > "$FIRST_RUN_GATE_MARKER"
      ;;
    fail)
      exit 95
      ;;
    term)
      kill -TERM "$PPID"
      exit 143
      ;;
    *)
      exit 96
      ;;
  esac
fi
exec "$REAL_MV" "$@"
GATE
  } > "$gate/mv"
  chmod 700 "$gate/mv"
  printf '%s' "$gate"
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

# The complete wrapper path must contribute no bytes before the silent Claude
# stub takes over. A single newline here would already corrupt a downstream
# parser in `claude-multi work -p ... | consumer`.
test_wrapper_launch_stdout_is_byte_empty_before_claude_output() {
  mk_root
  mk_account work
  local rec="$TMP/wrapper-stdout"
  unset FAKE_CLAUDE_STDOUT

  assert_stdout_empty_bytes entrypoint_in_subshell "$rec" work -p 'hello'

  assert_link "$CLAUDE_MULTI_ROOT/work/CLAUDE.md" "../shared/CLAUDE.md"
  assert_link "$CLAUDE_MULTI_ROOT/work/agents" "../shared/agents"
  assert_eq "2" "$(rec_argc "$rec")" "the silent stub must have received the launch argv"
  assert_eq "-p" "$(rec_arg "$rec" 0)"
  assert_eq "hello" "$(rec_arg "$rec" 1)"
  assert_eq "$CLAUDE_MULTI_ROOT/work" \
    "$(rec_env_val "$rec" CLAUDE_CONFIG_DIR)" "the complete wrapper must launch work"
}

test_complete_wrapper_preserves_claude_exit_statuses() {
  mk_root
  mk_account work
  local code rec rc
  for code in 0 1 2 42 126 127 130 143 255; do
    rec="$TMP/wrapper-exit-$code"
    export FAKE_CLAUDE_EXIT="$code"
    rc=0
    set +e
    entrypoint_in_subshell "$rec" work -p x >/dev/null 2> "$rec.err"
    rc=$?
    set -e
    assert_eq "$code" "$rc" "the wrapper must preserve Claude status $code"
    assert_eq "no" "$(if [[ -e "$rec.rejected" ]]; then printf yes; else printf no; fi)" \
      "status $code must be accepted by the fixture"
    assert_eq "2" "$(rec_argc "$rec")" "status $code must come from the invoked stub"
    assert_eq "-p" "$(rec_arg "$rec" 0)"
    assert_eq "x" "$(rec_arg "$rec" 1)"
  done
  unset FAKE_CLAUDE_EXIT
}

test_complete_wrapper_refuses_relative_root_before_launch() {
  local rec="$TMP/wrapper-relative-root" out="$TMP/wrapper-relative-root.out"
  local rc=0 err
  export CLAUDE_MULTI_ROOT="relative/root"
  set +e
  entrypoint_in_subshell "$rec" work > "$out" 2> "$rec.err"
  rc=$?
  set -e
  err="$(cat "$rec.err")"

  assert_eq "1" "$rc" "a relative managed root must still be refused"
  assert_contains "$err" "absolute" "the root refusal must explain the guard"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "root refusal must leave stdout byte-empty"
  assert_eq "no" "$(if [[ -e "$rec.argv" ]]; then printf yes; else printf no; fi)" \
    "root refusal must happen before Claude"
}

test_first_run_seeds_the_full_tree_atomically_then_shows_an_empty_menu() {
  local main project slug gate rec="$TMP/first-run-atomic"
  local out="$TMP/first-run-atomic.out" rc=0 err
  main="$(make_fixture_main "$TMP/first-run-source")"
  project="$TMP/first-run-project/app"
  mkdir -p "$project"
  slug="${project//[!a-zA-Z0-9]/-}"
  mkdir -p "$main/projects/$slug/memory"
  printf '%s\n' 'remember atomically' > "$main/projects/$slug/memory/MEMORY.md"
  gate="$(install_first_run_mv_gate inspect)"
  export FIRST_RUN_GATE_TARGET="$CLAUDE_MULTI_ROOT"
  export FIRST_RUN_GATE_MODE=inspect
  export FIRST_RUN_GATE_MARKER="$TMP/first-run-atomic.marker"
  export PATH="$gate:$PATH"

  rc="$(first_run_drive "$rec" "$main"$'\nq\n' "$out" "$rec.err" work -p ignored)"
  err="$(cat "$rec.err")"

  assert_eq "0" "$rc" "a successful first run followed by q must exit cleanly"
  assert_eq "complete-staged-root" "$(cat "$FIRST_RUN_GATE_MARKER")" \
    "the outer rename must receive one complete staged root on the same parent"
  assert_eq "remember atomically" \
    "$(cat "$CLAUDE_MULTI_ROOT/shared/project-memory/$slug/MEMORY.md")" \
    "project memory must be inside the atomically published root"
  assert_contains "$(cat "$CLAUDE_MULTI_ROOT/shared/settings.json")" \
    "$CLAUDE_MULTI_ROOT/shared/hooks/post-commit-practices.sh" \
    "published settings must name the final shared hooks path"
  assert_eq "" \
    "$(grep -F '.first-run.' "$CLAUDE_MULTI_ROOT/shared/settings.json" || true)" \
    "published settings must not retain a staging path"
  assert_contains "$err" "Main Claude folder" "first run must ask for its read-only source"
  assert_contains "$err" "Claude accounts" "the menu must follow publication"
  assert_contains "$err" "no accounts yet" "first run must create no account"
  assert_eq "shared" "$(find "$CLAUDE_MULTI_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n')" \
    "only shared state may exist after first run"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "the complete first-run wrapper must leave stdout byte-empty"
  assert_eq "no" "$(if [[ -e "$rec.argv" ]]; then printf yes; else printf no; fi)" \
    "an account argument on first run must not launch or create an account"
}

test_first_run_defaults_to_home_claude_and_reasks_after_invalid_input() {
  local main rec="$TMP/first-run-reask" out="$TMP/first-run-reask.out" rc=0 err
  mkdir -p "$TMP/not-a-claude-folder"
  main="$(make_fixture_main "$HOME")"

  rc="$(first_run_drive "$rec" \
    "$TMP/not-a-claude-folder"$'\n\nq\n' "$out" "$rec.err")"
  err="$(cat "$rec.err")"

  assert_eq "0" "$rc" "a valid default answer after a rejection must seed and enter the menu"
  assert_contains "$err" "$TMP/not-a-claude-folder" "the invalid source must be identified"
  assert_contains "$err" "~/.claude" "the prompt must advertise the default source"
  assert_eq "# fixture global CLAUDE.md" \
    "$(cat "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md")" \
    "a blank retry must select HOME/.claude"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')"
  assert_eq "$HOME/.claude" "$main" "the fixture must exercise the advertised default"
}

test_first_run_refuses_existing_shared_without_consuming_an_answer() {
  mk_root
  printf '%s\n' 'hand edited' > "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md"
  local out="$TMP/first-run-reseed.out" errfile="$TMP/first-run-reseed.err" rc=0 err

  rc="$(wizard_direct 'answer-must-not-be-read' "$out" "$errfile")"
  err="$(cat "$errfile")"

  assert_eq "1" "$rc" "A38 requires a direct re-seed attempt to fail"
  assert_contains "$err" "re-seed" "the refusal must explain the protected state"
  assert_eq "" "$(printf '%s' "$err" | grep -F 'Main Claude folder' || true)" \
    "the wizard must refuse before prompting"
  assert_eq "hand edited" "$(cat "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md")" \
    "existing shared state must remain untouched"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')"
}

test_first_run_rejects_both_source_root_nesting_directions_without_writes() {
  local main before after rec="$TMP/first-run-overlap" rc=0

  main="$(make_fixture_main "$TMP/source-contains-root")"
  export CLAUDE_MULTI_ROOT="$main/managed-root"
  before="$(snapshot_tree "$main")"
  rc="$(first_run_drive "$rec" "$main"$'\n' "$rec.out" "$rec.err")"
  after="$(snapshot_tree "$main")"
  assert_eq "1" "$rc" "a managed root inside the source must be refused"
  assert_contains "$(cat "$rec.err")" "overlap"
  assert_eq "$before" "$after" "containment refusal must not even change source metadata"
  assert_eq "no" "$(if [[ -e "$CLAUDE_MULTI_ROOT" ]]; then printf yes; else printf no; fi)"

  export CLAUDE_MULTI_ROOT="$TMP/root-contains-source"
  main="$(make_fixture_main "$CLAUDE_MULTI_ROOT/source-parent")"
  before="$(snapshot_tree "$main")"
  rc="$(wizard_direct "$main"$'\n' "$rec.reverse.out" "$rec.reverse.err")"
  after="$(snapshot_tree "$main")"
  assert_eq "1" "$rc" "a source inside the managed root must be refused"
  assert_contains "$(cat "$rec.reverse.err")" "overlap"
  assert_eq "$before" "$after" "reverse containment refusal must leave the source unchanged"
  assert_eq "no" "$(if [[ -e "$CLAUDE_MULTI_ROOT/shared" ]]; then printf yes; else printf no; fi)"
}

test_first_run_leaves_the_source_byte_and_mtime_identical() {
  local main before after rec="$TMP/first-run-source-ro" rc=0
  main="$(make_fixture_main "$TMP/source-read-only")"
  before="$(snapshot_tree "$main")"

  rc="$(first_run_drive "$rec" "$main"$'\nq\n' "$rec.out" "$rec.err")"
  after="$(snapshot_tree "$main")"

  assert_eq "0" "$rc"
  assert_eq "# fixture global CLAUDE.md" \
    "$(cat "$CLAUDE_MULTI_ROOT/shared/CLAUDE.md")" \
    "the immutability assertion must cover a completed seed"
  assert_eq "$before" "$after" "first run must leave every source byte and mtime unchanged"
  assert_eq "0" "$(wc -c < "$rec.out" | tr -d '[:space:]')"
}

test_first_run_failed_publication_removes_staging_and_live_state() {
  local main gate rec="$TMP/first-run-fail" rc=0 parent base
  main="$(make_fixture_main "$TMP/source-failed-publish")"
  gate="$(install_first_run_mv_gate fail)"
  export FIRST_RUN_GATE_TARGET="$CLAUDE_MULTI_ROOT"
  export FIRST_RUN_GATE_MODE=fail
  export FIRST_RUN_GATE_MARKER="$TMP/unused-fail-marker"
  export PATH="$gate:$PATH"

  rc="$(first_run_drive "$rec" "$main"$'\n' "$rec.out" "$rec.err")"
  parent="$(dirname -- "$CLAUDE_MULTI_ROOT")"
  base="${CLAUDE_MULTI_ROOT##*/}"

  assert_eq "1" "$rc" "a failed outer rename must fail first run"
  assert_contains "$(cat "$rec.err")" "publish"
  assert_eq "no" "$(if [[ -e "$CLAUDE_MULTI_ROOT" || -L "$CLAUDE_MULTI_ROOT" ]]; then printf yes; else printf no; fi)" \
    "failed publication must expose no live root"
  assert_eq "" "$(find "$parent" -maxdepth 1 -name ".$base.first-run.*" -print)" \
    "failed publication must remove its validated staging directory"
  assert_eq "0" "$(wc -c < "$rec.out" | tr -d '[:space:]')"
}

test_first_run_term_during_publication_is_recoverable() {
  local main gate rec="$TMP/first-run-term" rc=0 parent base
  main="$(make_fixture_main "$TMP/source-term-publish")"
  gate="$(install_first_run_mv_gate term)"
  export FIRST_RUN_GATE_TARGET="$CLAUDE_MULTI_ROOT"
  export FIRST_RUN_GATE_MODE=term
  export FIRST_RUN_GATE_MARKER="$TMP/unused-term-marker"
  export PATH="$gate:$PATH"

  rc="$(first_run_drive "$rec" "$main"$'\n' "$rec.out" "$rec.err")"
  parent="$(dirname -- "$CLAUDE_MULTI_ROOT")"
  base="${CLAUDE_MULTI_ROOT##*/}"

  assert_eq "yes" "$(if (( rc != 0 )); then printf yes; else printf no; fi)" \
    "TERM during final publication must fail the invocation"
  assert_eq "no" "$(if [[ -e "$CLAUDE_MULTI_ROOT" || -L "$CLAUDE_MULTI_ROOT" ]]; then printf yes; else printf no; fi)" \
    "interruption must leave no partial live root"
  assert_eq "" "$(find "$parent" -maxdepth 1 -name ".$base.first-run.*" -print)" \
    "interruption recovery must remove validated staging"
  assert_eq "0" "$(wc -c < "$rec.out" | tr -d '[:space:]')"
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
