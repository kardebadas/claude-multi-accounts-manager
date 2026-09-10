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

FIX_REAL_RELPATHS=(
  "projects/alpha-service" "projects/beta-app" "projects/gamma"
  "projects/delta-one-two-three" "projects/sigma-sigma-notes"
  "projects/epsilon_notes" "projects/two words" "projects/theta.tools"
  "projects/zeta" "projects/zeta/scripts/env-provisioning" "scratch/notes"
)
FIX_WORKTREE_RELPATHS=(
  "projects/alpha-service/.claude/worktrees/agent-one"
  "projects/alpha-service/.claude/worktrees/agent-two"
  "projects/beta-app/.claude/worktrees/agent-three"
  "projects/beta-app/.claude/worktrees/agent-four"
  "projects/beta-app/.claude/worktrees/agent-five"
  "projects/gamma/.claude/worktrees/agent-six"
  "projects/gamma/.claude/worktrees/agent-seven"
  "projects/zeta/.claude/worktrees/agent-eight"
  "projects/zeta/.claude/worktrees/agent-nine"
  "projects/zeta/.claude/worktrees/agent-ten"
  "projects/sigma-sigma-notes/.claude/worktrees/agent-eleven"
  "projects/sigma-sigma-notes/.claude/worktrees/agent-twelve"
  "projects/delta-one-two-three/.claude/worktrees/agent-thirteen"
  "projects/delta-one-two-three/.claude/worktrees/task-migration"
  "projects/theta.tools/.claude/worktrees/wt-p2-phase"
  "wt/refactor-api" "projects/zeta/wt/spike-cache"
)
FIX_ADVERSARIAL_RELPATHS=(
  "amb/a-b" "amb/a/b" "und/my-app" "und/my_app" "dot/.hidden-notes"
  "projects/wt-dashboard"
)

fix_slug() { slug_of_path "$FIX_FS/$1"; }

fix_base_charset() {
  if [[ ${FIX_BASE:-} =~ ^[/A-Za-z0-9._\ -]+$ ]]; then
    printf 'reconstructable\n'
  else
    printf 'unreconstructable\n'
  fi
}

cleanup_memory_fixture() {
  if [[ -n ${FIX_BASE:-} && -d ${FIX_BASE:-/nonexistent} ]]; then
    rm -rf -- "$FIX_BASE"
  fi
}

make_memory_fixture() {
  FIX_BASE="$(mktemp -d "${TMPDIR:-/tmp}/cm-mem.XXXXXXXX")"
  trap cleanup_memory_fixture EXIT
  assert_eq "reconstructable" "$(fix_base_charset)" \
    "fixture base must contain only reconstructable characters"
  FIX_FS="$FIX_BASE/fs" FIX_MAIN="$FIX_BASE/main" FIX_ROOT="$FIX_BASE/root"
  export CLAUDE_MULTI_ROOT="$FIX_ROOT"
  local rel slug
  FIX_REAL_SLUGS=()
  for rel in "${FIX_REAL_RELPATHS[@]}"; do
    mkdir -p "$FIX_FS/$rel"
    FIX_REAL_SLUGS+=("$(fix_slug "$rel")")
  done
  FIX_WORKTREE_SLUGS=()
  for rel in "${FIX_WORKTREE_RELPATHS[@]}"; do
    mkdir -p "$FIX_FS/$rel"
    FIX_WORKTREE_SLUGS+=("$(fix_slug "$rel")")
  done
  for rel in "${FIX_ADVERSARIAL_RELPATHS[@]}"; do mkdir -p "$FIX_FS/$rel"; done
  mkdir -p "$FIX_MAIN/projects"
  for slug in "${FIX_REAL_SLUGS[@]}" "${FIX_WORKTREE_SLUGS[@]}"; do
    mkdir -p "$FIX_MAIN/projects/$slug/memory"
    printf 'memory for %s\n' "$slug" > "$FIX_MAIN/projects/$slug/memory/MEMORY.md"
  done
  mkdir -p "$FIX_MAIN/projects/$(fix_slug projects/gamma)-nomem"
  mkdir -p "$FIX_MAIN/projects/$(fix_slug gone/project)/memory"
  printf 'stale\n' > "$FIX_MAIN/projects/$(fix_slug gone/project)/memory/MEMORY.md"
  mkdir -p "$FIX_ROOT/shared"
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

t_fixture_has_the_required_mix() {
  make_memory_fixture
  assert_eq "11" "${#FIX_REAL_SLUGS[@]}" "11 real project slugs"
  assert_eq "17" "${#FIX_WORKTREE_SLUGS[@]}" "17 worktree slugs"
  local slug
  for slug in "${FIX_WORKTREE_SLUGS[@]}"; do
    assert_eq "yes" "$(yesno is_worktree_slug "$slug")" "worktree detected: $slug"
  done
  for slug in "${FIX_REAL_SLUGS[@]}"; do
    assert_eq "no" "$(yesno is_worktree_slug "$slug")" "real slug accepted: $slug"
  done
  cleanup_memory_fixture
}

t_fixture_paths_exist_on_disk_and_are_all_relative() {
  make_memory_fixture
  local rel
  for rel in "${FIX_REAL_RELPATHS[@]}" "${FIX_WORKTREE_RELPATHS[@]}" \
             "${FIX_ADVERSARIAL_RELPATHS[@]}"; do
    assert_eq "yes" "$(yesno test -d "$FIX_FS/$rel")" "fixture path exists: $rel"
    assert_eq "no" "$(yesno test "${rel:0:1}" = "/")" "fixture path is relative: $rel"
  done
  assert_eq "yes" "$(yesno test -f "$FIX_MAIN/projects/${FIX_REAL_SLUGS[0]}/memory/MEMORY.md")" \
    "fixture main folder carries memory"
  cleanup_memory_fixture
}

t_decode_slug_plain_nesting() {
  make_memory_fixture
  assert_eq "$FIX_FS/projects/gamma" \
    "$(decode_slug "$(fix_slug projects/gamma)")" \
    "decodes a two-level path with no literal hyphens in the leaf"
  cleanup_memory_fixture
}

t_decode_slug_literal_hyphens_in_leaf() {
  make_memory_fixture
  assert_eq "$FIX_FS/projects/alpha-service" \
    "$(decode_slug "$(fix_slug projects/alpha-service)")" \
    "one literal hyphen in a component"
  assert_eq "$FIX_FS/projects/delta-one-two-three" \
    "$(decode_slug "$(fix_slug projects/delta-one-two-three)")" \
    "three literal hyphens in one component"
  assert_eq "$FIX_FS/projects/sigma-sigma-notes" \
    "$(decode_slug "$(fix_slug projects/sigma-sigma-notes)")" \
    "repeated token with literal hyphens"
  cleanup_memory_fixture
}

t_decode_slug_mixes_separators_and_hyphens() {
  make_memory_fixture
  assert_eq "$FIX_FS/projects/zeta/scripts/env-provisioning" \
    "$(decode_slug "$(fix_slug projects/zeta/scripts/env-provisioning)")" \
    "prefix-extension of another valid slug"
  assert_eq "$FIX_FS/projects/zeta" \
    "$(decode_slug "$(fix_slug projects/zeta)")" \
    "the shorter sibling slug still decodes"
  cleanup_memory_fixture
}

t_decode_slug_dot_space_and_underscore_literals() {
  make_memory_fixture
  assert_eq "$FIX_FS/projects/zeta/.claude/worktrees/agent-eight" \
    "$(decode_slug "$(fix_slug projects/zeta/.claude/worktrees/agent-eight)")" \
    "leading-dot component decodes from a doubled hyphen"
  assert_eq "$FIX_FS/dot/.hidden-notes" \
    "$(decode_slug "$(fix_slug dot/.hidden-notes)")" \
    "dot plus literal hyphen in one component"
  assert_eq "$FIX_FS/projects/two words" \
    "$(decode_slug "$(fix_slug "projects/two words")")" \
    "a space inside a component decodes"
  assert_eq "$FIX_FS/projects/theta.tools" \
    "$(decode_slug "$(fix_slug projects/theta.tools)")" \
    "a dot inside a component decodes"
  cleanup_memory_fixture
}

t_decode_slug_every_real_fixture_slug_round_trips() {
  make_memory_fixture
  local rel decoded
  for rel in "${FIX_REAL_RELPATHS[@]}"; do
    assert_eq "yes" "$(yesno decode_slug "$(fix_slug "$rel")")" \
      "decode_slug must succeed for real slug: $rel"
    decoded="$(decode_slug "$(fix_slug "$rel")")"
    assert_eq "$FIX_FS/$rel" "$decoded" "round trip for $rel"
  done
  cleanup_memory_fixture
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

# Keep this outside a conditional so errexit remains active inside each test.
run_all_memory_tests
