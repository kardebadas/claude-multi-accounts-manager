#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

. "$REPO/tests/assert.sh"
. "$REPO/lib/util.sh"
. "$REPO/lib/config.sh"
. "$REPO/lib/memory.sh"

yesno() {
  if "$@" >/dev/null 2>&1; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

slug_oracle() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9' '-'
}

t_slug_of_path_encodes_every_non_alphanumeric_byte() {
  local t base p s
  t="$(mktemp -d "${TMPDIR:-/tmp}/cm-slug.XXXXXXXX")"
  base="$(slug_oracle "$t")"
  assert_eq "-" "${base:0:1}" "an absolute path's slug starts with '-'"
  assert_eq "${base}-alpha-service" "$(slug_of_path "$t/alpha-service")" \
    "a path separator and a literal hyphen both become '-'"
  assert_eq "${base}-beta--claude-worktrees-agent-one" \
    "$(slug_of_path "$t/beta/.claude/worktrees/agent-one")" \
    "'/.' becomes '--'"
  assert_eq "${base}-epsilon-notes" "$(slug_of_path "$t/epsilon_notes")" \
    "an underscore becomes '-'"
  assert_eq "${base}-two-words" "$(slug_of_path "$t/two words")" \
    "a space becomes '-'"
  assert_eq "${base}-theta-tools" "$(slug_of_path "$t/theta.tools")" \
    "a dot inside a component becomes '-'"
  p="$t/delta-one-two-three"
  s="$(slug_of_path "$p")"
  assert_eq "${#p}" "${#s}" "encoding is per-character: len(slug) == len(path)"
  rm -rf -- "$t"
}

t_is_worktree_slug_matches_worktree_shapes() {
  local t
  t="$(mktemp -d "${TMPDIR:-/tmp}/cm-wt.XXXXXXXX")"
  assert_eq "yes" "$(yesno is_worktree_slug "$(slug_of_path "$t/beta/.claude/worktrees/agent-one")")" \
    "a '/.claude/worktrees/' slug is a worktree"
  assert_eq "yes" "$(yesno is_worktree_slug "$(slug_of_path "$t/zeta/.claude/worktrees/wt-p2-phase")")" \
    "a named worktree under .claude/worktrees is a worktree"
  assert_eq "yes" "$(yesno is_worktree_slug "$(slug_of_path "$t/wt/refactor-api")")" \
    "a 'wt/' slug is a worktree"
  rm -rf -- "$t"
}

t_is_worktree_slug_rejects_real_project_shapes() {
  local t rel
  t="$(mktemp -d "${TMPDIR:-/tmp}/cm-real.XXXXXXXX")"
  for rel in alpha-service beta-app gamma delta-one-two-three sigma-sigma-notes \
             epsilon_notes "two words" theta.tools zeta zeta/scripts/env-provisioning; do
    assert_eq "no" "$(yesno is_worktree_slug "$(slug_of_path "$t/projects/$rel")")" \
      "a real project slug must not be flagged as a worktree: $rel"
  done
  rm -rf -- "$t"
}

t_is_worktree_slug_writes_nothing_at_all() {
  local t slug
  t="$(mktemp -d "${TMPDIR:-/tmp}/cm-wt.XXXXXXXX")"
  slug="$(slug_of_path "$t/beta/.claude/worktrees/agent-one")"
  assert_stdout_empty_bytes is_worktree_slug "$slug"
  assert_eq "" "$(is_worktree_slug "$slug" 2>&1 >/dev/null || true)" \
    "a predicate must not narrate on stderr either"
  rm -rf -- "$t"
}

# Dispatch MUST remain the last block: later tasks append tests above it.
run_all_memory_tests() {
  local fn status=0 ran=0
  while IFS= read -r fn; do
    ran=$((ran + 1))
    set +e
    ( set -e; "$fn" )
    local test_status=$?
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

if run_all_memory_tests; then
  exit 0
else
  exit 1
fi
