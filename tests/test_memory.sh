#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

. "$REPO/tests/assert.sh"
. "$REPO/lib/util.sh"
. "$REPO/lib/config.sh"
. "$REPO/lib/links.sh"
. "$REPO/lib/memory.sh"

yesno() {
  if "$@" >/dev/null 2>&1; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
}

tree_snapshot() {
  local root="$1"
  (
    cd -- "$root"
    {
      find . -printf '%p %y %s %l\n'
      find . -type f -exec cksum {} +
    } | LC_ALL=C sort | cksum
  )
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
  mkdir -p "$t/beta/.claude/worktrees/agent-one" \
    "$t/zeta/.claude/worktrees/wt-p2-phase" "$t/wt/refactor-api"
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
             epsilon_notes "two words" theta.tools zeta zeta/scripts/env-provisioning \
             wt-dashboard .claude-worktrees/tool .claude/worktrees-dashboard/tool; do
    mkdir -p "$t/projects/$rel"
    assert_eq "no" "$(yesno is_worktree_slug "$(slug_of_path "$t/projects/$rel")")" \
      "only exact decoded worktree path components are rejected: $rel"
  done
  rm -rf -- "$t"
}

t_is_worktree_slug_writes_nothing_at_all() {
  local t slug
  t="$(mktemp -d "${TMPDIR:-/tmp}/cm-wt.XXXXXXXX")"
  mkdir -p "$t/beta/.claude/worktrees/agent-one"
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

t_decode_slug_returns_2_when_path_is_gone() {
  make_memory_fixture
  local slug out rc errfile
  slug="$(fix_slug gone/project)"
  errfile="$FIX_BASE/decode.err"
  set +e
  out="$(decode_slug "$slug" 2>"$errfile")"
  rc=$?
  set -e
  assert_eq "2" "$rc" "a slug with no matching directory must exit 2"
  assert_eq "" "$out" "exit 2 must print nothing on stdout"
  assert_eq "" "$(cat "$errfile")" "a deleted project is silently skipped"
  assert_stdout_empty_bytes decode_slug "$slug"
  cleanup_memory_fixture
}

t_decode_slug_returns_2_for_a_relative_slug() {
  make_memory_fixture
  local out rc
  set +e
  out="$(decode_slug "not-a-slug" 2>/dev/null)"
  rc=$?
  set -e
  assert_eq "2" "$rc" "a slug not starting with '-' is not a project slug"
  assert_eq "" "$out" "exit 2 must print nothing on stdout"
  assert_stdout_empty_bytes decode_slug "not-a-slug"
  cleanup_memory_fixture
}

t_decode_slug_returns_3_on_hyphen_ambiguity() {
  make_memory_fixture
  local slug out rc err errfile
  errfile="$FIX_BASE/decode.err"
  slug="$(fix_slug amb/a-b)"
  set +e
  out="$(decode_slug "$slug" 2>"$errfile")"
  rc=$?
  set -e
  err="$(cat "$errfile")"
  assert_eq "3" "$rc" "two valid reconstructions must exit 3, not guess"
  assert_eq "" "$out" "exit 3 must print nothing on stdout"
  assert_contains "$err" "ambiguous" "exit 3 must warn on stderr"
  assert_contains "$err" "$FIX_FS/amb/a-b" "the warning must list the candidates"
  assert_contains "$err" "$FIX_FS/amb/a/b" "the warning must list the candidates"
  assert_stdout_empty_bytes decode_slug "$slug"
  cleanup_memory_fixture
}

t_decode_slug_returns_3_on_underscore_ambiguity() {
  make_memory_fixture
  local rc
  set +e
  decode_slug "$(fix_slug und/my_app)" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "3" "$rc" "underscore versus literal hyphen is ambiguous"
  set +e
  decode_slug "$(fix_slug und/my-app)" >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "3" "$rc" "both spellings encode to the same slug"
  assert_stdout_empty_bytes decode_slug "$(fix_slug und/my_app)"
  cleanup_memory_fixture
}

t_decode_slug_returns_4_when_capped() {
  make_memory_fixture
  local rc err slug
  slug="$(fix_slug projects/alpha-service)"
  set +e
  err="$(MEMORY_DECODE_MAX_NODES=3 decode_slug "$slug" 2>&1 >/dev/null)"
  rc=$?
  set -e
  assert_eq "4" "$rc" "exceeding the node cap must exit 4"
  assert_contains "$err" "search cap" "exit 4 must say why"
  MEMORY_DECODE_MAX_NODES=3 assert_stdout_empty_bytes decode_slug "$slug"
  assert_eq "$FIX_FS/projects/alpha-service" "$(decode_slug "$slug")" \
    "a per-call cap must not affect a later default-cap call"
  cleanup_memory_fixture
}

t_project_slugs_lists_main_folder_slugs() {
  make_memory_fixture
  local n listing expected
  printf 'not a directory\n' > "$FIX_MAIN/projects/ordinary-file"
  n="$(project_slugs "$FIX_MAIN" | wc -l | tr -d ' ')"
  assert_eq "30" "$n" "list all project directories, excluding files"
  listing="$(project_slugs "$FIX_MAIN")"
  # The directory-only glob sorts paths with their trailing slash intact.
  expected="$(printf '%s/\n' "${FIX_REAL_SLUGS[@]}" "${FIX_WORKTREE_SLUGS[@]}" \
    "$(fix_slug projects/gamma)-nomem" "$(fix_slug gone/project)" | sort | sed 's:/$::')"
  assert_eq "$expected" "$listing" "list every slug in shell glob order"
  cleanup_memory_fixture
}

t_project_slugs_is_quiet_when_projects_dir_absent() {
  make_memory_fixture
  local out
  out="$(project_slugs "$FIX_BASE/no-such-main")"
  assert_eq "" "$out" "a missing projects directory yields no output"
  assert_eq "yes" "$(yesno project_slugs "$FIX_BASE/no-such-main")" \
    "a missing projects directory must exit 0"
  assert_stdout_empty_bytes project_slugs "$FIX_BASE/no-such-main"
  mkdir -p "$FIX_BASE/empty-main/projects"
  assert_eq "" "$(project_slugs "$FIX_BASE/empty-main")" \
    "an empty projects directory must not print an unmatched glob"
  cleanup_memory_fixture
}

t_slug_is_eligible_accepts_all_real_slugs() {
  make_memory_fixture
  local slug
  for slug in "${FIX_REAL_SLUGS[@]}"; do
    assert_eq "yes" "$(yesno slug_is_eligible "$slug")" \
      "real slug must be eligible: $slug"
  done
  assert_stdout_empty_bytes slug_is_eligible "${FIX_REAL_SLUGS[0]}"
  cleanup_memory_fixture
}

t_slug_is_eligible_rejects_every_worktree_slug() {
  make_memory_fixture
  local slug rc
  for slug in "${FIX_WORKTREE_SLUGS[@]}"; do
    rc=0
    slug_is_eligible "$slug" >"$FIX_BASE/eligible.out" 2>"$FIX_BASE/eligible.err" || rc=$?
    assert_eq "1" "$rc" "worktree slug must be rejected: $slug"
    assert_eq "" "$(cat "$FIX_BASE/eligible.out")" "worktree predicate has no stdout"
  done
  rc=0
  MEMORY_DECODE_MAX_NODES=1 slug_is_eligible "${FIX_WORKTREE_SLUGS[0]}" \
    >"$FIX_BASE/eligible.out" 2>"$FIX_BASE/eligible.err" || rc=$?
  assert_eq "1" "$rc" "a capped decode is ineligible before path classification"
  assert_contains "$(cat "$FIX_BASE/eligible.err")" "search cap" \
    "worktree classification requires the decoded path"
  assert_stdout_empty_bytes slug_is_eligible "${FIX_WORKTREE_SLUGS[0]}"
  cleanup_memory_fixture
}

t_slug_is_eligible_rejects_gone_and_ambiguous() {
  make_memory_fixture
  local rel rc slug
  for rel in gone/project amb/a-b; do
    slug="$(fix_slug "$rel")"
    rc=0
    slug_is_eligible "$slug" >/dev/null 2>"$FIX_BASE/eligible.err" || rc=$?
    assert_eq "1" "$rc" "gone or ambiguous project must be rejected: $rel"
    assert_stdout_empty_bytes slug_is_eligible "$slug"
  done
  assert_contains "$(cat "$FIX_BASE/eligible.err")" "ambiguous" \
    "eligibility preserves decoder diagnostics on stderr"
  rc=0
  MEMORY_DECODE_MAX_NODES=1 slug_is_eligible "${FIX_REAL_SLUGS[0]}" \
    >/dev/null 2>"$FIX_BASE/eligible.err" || rc=$?
  assert_eq "1" "$rc" "a capped decode is ineligible"
  MEMORY_DECODE_MAX_NODES=1 assert_stdout_empty_bytes slug_is_eligible "${FIX_REAL_SLUGS[0]}"
  cleanup_memory_fixture
}

t_slug_is_eligible_accepts_wt_dashboard_component() {
  make_memory_fixture
  local rc=0
  slug_is_eligible "$(fix_slug projects/wt-dashboard)" >/dev/null 2>&1 || rc=$?
  assert_eq "0" "$rc" "wt-dashboard is not a component exactly named wt"
  assert_stdout_empty_bytes slug_is_eligible "$(fix_slug projects/wt-dashboard)"
  cleanup_memory_fixture
}

t_project_memory_store_follows_the_staging_root_override() {
  make_memory_fixture
  local live_store="$FIX_ROOT/shared/project-memory"
  local stage="$FIX_BASE/.claude-multi.stage.example"
  mkdir -p "$stage"
  printf 'keep\n' > "$stage/sentinel"
  export CLAUDE_MULTI_ROOT="$stage"

  assert_eq "$stage/shared/project-memory" "$(project_memory_store)" \
    "the store composes through the caller's root override"
  seed_project_memory "$FIX_MAIN" 2>/dev/null

  assert_eq "yes" "$(yesno test -f "$stage/shared/project-memory/${FIX_REAL_SLUGS[0]}/MEMORY.md")" \
    "project memory is assembled inside the caller-owned root stage"
  assert_eq "no" "$(yesno test -e "$live_store")" \
    "project-memory seeding must not independently publish live state"
  assert_eq "keep" "$(cat "$stage/sentinel")" \
    "seeding preserves caller-owned staged siblings"
  cleanup_memory_fixture
}

t_seed_project_memory_copies_eligible_slugs_only() {
  make_memory_fixture
  seed_project_memory "$FIX_MAIN" 2>/dev/null

  local dest="$FIX_ROOT/shared/project-memory" slug
  for slug in "${FIX_REAL_SLUGS[@]}"; do
    assert_eq "yes" "$(yesno test -f "$dest/$slug/MEMORY.md")" \
      "eligible slug must be seeded: $slug"
    assert_eq "memory for $slug" "$(cat "$dest/$slug/MEMORY.md")" \
      "seeded content must match the source"
  done
  for slug in "${FIX_WORKTREE_SLUGS[@]}"; do
    assert_eq "no" "$(yesno test -e "$dest/$slug")" \
      "worktree slug must not be seeded despite carrying source memory: $slug"
  done
  assert_eq "no" "$(yesno test -e "$dest/$(fix_slug gone/project)")" \
    "a slug whose decoded path is gone must not be seeded"
  cleanup_memory_fixture
}

t_seed_project_memory_seeds_exactly_the_real_count() {
  make_memory_fixture
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  local n
  n="$(find "$FIX_ROOT/shared/project-memory" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
  assert_eq "11" "$n" "exactly the 11 eligible slugs are seeded"
  cleanup_memory_fixture
}

t_seed_project_memory_leaves_the_main_folder_untouched() {
  make_memory_fixture
  local before after
  before="$(cd "$FIX_MAIN" && find . -printf '%p %s %T@\n' | sort | cksum)"
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  after="$(cd "$FIX_MAIN" && find . -printf '%p %s %T@\n' | sort | cksum)"
  assert_eq "$before" "$after" "the main folder remains read-only"
  cleanup_memory_fixture
}

t_seed_project_memory_is_silent_and_inert_on_rerun() {
  make_memory_fixture
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  local snap1 snap2 err
  snap1="$(cd "$FIX_ROOT/shared/project-memory" && find . -printf '%p %y %s %T@\n' | sort | cksum)"
  err="$(seed_project_memory "$FIX_MAIN" 2>&1 >/dev/null)"
  snap2="$(cd "$FIX_ROOT/shared/project-memory" && find . -printf '%p %y %s %T@\n' | sort | cksum)"
  assert_eq "$snap1" "$snap2" "a repeated seed changes nothing"
  assert_eq "" "$err" "a repeated seed reports nothing"
  cleanup_memory_fixture
}

t_seed_project_memory_writes_nothing_to_stdout() {
  make_memory_fixture
  local out="$FIX_BASE/seed.out" rc=0
  seed_project_memory "$FIX_MAIN" >"$out" 2>/dev/null || rc=$?
  assert_eq "0" "$rc" "seeding succeeds while stdout is captured"
  assert_eq "0" "$(wc -c < "$out" | tr -d ' ')" \
    "seeding writes zero bytes to stdout"
  cleanup_memory_fixture
}

t_seed_project_memory_survives_a_main_folder_with_no_projects() {
  make_memory_fixture
  mkdir -p "$FIX_BASE/bare-main"
  assert_eq "yes" "$(yesno seed_project_memory "$FIX_BASE/bare-main")" \
    "an absent projects directory exits successfully"
  cleanup_memory_fixture
}

t_memory_link_path_follows_the_active_root() {
  make_memory_fixture
  local slug="${FIX_REAL_SLUGS[0]}" err="$FIX_BASE/link-path.err" path

  path="$(memory_link_path work "$slug" 2>"$err")"
  assert_eq "$FIX_ROOT/work/projects/$slug/memory" "$path" \
    "the account memory link uses the planned account project layout"
  assert_eq "" "$(cat "$err")" "memory_link_path emits no diagnostics"

  local stage="$FIX_BASE/.claude-multi.stage.example"
  export CLAUDE_MULTI_ROOT="$stage"
  assert_eq "$stage/work/projects/$slug/memory" \
    "$(memory_link_path work "$slug")" \
    "the link path composes through a caller-owned staging root"
  cleanup_memory_fixture
}

t_memory_link_target_resolves_to_the_project_store() {
  make_memory_fixture
  local slug="${FIX_REAL_SLUGS[0]}" link target store
  link="$(memory_link_path work "$slug")"
  target="$(memory_link_target "$slug")"
  store="$(project_memory_store)/$slug"
  mkdir -p "$(dirname "$link")" "$store"
  printf 'linked memory\n' > "$store/MEMORY.md"
  ln -s "$target" "$link"

  assert_link "$link" "$target"
  assert_eq "yes" "$(yesno test -d "$link")" \
    "the relative link resolves to an existing project-memory directory"
  assert_eq "linked memory" "$(cat "$link/MEMORY.md")" \
    "the resolved link exposes the stored project memory"
  assert_eq "$(readlink -f "$store")" "$(readlink -f "$link")" \
    "the planned link depth resolves to the project-memory store"
  assert_eq "no" "$(yesno test "${target:0:1}" = /)" \
    "the stored symlink target is relative"
  cleanup_memory_fixture
}

t_memory_link_target_depth_is_three() {
  make_memory_fixture
  local slug="${FIX_REAL_SLUGS[0]}" err="$FIX_BASE/link-target.err" target
  target="$(memory_link_target "$slug" 2>"$err")"
  assert_eq "../../../shared/project-memory/$slug" "$target" \
    "the account project memory link climbs exactly three levels"
  assert_eq "" "$(cat "$err")" "memory_link_target emits no diagnostics"
  cleanup_memory_fixture
}

t_memory_link_depth_matches_the_planned_layout() {
  make_memory_fixture
  local slug="${FIX_REAL_SLUGS[0]}" link cursor derived="" depth=0
  link="$(memory_link_path work "$slug")"
  cursor="${link%/*}"
  while [[ "$cursor" != "$FIX_ROOT" && "$cursor" != / && $depth -lt 10 ]]; do
    cursor="${cursor%/*}"
    derived+="../"
    depth=$((depth + 1))
  done

  assert_eq "$FIX_ROOT" "$cursor" \
    "the link directory descends from the active managed root"
  assert_eq "3" "$depth" \
    "the link directory is independently three levels below the root"
  assert_eq "${derived}shared/project-memory/$slug" \
    "$(memory_link_target "$slug")" \
    "the relative target depth follows the link and store layouts"
  cleanup_memory_fixture
}

# Helper: a seeded store plus an empty account directory.
fix_seed_and_account() {
  local account="$1"
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  mkdir -p "$FIX_ROOT/$account"
}

t_store_slugs_lists_seeded_slugs() {
  make_memory_fixture
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  local actual expected
  actual="$(store_slugs | sort)"
  expected="$(printf '%s\n' "${FIX_REAL_SLUGS[@]}" | sort)"
  assert_eq "$expected" "$actual" \
    "store_slugs lists exactly the seeded slugs, one per line"
  assert_eq "11" "$(store_slugs | wc -l | tr -d ' ')" \
    "store_slugs lists one line per seeded slug"
  cleanup_memory_fixture
}

t_sync_creates_a_working_link_per_seeded_slug() {
  make_memory_fixture
  fix_seed_and_account personal
  sync_project_memory personal 2>/dev/null

  local slug link
  for slug in "${FIX_REAL_SLUGS[@]}"; do
    link="$(memory_link_path personal "$slug")"
    assert_link "$link" "$(memory_link_target "$slug")"
    assert_eq "yes" "$(yesno test -d "$link")" \
      "link for $slug must resolve to a directory"
    assert_eq "memory for $slug" "$(cat "$link/MEMORY.md")" \
      "content is readable through the link for $slug"
  done
  cleanup_memory_fixture
}

t_sync_creates_no_link_for_worktree_slugs() {
  make_memory_fixture
  fix_seed_and_account personal
  sync_project_memory personal 2>/dev/null
  local slug
  for slug in "${FIX_WORKTREE_SLUGS[@]}"; do
    assert_eq "no" "$(yesno test -e "$FIX_ROOT/personal/projects/$slug")" \
      "worktree slug must get no project dir in the account: $slug"
  done
  cleanup_memory_fixture
}

t_sync_is_independent_per_account() {
  make_memory_fixture
  fix_seed_and_account personal
  mkdir -p "$FIX_ROOT/work"
  sync_project_memory personal 2>/dev/null
  sync_project_memory work 2>/dev/null
  local slug
  slug="${FIX_REAL_SLUGS[0]}"
  assert_link "$(memory_link_path personal "$slug")" "$(memory_link_target "$slug")"
  assert_link "$(memory_link_path work "$slug")" "$(memory_link_target "$slug")"
  cleanup_memory_fixture
}

t_sync_writes_nothing_to_stdout() {
  make_memory_fixture
  fix_seed_and_account personal
  assert_stdout_empty_bytes sync_project_memory personal
  cleanup_memory_fixture
}

t_sync_refuses_an_unknown_account_without_exiting() {
  make_memory_fixture
  fix_seed_and_account personal
  local err
  assert_fails sync_project_memory no-such-account
  err="$(sync_project_memory no-such-account 2>&1 >/dev/null || true)"
  assert_contains "$err" "no such account" \
    "the refusal must be narrated on stderr"
  assert_eq "yes" "$(yesno test -d "$FIX_ROOT/personal")" \
    "the refusal must not have torn anything down"
  cleanup_memory_fixture
}

t_sync_direct_call_refuses_a_symlinked_account_without_external_mutation() {
  make_memory_fixture
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  local external="$FIX_BASE/external-account"
  mkdir -p "$external"
  printf 'external sentinel bytes\n' > "$external/sentinel.txt"
  ln -s "$external" "$FIX_ROOT/escape"
  local root_before external_before rc=0 out="$FIX_BASE/symlink-sync.out" err
  root_before="$(tree_snapshot "$FIX_ROOT")"
  external_before="$(tree_snapshot "$external")"

  sync_project_memory escape >"$out" 2>"$FIX_BASE/symlink-sync.err" || rc=$?
  err="$(cat "$FIX_BASE/symlink-sync.err")"

  assert_eq "1" "$rc" "direct sync must reject a symlinked account"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "symlink refusal writes zero bytes to stdout"
  assert_eq "$root_before" "$(tree_snapshot "$FIX_ROOT")" \
    "symlink refusal leaves the managed root byte-for-byte unchanged"
  assert_eq "$external_before" "$(tree_snapshot "$external")" \
    "symlink refusal leaves the external target byte-for-byte unchanged"
  assert_eq "no" "$(yesno test -e "$external/projects")" \
    "symlink refusal creates no external project directory"
  assert_contains "$err" "refusing account mutation" \
    "the direct-call refusal explains the containment boundary"
  cleanup_memory_fixture
}

t_sync_direct_call_refuses_traversal_before_path_composition() {
  make_memory_fixture
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  local external="$FIX_BASE/external-account"
  mkdir -p "$external"
  printf 'external sentinel bytes\n' > "$external/sentinel.txt"
  local root_before external_before rc=0 out="$FIX_BASE/traversal-sync.out" err
  root_before="$(tree_snapshot "$FIX_ROOT")"
  external_before="$(tree_snapshot "$external")"

  sync_project_memory ../external-account >"$out" \
    2>"$FIX_BASE/traversal-sync.err" || rc=$?
  err="$(cat "$FIX_BASE/traversal-sync.err")"

  assert_eq "1" "$rc" "direct sync must reject a traversal-shaped account"
  assert_eq "0" "$(wc -c < "$out" | tr -d '[:space:]')" \
    "traversal refusal writes zero bytes to stdout"
  assert_eq "$root_before" "$(tree_snapshot "$FIX_ROOT")" \
    "traversal refusal leaves the managed root byte-for-byte unchanged"
  assert_eq "$external_before" "$(tree_snapshot "$external")" \
    "traversal refusal leaves the external target byte-for-byte unchanged"
  assert_eq "no" "$(yesno test -e "$external/projects")" \
    "traversal refusal creates no external project directory"
  assert_contains "$err" "invalid account name" \
    "the traversal-shaped value is rejected by the canonical name policy"
  cleanup_memory_fixture
}

t_sync_is_a_noop_when_the_store_is_empty() {
  make_memory_fixture
  mkdir -p "$FIX_ROOT/personal"
  assert_eq "yes" "$(yesno sync_project_memory personal)" \
    "an unseeded store must exit 0, not abort the caller under set -e"
  cleanup_memory_fixture
}

t_sync_second_run_changes_nothing_and_says_nothing() {
  make_memory_fixture
  fix_seed_and_account personal
  sync_project_memory personal 2>/dev/null

  local snap1 snap2 err
  snap1="$(cd "$FIX_ROOT/personal" && find . -printf '%p %y %l\n' | sort | cksum)"
  err="$(sync_project_memory personal 2>&1 >/dev/null)"
  assert_stdout_empty_bytes sync_project_memory personal
  snap2="$(cd "$FIX_ROOT/personal" && find . -printf '%p %y %l\n' | sort | cksum)"

  assert_eq "$snap1" "$snap2" "a repeat sync must not change the tree"
  assert_eq "" "$err" "a repeat sync must report nothing on stderr"
  cleanup_memory_fixture
}

t_sync_repoints_a_wrong_target() {
  make_memory_fixture
  fix_seed_and_account personal
  local slug link err
  slug="${FIX_REAL_SLUGS[0]}"
  link="$(memory_link_path personal "$slug")"
  mkdir -p "$(dirname "$link")"
  ln -s "../../../shared/project-memory/WRONG" "$link"

  err="$(sync_project_memory personal 2>&1 >/dev/null)"
  assert_link "$link" "$(memory_link_target "$slug")"
  assert_contains "$err" "repointed" "the repair must be narrated on stderr"
  cleanup_memory_fixture
}

t_sync_repairs_a_dangling_wrong_link_for_an_enumerated_slug() {
  make_memory_fixture
  fix_seed_and_account personal
  local slug link
  slug="${FIX_REAL_SLUGS[1]}"
  link="$(memory_link_path personal "$slug")"
  mkdir -p "$(dirname "$link")"
  ln -s "../../../shared/project-memory/does-not-exist" "$link"

  assert_eq "yes" "$(yesno test -d "$(project_memory_store)/$slug")" \
    "the repaired slug must be an existing enumerated store directory"
  sync_project_memory personal 2>/dev/null
  assert_eq "yes" "$(yesno test -d "$link")" \
    "a dangling wrong link must be repaired until it resolves"
  assert_link "$link" "$(memory_link_target "$slug")"
  cleanup_memory_fixture
}

t_sync_leaves_an_unenumerated_dangling_link_untouched() {
  make_memory_fixture
  mkdir -p "$FIX_ROOT/personal/projects/orphan-slug"
  local link="$FIX_ROOT/personal/projects/orphan-slug/memory"
  local target="../../../shared/project-memory/orphan-slug"
  ln -s "$target" "$link"

  sync_project_memory personal 2>/dev/null
  assert_link "$link" "$target"
  assert_eq "no" "$(yesno test -e "$FIX_ROOT/shared/project-memory/orphan-slug")" \
    "sync must not invent a store directory for an unenumerated link"
  cleanup_memory_fixture
}

t_sync_backs_up_a_real_directory_uniquely_before_relinking() {
  make_memory_fixture
  fix_seed_and_account personal
  local slug link err backup out="$FIX_BASE/sync.out"
  slug="${FIX_REAL_SLUGS[2]}"
  link="$(memory_link_path personal "$slug")"
  mkdir -p "$link"
  printf 'local notes that must survive\n' > "$link/LOCAL.md"

  backup="$link.backup-20260911T010203Z"
  mkdir -p "$backup"
  printf 'existing backup\n' > "$backup/SENTINEL"
  date() { printf '20260911T010203Z\n'; }
  sync_project_memory personal >"$out" 2>"$FIX_BASE/sync.err"
  err="$(cat "$FIX_BASE/sync.err")"

  assert_link "$link" "$(memory_link_target "$slug")"
  assert_eq "0" "$(wc -c < "$out" | tr -d ' ')" \
    "a backup-and-relink repair writes zero bytes to stdout"
  assert_contains "$err" "backed up" "the backup must be narrated"
  assert_eq "existing backup" "$(cat "$backup/SENTINEL")" \
    "an existing backup name must never be overwritten"
  assert_eq "local notes that must survive" "$(cat "$backup.1/LOCAL.md")" \
    "the pre-existing directory content must survive in a unique backup"
  cleanup_memory_fixture
}

t_sync_backs_up_a_real_file_before_relinking() {
  make_memory_fixture
  fix_seed_and_account personal
  local slug link err backup found=""
  slug="${FIX_REAL_SLUGS[3]}"
  link="$(memory_link_path personal "$slug")"
  mkdir -p "$(dirname "$link")"
  printf 'not a directory\n' > "$link"

  err="$(sync_project_memory personal 2>&1 >/dev/null)"
  assert_link "$link" "$(memory_link_target "$slug")"
  for backup in "$link".backup-*; do
    if [[ -f $backup ]]; then
      found="$backup"
    fi
  done
  assert_eq "no" "$(yesno test -z "$found")" "a backup file must exist"
  assert_eq "not a directory" "$(cat "$found")" "file content preserved"
  assert_contains "$err" "backed up" "the backup must be narrated"
  cleanup_memory_fixture
}

t_sync_refuses_and_restores_content_when_relink_fails() {
  make_memory_fixture
  mkdir -p "$FIX_ROOT/personal"
  local slug="safe-relink-slug" link rc=0 err out="$FIX_BASE/sync.out"
  mkdir -p "$(project_memory_store)/$slug"
  link="$(memory_link_path personal "$slug")"
  mkdir -p "$link"
  printf 'must remain in place\n' > "$link/LOCAL.md"

  ln() { return 1; }
  sync_project_memory personal >"$out" 2>"$FIX_BASE/sync.err" || rc=$?
  unset -f ln
  err="$(cat "$FIX_BASE/sync.err")"

  assert_eq "1" "$rc" "a failed relink must refuse the sync"
  assert_eq "0" "$(wc -c < "$out" | tr -d ' ')" \
    "a refused relink writes zero bytes to stdout"
  assert_eq "no" "$(yesno test -L "$link")" \
    "a failed relink must not pretend a link was established"
  assert_eq "must remain in place" "$(cat "$link/LOCAL.md")" \
    "content must be restored at its original path when relinking fails"
  assert_contains "$err" "restored" "the safe refusal must be narrated"
  cleanup_memory_fixture
}

t_sync_picks_up_a_slug_added_to_the_store_later() {
  make_memory_fixture
  fix_seed_and_account personal
  sync_project_memory personal 2>/dev/null

  local slug link
  slug="$(fix_slug projects/beta-app)-later"
  mkdir -p "$FIX_ROOT/shared/project-memory/$slug"
  printf 'new project\n' > "$FIX_ROOT/shared/project-memory/$slug/MEMORY.md"

  sync_project_memory personal 2>/dev/null
  link="$(memory_link_path personal "$slug")"
  assert_link "$link" "$(memory_link_target "$slug")"
  assert_eq "new project" "$(cat "$link/MEMORY.md")" "the new link resolves"
  cleanup_memory_fixture
}

t_full_seed_then_sync_twice_is_stable() {
  make_memory_fixture
  mkdir -p "$FIX_ROOT/personal" "$FIX_ROOT/work"
  seed_project_memory "$FIX_MAIN" 2>/dev/null
  sync_project_memory personal 2>/dev/null
  sync_project_memory work 2>/dev/null

  local snap1 snap2 err
  snap1="$(cd "$FIX_ROOT" && find . -printf '%p %y %s %T@ %l\n' | sort | cksum)"
  err="$( { seed_project_memory "$FIX_MAIN"; sync_project_memory personal; sync_project_memory work; } 2>&1 >/dev/null )"
  snap2="$(cd "$FIX_ROOT" && find . -printf '%p %y %s %T@ %l\n' | sort | cksum)"
  assert_eq "$snap1" "$snap2" "the whole seed+multi-account sync cycle is idempotent"
  assert_eq "" "$err" "the second cycle reports nothing new"
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
