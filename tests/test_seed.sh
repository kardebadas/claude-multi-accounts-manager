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

# Verified fact: the real settings.json hook command is an absolute path into the
# main folder. Left alone, every managed account would EXECUTE code out of the
# folder the spec calls read-only. jq is not an allowed dependency -> awk.
test_rewrite_moves_the_hook_command_into_shared_hooks() {
  local tmp main shared out; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"; mkdir -p "$shared"

  rewrite_hook_paths "$main/settings.json" "$shared/settings.json" "$main" "$shared"
  out=$(cat "$shared/settings.json")

  assert_contains "$out" "\"command\": \"$shared/hooks/post-commit-practices.sh\"" \
    "hook command must point into shared/hooks"
  assert_eq "no" "$(grep -qF "$main/hooks/" "$shared/settings.json" && printf yes || printf no)" \
    "no hook path may still point into the main folder"
  rm -rf "$tmp"
}

test_rewrite_preserves_everything_else_including_the_work_profile() {
  local tmp main shared out; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"; mkdir -p "$shared"

  rewrite_hook_paths "$main/settings.json" "$shared/settings.json" "$main" "$shared"
  out=$(cat "$shared/settings.json")

  assert_contains "$out" '"model": "opus[1m]"'              "model preserved"
  assert_contains "$out" '"environment": "work-profile"'    "autoMode profile preserved"
  assert_contains "$out" '"matcher": "Bash"'                "matcher preserved"
  assert_eq "$(wc -l < "$main/settings.json")" "$(wc -l < "$shared/settings.json")" \
    "line count unchanged — a transform, not a reformat"
  rm -rf "$tmp"
}

test_rewrite_leaves_the_source_settings_untouched() {
  local tmp main shared before after; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"; mkdir -p "$shared"
  before=$(md5sum < "$main/settings.json")

  rewrite_hook_paths "$main/settings.json" "$shared/settings.json" "$main" "$shared"

  after=$(md5sum < "$main/settings.json")
  assert_eq "$before" "$after" "source settings.json must not change"
  rm -rf "$tmp"
}

test_rewrite_writes_no_temp_file_behind() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"; mkdir -p "$shared"

  rewrite_hook_paths "$main/settings.json" "$shared/settings.json" "$main" "$shared"

  assert_eq "0" "$(find "$shared" -maxdepth 1 -name 'settings.json.tmp*' | wc -l | tr -d ' ')" \
    "temp file must be renamed away"
  rm -rf "$tmp"
}

test_seed_produces_a_settings_json_with_rewritten_hooks() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"

  seed_shared "$main" "$shared"

  assert_eq "file" "$(kind "$shared/settings.json")" "settings.json seeded"
  assert_contains "$(cat "$shared/settings.json")" \
    "\"command\": \"$shared/hooks/post-commit-practices.sh\"" "hook rewritten during seeding"
  # and the rewritten target must actually exist, because hooks/ was copied
  assert_eq "file" "$(kind "$shared/hooks/post-commit-practices.sh")" "rewritten target exists"
  rm -rf "$tmp"
}

test_rewrite_handles_a_main_folder_path_with_spaces() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"
  mkdir -p "$tmp/my configs"
  main=$(make_fixture_main "$tmp/my configs" "claude dir")
  shared="$(multi_root)/my shared"

  seed_shared "$main" "$shared"

  assert_contains "$(cat "$shared/settings.json")" \
    "\"command\": \"$shared/hooks/post-commit-practices.sh\"" "spaces in both paths handled"
  assert_eq "no" "$(grep -qF "$main/hooks/" "$shared/settings.json" && printf yes || printf no)" \
    "old path fully gone"
  rm -rf "$tmp"
}

test_rewrite_copies_a_settings_json_with_no_hooks_key_verbatim() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"
  main="$tmp/nohooks"; shared="$(multi_root)/shared"
  mkdir -p "$main"
  printf '{\n  "model": "opus[1m]"\n}\n' > "$main/settings.json"

  seed_shared "$main" "$shared"

  assert_eq "$(md5sum < "$main/settings.json")" "$(md5sum < "$shared/settings.json")" \
    "with nothing to rewrite the file is byte-identical"
  rm -rf "$tmp"
}

test_seed_warns_when_a_main_folder_path_survives_the_rewrite() {
  local tmp main shared err; new_sandbox; tmp="$SANDBOX_TMP"
  main="$tmp/odd"; shared="$(multi_root)/shared"
  mkdir -p "$main"
  # a command that points into the main folder but NOT into its hooks/ dir
  printf '{\n  "hooks": { "PostToolUse": [ { "hooks": [ { "type": "command", "command": "%s/scripts/x.sh" } ] } ] }\n}\n' \
    "$main" > "$main/settings.json"

  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)

  assert_contains "$err" "still references the main folder" "unhandled source path must be reported"
  rm -rf "$tmp"
}

test_seed_skips_an_absent_settings_json() {
  local tmp main shared; new_sandbox; tmp="$SANDBOX_TMP"
  main="$tmp/nosettings"; shared="$(multi_root)/shared"
  mkdir -p "$main"
  printf '# only a CLAUDE.md marker\n' > "$main/CLAUDE.md"

  seed_shared "$main" "$shared"

  assert_eq "absent" "$(kind "$shared/settings.json")" "absent settings.json simply skipped"
  rm -rf "$tmp"
}

make_observing_awk_stub() {
  local path="$1"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ -e "$SEED_OBSERVED_TARGET" || -L "$SEED_OBSERVED_TARGET" ]]; then exit 97; fi' \
    'exec "$SEED_REAL_AWK" "$@"' > "$path"
  chmod +x "$path"
}

make_failing_awk_stub() {
  local path="$1"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 1' > "$path"
  chmod +x "$path"
}

make_signalling_awk_stub() {
  local path="$1"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'kill -s "$SEED_SIGNAL" "$PPID"' \
    'exit 1' > "$path"
  chmod +x "$path"
}

# Create a competing directory only when seed_shared reaches its final rename.
# Earlier settings-file renames continue through the real mv unchanged.
install_seed_mv_collision_gate() {
  local gate="$1" real_mv
  real_mv=$(command -v mv)
  mkdir -p "$gate"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf 'REAL_MV=%q\n' "$real_mv"
    cat <<'GATE'
args=("$@")
argc=${#args[@]}
target_path="${args[$((argc - 1))]}"
if [[ "$target_path" == "$SEED_COLLISION_TARGET" ]]; then
  mkdir -- "$target_path"
  cp -p -- "$SEED_COLLISION_FIXTURE" "$target_path/sentinel"
fi
exec "$REAL_MV" "$@"
GATE
  } > "$gate/mv"
  chmod 700 "$gate/mv"
}

test_seed_leaves_main_and_resolved_skills_source_unchanged() {
  local tmp main shared source_before source_after skills_before skills_after
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  source_before=$(snapshot_tree "$main")
  skills_before=$(snapshot_tree "$tmp/.codex-skills")

  seed_shared "$main" "$shared"

  source_after=$(snapshot_tree "$main")
  skills_after=$(snapshot_tree "$tmp/.codex-skills")
  assert_eq "$source_before" "$source_after" "seeding must not change main bytes or mtimes"
  assert_eq "$skills_before" "$skills_after" "seeding must not change resolved skills bytes or mtimes"
  rm -rf "$tmp"
}

test_seed_refuses_a_second_seed_and_preserves_live_edits() {
  local tmp main shared err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  seed_shared "$main" "$shared"
  printf '%s\n' 'hand-edited' > "$shared/CLAUDE.md"

  set +e
  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)
  rc=$?
  set -e

  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "a second seed must fail"
  assert_contains "$err" "re-seed" "second-seed refusal must explain the policy"
  assert_eq "hand-edited" "$(cat "$shared/CLAUDE.md")" "refusal must preserve live edits"
  rm -rf "$tmp"
}

test_seed_rejects_equal_source_and_destination_before_writes() {
  local tmp main before after err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  before=$(snapshot_tree "$main")

  set +e
  err=$(seed_shared "$main" "$main" 2>&1 >/dev/null)
  rc=$?
  set -e

  after=$(snapshot_tree "$main")
  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "equal source and destination must fail"
  assert_contains "$err" "overlap" "equal paths must report containment"
  assert_eq "$before" "$after" "equal-path refusal must happen before writes"
  rm -rf "$tmp"
}

test_seed_rejects_source_nested_under_destination_before_writes() {
  local tmp container main before after err rc
  new_sandbox; tmp="$SANDBOX_TMP"; container="$tmp/container"
  mkdir -p "$container"
  main=$(make_fixture_main "$container")
  before=$(snapshot_tree "$container")

  set +e
  err=$(seed_shared "$main" "$container" 2>&1 >/dev/null)
  rc=$?
  set -e

  after=$(snapshot_tree "$container")
  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "source below destination must fail"
  assert_contains "$err" "overlap" "source containment must be reported"
  assert_eq "$before" "$after" "source containment refusal must happen before writes"
  rm -rf "$tmp"
}

test_seed_rejects_destination_nested_under_source_before_writes() {
  local tmp main shared before after err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$main/generated/shared"
  before=$(snapshot_tree "$main")

  set +e
  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)
  rc=$?
  set -e

  after=$(snapshot_tree "$main")
  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "destination below source must fail"
  assert_contains "$err" "overlap" "destination containment must be reported"
  assert_eq "$before" "$after" "destination containment refusal must happen before writes"
  rm -rf "$tmp"
}

test_seed_rejects_destination_nested_under_resolved_skills_source() {
  local tmp main skills shared before after err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  skills="$tmp/.codex-skills"; shared="$skills/generated/shared"
  before=$(snapshot_tree "$skills")

  set +e
  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)
  rc=$?
  set -e

  after=$(snapshot_tree "$skills")
  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" \
    "destination below resolved skills source must fail"
  assert_contains "$err" "overlap" "resolved skills containment must be reported"
  assert_eq "$before" "$after" "resolved skills containment refusal must happen before writes"
  rm -rf "$tmp"
}

test_seed_refuses_any_preexisting_live_target() {
  local tmp main shared err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$tmp/publish/shared"
  mkdir -p "$shared"

  set +e
  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)
  rc=$?
  set -e

  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "even an empty live target must be refused"
  assert_contains "$err" "re-seed" "pre-existing target refusal must explain the policy"
  assert_eq "0" "$(find "$shared" -mindepth 1 | wc -l | tr -d ' ')" "empty target must remain untouched"
  rm -rf "$tmp"
}

test_seed_refuses_a_preexisting_live_multi_root() {
  local tmp main root shared err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  root=$(multi_root); shared="$root/shared"
  mkdir -p "$root"
  printf '%s\n' keep > "$root/sentinel"

  set +e
  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)
  rc=$?
  set -e

  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "a pre-existing live root must be refused"
  assert_contains "$err" "re-seed" "live-root refusal must explain the policy"
  assert_eq "absent" "$(kind "$shared")" "live-root refusal must not create shared"
  assert_eq "keep" "$(cat "$root/sentinel")" "live-root refusal must preserve existing content"
  rm -rf "$tmp"
}

test_seed_refuses_a_dangling_live_target_symlink() {
  local tmp main shared before err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$tmp/publish/shared"
  mkdir -p "$(dirname "$shared")"
  ln -s "$tmp/missing-target" "$shared"
  before=$(readlink "$shared")

  set +e
  err=$(seed_shared "$main" "$shared" 2>&1 >/dev/null)
  rc=$?
  set -e

  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "dangling live target must be refused"
  assert_contains "$err" "re-seed" "dangling target refusal must explain the policy"
  assert_eq "$before" "$(readlink "$shared")" "dangling target must remain untouched"
  rm -rf "$tmp"
}

test_seed_keeps_target_invisible_until_complete_atomic_publish() {
  local tmp main root parent shared stub real_awk stage_pattern
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  root=$(multi_root); parent=$(dirname "$root"); shared="$root/shared"; stub="$tmp/stub"
  stage_pattern=".$(basename "$root").seed.*"
  mkdir -p "$stub"
  real_awk=$(command -v awk)
  make_observing_awk_stub "$stub/awk"

  (
    export PATH="$stub:$PATH"
    export SEED_REAL_AWK="$real_awk"
    export SEED_OBSERVED_TARGET="$root"
    seed_shared "$main" "$shared"
  )

  assert_eq "dir" "$(kind "$root")" "complete live root is published at once"
  assert_eq "file" "$(kind "$shared/CLAUDE.md")" "published tree contains CLAUDE.md"
  assert_eq "file" "$(kind "$shared/settings.json")" "published tree contains rewritten settings"
  assert_eq "file" "$(kind "$shared/hooks/post-commit-practices.sh")" "published tree contains hook target"
  assert_eq "0" "$(find "$parent" -maxdepth 1 -name "$stage_pattern" | wc -l | tr -d ' ')" \
    "successful publication leaves no sibling staging directory"
  rm -rf "$tmp"
}

test_seed_publication_collision_preserves_destination_and_fails() {
  local tmp main root parent base shared gate fixture before after err rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  root=$(multi_root); parent=$(dirname -- "$root"); base=${root##*/}
  shared="$root/shared"; gate="$tmp/mv-collision"; fixture="$tmp/competitor-bytes"
  printf 'competing destination\n\000binary tail\n' > "$fixture"
  before=$(md5sum < "$fixture")
  install_seed_mv_collision_gate "$gate"

  set +e
  err=$(
    PATH="$gate:$PATH" \
      SEED_COLLISION_TARGET="$root" \
      SEED_COLLISION_FIXTURE="$fixture" \
      seed_shared "$main" "$shared" 2>&1 >/dev/null
  )
  rc=$?
  set -e

  after=$(md5sum < "$root/sentinel")
  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" \
    "a destination appearing at publication must fail direct seeding"
  assert_eq "$before" "$after" \
    "the competing destination must remain byte-for-byte unchanged"
  assert_eq "sentinel" \
    "$(find "$root" -mindepth 1 -maxdepth 1 -printf '%f\n')" \
    "publication must not nest the staged tree inside the competing destination"
  assert_eq "" \
    "$(find "$parent" -maxdepth 2 -name ".$base.seed.*" -print)" \
    "a publication collision must remove all seed staging residue"
  assert_contains "$err" "publish" "the failed publication must be reported"
  rm -rf "$tmp"
}

test_seed_failure_cleans_only_its_validated_staging_directory() {
  local tmp main root root_base parent shared stub lookalike rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  root=$(multi_root); root_base=$(basename "$root"); parent=$(dirname "$root")
  shared="$root/shared"; stub="$tmp/stub"; lookalike="$parent/.$root_base.seed.keep"
  mkdir -p "$lookalike" "$stub"
  printf '%s\n' keep > "$lookalike/sentinel"
  make_failing_awk_stub "$stub/awk"

  set +e
  PATH="$stub:$PATH" seed_shared "$main" "$shared" >/dev/null 2>&1
  rc=$?
  set -e

  assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "build failure must propagate"
  assert_eq "absent" "$(kind "$root")" "failure must not expose a partial live root"
  assert_eq "file" "$(kind "$lookalike/sentinel")" "lookalike sibling must survive cleanup"
  assert_eq "0" "$(find "$parent" -maxdepth 1 -name ".$root_base.seed.*" ! -name ".$root_base.seed.keep" | wc -l | tr -d ' ')" \
    "failure must remove its own staging directory"
  rm -rf "$tmp"
}

test_seed_signals_clean_staging_without_exposing_the_target() {
  local tmp main parent stub signal shared rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  parent="$tmp/publish"; stub="$tmp/stub"
  mkdir -p "$parent" "$stub"
  make_signalling_awk_stub "$stub/awk"

  for signal in INT TERM; do
    shared="$parent/shared-$signal"
    set +e
    (
      export PATH="$stub:$PATH"
      export SEED_SIGNAL="$signal"
      seed_shared "$main" "$shared"
    ) >/dev/null 2>&1
    rc=$?
    set -e

    assert_eq "no" "$([[ $rc -eq 0 ]] && printf yes || printf no)" "$signal must interrupt seeding"
    assert_eq "absent" "$(kind "$shared")" "$signal must not expose a partial target"
    assert_eq "0" "$(find "$parent" -maxdepth 1 -name ".shared-$signal.seed.*" | wc -l | tr -d ' ')" \
      "$signal must clean its staging directory"
  done
  rm -rf "$tmp"
}

test_seed_shared_composes_inside_an_existing_multi_root_stage() {
  local tmp main root_stage shared
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  root_stage="$tmp/.claude-multi.stage.example"; shared="$root_stage/shared"
  mkdir -p "$root_stage/project-memory"
  printf '%s\n' keep > "$root_stage/project-memory/sentinel"

  seed_shared "$main" "$shared"

  assert_eq "file" "$(kind "$shared/CLAUDE.md")" "shared subtree publishes inside caller stage"
  assert_eq "keep" "$(cat "$root_stage/project-memory/sentinel")" \
    "publishing shared must preserve caller-owned staged siblings"
  rm -rf "$tmp"
}

test_entry_point_sources_the_complete_seed_interface_without_output() {
  local tmp out_file err_file rc
  new_sandbox; tmp="$SANDBOX_TMP"
  out_file="$tmp/source.stdout"; err_file="$tmp/source.stderr"

  set +e
  bash -c '
    set -euo pipefail
    source "$1/bin/claude-multi"
    for fn in validate_main_folder seed_shared seed_skills_link rewrite_hook_paths; do
      declare -F "$fn" >/dev/null || exit 23
    done
  ' _ "$repo" >"$out_file" 2>"$err_file"
  rc=$?
  set -e

  assert_eq "0" "$rc" "entry point must expose the complete seed interface"
  assert_eq "0" "$(wc -c < "$out_file" | tr -d ' ')" "sourcing entry point must keep stdout byte-empty"
  assert_eq "0" "$(wc -c < "$err_file" | tr -d ' ')" "sourcing entry point must keep stderr byte-empty"
  rm -rf "$tmp"
}

test_entry_point_seed_interface_runs_a_complete_seed() {
  local tmp main shared out_file err_file rc
  new_sandbox; tmp="$SANDBOX_TMP"; main=$(make_fixture_main "$tmp")
  shared="$(multi_root)/shared"
  out_file="$tmp/seed.stdout"; err_file="$tmp/seed.stderr"

  set +e
  bash -c '
    set -euo pipefail
    source "$1/bin/claude-multi"
    seed_shared "$2" "$3"
  ' _ "$repo" "$main" "$shared" >"$out_file" 2>"$err_file"
  rc=$?
  set -e

  assert_eq "0" "$rc" "seed interface sourced by entry point must be callable"
  assert_eq "file" "$(kind "$shared/CLAUDE.md")" "entry-point seed publishes complete shared content"
  assert_eq "link" "$(kind "$shared/skills")" "entry-point seed has the link_create dependency"
  assert_eq "0" "$(wc -c < "$out_file" | tr -d ' ')" "entry-point seed keeps stdout byte-empty"
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
