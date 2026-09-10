#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(cd "$here/.." && pwd)
. "$here/assert.sh"
. "$here/fixtures/main-folder.sh"
. "$repo/lib/util.sh"
. "$repo/lib/config.sh"
. "$repo/lib/links.sh"
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

# Verified fact: ~/.claude/commands does not exist. The naive loop
#   for item in CLAUDE.md agents hooks agent-memory commands; do cp -a "$main/$item" …; done
# makes `cp` exit 1 on the missing source, and `set -e` kills the whole run.
test_seed_creates_commands_empty_when_the_source_is_absent() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  assert_eq "absent" "$(kind "$main/commands")" "fixture precondition: no source commands/"

  seed_shared "$main" "$shared"

  assert_eq "dir" "$(kind "$shared/commands")" "commands/ must be created"
  assert_eq "0" "$(find "$shared/commands" -mindepth 1 | wc -l | tr -d ' ')" "commands/ must be empty"
  # and the run must have reached the LAST item, not died at the missing one
  assert_eq "dir" "$(kind "$shared/agent-memory")" "seeding continued past the missing source"
  rm -rf "$tmp"
}

test_seed_copies_commands_when_the_source_exists() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  mkdir -p "$main/commands"
  printf '# cmd\n' > "$main/commands/deploy.md"

  seed_shared "$main" "$shared"

  assert_eq "file" "$(kind "$shared/commands/deploy.md")" "existing commands/ contents copied"
  rm -rf "$tmp"
}

test_seed_survives_a_main_folder_missing_most_sources() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"
  main="$tmp/bare"; shared="$(multi_root)/shared"
  mkdir -p "$main"
  printf '{}\n' > "$main/settings.json"   # the only marker; no CLAUDE.md, no dirs

  seed_shared "$main" "$shared"   # must exit 0 under set -e

  assert_eq "absent" "$(kind "$shared/CLAUDE.md")" "absent CLAUDE.md simply skipped"
  assert_eq "absent" "$(kind "$shared/agents")"    "absent agents/ simply skipped"
  assert_eq "dir"    "$(kind "$shared/commands")"  "commands/ still created"
  rm -rf "$tmp"
}

# Verified fact: ~/.claude/skills is a RELATIVE symlink to ../.codex-skills.
# `cp -a` copies the link verbatim; inside shared/ that resolves to
# ~/.claude-multi/.codex-skills, i.e. a dangling link, and every skill is gone.
test_seed_points_shared_skills_at_the_resolved_absolute_target() {
  local tmp main shared expected; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  expected=$(readlink -f "$tmp/.codex-skills")

  seed_shared "$main" "$shared"

  assert_eq "link" "$(kind "$shared/skills")" "shared/skills must be a symlink"
  assert_link "$shared/skills" "$expected" "must be the ABSOLUTE resolved target"
  # the link must actually resolve — the dangling-link failure mode
  assert_eq "file" "$(kind "$shared/skills/brainstorm/SKILL.md")" "skills must be reachable through the link"
  assert_eq "no" "$([[ "$(readlink "$shared/skills")" == ../* ]] && printf yes || printf no)" \
    "must not be a copied relative link"
  rm -rf "$tmp"
}

test_seed_warns_and_creates_nothing_for_a_dangling_skills_link() {
  local tmp main shared err; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  rm -rf "$tmp/.codex-skills"      # link now dangles

  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)

  assert_eq "absent" "$(kind "$shared/skills")" "must NOT create a dangling shared/skills"
  assert_contains "$err" "dangling" "must warn about the dangling source link"
  rm -rf "$tmp"
}

test_seed_copies_skills_when_the_source_is_a_real_directory() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  rm -f "$main/skills"
  mkdir -p "$main/skills/local-skill"
  printf '# local\n' > "$main/skills/local-skill/SKILL.md"

  seed_shared "$main" "$shared"

  assert_eq "dir"  "$(kind "$shared/skills")" "real dir source is copied, not linked"
  assert_eq "file" "$(kind "$shared/skills/local-skill/SKILL.md")" "skills contents copied"
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
