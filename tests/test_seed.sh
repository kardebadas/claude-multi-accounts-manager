#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
. "$here/assert.sh"
. "$here/fixtures/main-folder.sh"
. "$repo/lib/util.sh"
. "$repo/lib/config.sh"
. "$repo/lib/seed.sh"

# Every test gets its own temp HOME + multi root. The real ~/.claude is never touched.
SANDBOX_TMP=""
new_sandbox() {
  SANDBOX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/cmseed.XXXXXX")
  export HOME="$SANDBOX_TMP/home"
  export CLAUDE_MULTI_ROOT="$SANDBOX_TMP/home/.claude-multi"
  mkdir -p "$HOME"
}

test_validate_accepts_a_claude_config_dir() {
  local tmp main; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  validate_main_folder "$main"
  rm -rf "$tmp"
}

test_validate_rejects_a_dir_that_is_not_a_claude_config_dir() {
  local tmp; new_sandbox; tmp="$SANDBOX_TMP"
  mkdir -p "$tmp/plain"
  printf 'x\n' > "$tmp/plain/random.txt"
  assert_fails validate_main_folder "$tmp/plain"
  rm -rf "$tmp"
}

test_validate_rejects_a_relative_path() {
  local tmp main; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  (
    cd "$tmp"
    assert_fails validate_main_folder ".claude"
    mkdir -p "$tmp/nested"
    cd "$tmp/nested"
    assert_fails validate_main_folder "../.claude"
  )
  rm -rf "$tmp"
}

test_validate_rejects_a_nonexistent_path() {
  local tmp; new_sandbox; tmp="$SANDBOX_TMP"
  assert_fails validate_main_folder "$tmp/nope"
  rm -rf "$tmp"
}

test_validate_rejects_the_multi_root_itself() {
  local tmp root; new_sandbox; tmp="$SANDBOX_TMP"; root=$(multi_root)
  # A root that looks like a Claude dir must STILL be rejected.
  mkdir -p "$root"
  printf '{}\n' > "$root/settings.json"
  assert_fails validate_main_folder "$root"
  rm -rf "$tmp"
}

test_validate_accepts_a_path_with_spaces() {
  local tmp main; new_sandbox; tmp="$SANDBOX_TMP"
  mkdir -p "$tmp/my configs"
  main=$(make_fixture_main "$tmp/my configs" "claude dir")
  validate_main_folder "$main"
  rm -rf "$tmp"
}

test_validate_accepts_a_symlinked_path() {
  local tmp main; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  ln -sfn "$main" "$tmp/link-to-claude"
  validate_main_folder "$tmp/link-to-claude"
  rm -rf "$tmp"
}

test_validate_reports_its_reason_on_stderr_only() {
  local tmp out; new_sandbox; tmp="$SANDBOX_TMP"
  out=$(validate_main_folder "$tmp/nope" 2>/dev/null || true)
  assert_eq "" "$out" "rejection must not write to stdout"
  rm -rf "$tmp"
}

test_seed_copies_the_shared_config_items() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"

  seed_shared "$main" "$shared"

  assert_eq "file" "$(kind "$shared/CLAUDE.md")"        "CLAUDE.md copied"
  assert_eq "# fixture global CLAUDE.md" "$(cat "$shared/CLAUDE.md")" "CLAUDE.md content"
  assert_eq "dir"  "$(kind "$shared/agents")"           "agents/ copied"
  assert_eq "file" "$(kind "$shared/agents/brainstorm-architect.md")" "agents/ contents copied"
  assert_eq "dir"  "$(kind "$shared/hooks")"            "hooks/ copied"
  assert_eq "file" "$(kind "$shared/hooks/post-commit-practices.sh")" "hook script copied"
  assert_eq "dir"  "$(kind "$shared/plugin-cache")"     "plugin-cache/ created"

  # agent-memory keeps its subdirectory structure
  assert_eq "file" "$(kind "$shared/agent-memory/software-engineer/notes.md")"   "memory subdir 1"
  assert_eq "file" "$(kind "$shared/agent-memory/brainstorm-architect/notes.md")" "memory subdir 2"

  # the copied hook stays executable, or the hook silently stops firing
  assert_eq "yes" "$([[ -x "$shared/hooks/post-commit-practices.sh" ]] && printf yes || printf no)" \
    "hook must remain executable"
  rm -rf "$tmp"
}

test_seed_writes_nothing_to_stdout() {
  local tmp main; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  assert_stdout_empty_bytes seed_shared "$main" "$(multi_root)/shared"
  rm -rf "$tmp"
}

test_seed_rejects_an_invalid_main_folder() {
  local tmp; new_sandbox; tmp="$SANDBOX_TMP"
  mkdir -p "$tmp/plain"
  assert_fails seed_shared "$tmp/plain" "$(multi_root)/shared"
  assert_eq "absent" "$(kind "$(multi_root)/shared/CLAUDE.md")" "nothing seeded on rejection"
  rm -rf "$tmp"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  status=0
  runner_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmseed-run.XXXXXX")
  cleanup_runner_tmp() {
    case "$runner_tmp" in
      */cmseed-run.*) rm -rf -- "$runner_tmp" ;;
      *) printf 'refusing to remove unexpected temp dir: %s\n' "$runner_tmp" >&2 ;;
    esac
  }
  trap cleanup_runner_tmp EXIT
  while read -r fn; do
    set +e
    ( export TMPDIR="$runner_tmp"; set -e; "$fn" )
    fn_status=$?
    set -e
    if (( fn_status == 0 )); then printf 'ok   %s\n' "$fn" >&2; else status=1; printf 'FAIL %s\n' "$fn" >&2; fi
  done < <(declare -F | awk '{print $3}' | grep '^test_')
  exit "$status"
fi
