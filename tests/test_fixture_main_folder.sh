#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$here/assert.sh"
. "$here/fixtures/main-folder.sh"

test_fixture_reproduces_the_four_quirks() {
  local tmp main
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmfix.XXXXXX")
  main=$(make_fixture_main "$tmp")

  # Quirk 1: skills is a RELATIVE symlink to ../.codex-skills
  assert_eq "link" "$(kind "$main/skills")" "skills must be a symlink"
  assert_link "$main/skills" "../.codex-skills" "skills target must stay relative"
  assert_eq "dir" "$(kind "$tmp/.codex-skills")" "codex-skills lives OUTSIDE the main folder"

  # Quirk 2: commands/ does not exist
  assert_eq "absent" "$(kind "$main/commands")" "fixture must NOT have commands/"

  # Quirk 3: settings.json hook command is an absolute path into the main folder
  assert_contains "$(cat "$main/settings.json")" \
    "\"command\": \"$main/hooks/post-commit-practices.sh\"" \
    "hook command must be absolute into the fixture main folder"

  # Quirk 4: agent-memory/ has subdirectories
  assert_eq "dir" "$(kind "$main/agent-memory/software-engineer")" "agent-memory subdir"
  assert_eq "dir" "$(kind "$main/agent-memory/brainstorm-architect")" "agent-memory subdir"

  rm -rf "$tmp"
}

test_snapshot_tree_is_stable_and_notices_a_change() {
  local tmp main a b c
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmfix.XXXXXX")
  main=$(make_fixture_main "$tmp")

  a=$(snapshot_tree "$main")
  b=$(snapshot_tree "$main")
  assert_eq "$a" "$b" "snapshot must be deterministic"

  printf 'tampered\n' >> "$main/CLAUDE.md"
  c=$(snapshot_tree "$main")
  if [[ "$a" == "$c" ]]; then
    printf 'FAIL: snapshot_tree did not notice a modified file\n' >&2
    return 1
  fi
  rm -rf "$tmp"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  status=0
  runner_tmp=$(mktemp -d "${TMPDIR:-/tmp}/cmfix-run.XXXXXX")
  cleanup_runner_tmp() {
    case "$runner_tmp" in
      */cmfix-run.*) rm -rf -- "$runner_tmp" ;;
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
