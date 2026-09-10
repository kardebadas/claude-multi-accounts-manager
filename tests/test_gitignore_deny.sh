# shellcheck shell=bash
# tests/test_gitignore_deny.sh — .gitignore is deny-by-default. This proves it.
#
# The real .gitignore ignores EVERYTHING at the top level (`/*`) and then adds
# explicit `!` allows, plus a set of landmine patterns that apply anywhere
# inside the allowed directories. That shape is the whole safety story for a
# PUBLIC repository: a file a future agent carelessly drops here is ignored
# because nobody allowed it, rather than committed because nobody denied it.
#
# This suite is a regression lock on that file. It copies the REAL .gitignore
# into a throwaway repo, plants the exact tree the design spec names, and
# proves the ignore rules block exactly the landmines and nothing legitimate.
#
# Invoked as `bash tests/test_gitignore_deny.sh` (by tests/run.sh, or by hand)
# with REPO_ROOT and TEST_TMP exported. Not executable and no shebang, matching
# tests/assert.sh and the other tests/test_*.sh files.
#
# FOUR RULES THIS FILE MUST FOLLOW, all of which are about this file itself:
#
#  1. Never `git add -A`. CLAUDE.md forbids it, and it is not needed: the
#     questions here are answered by `git check-ignore -v` (which also names
#     the rule that fired) and by `git add --dry-run`, neither of which
#     mutates an index.
#  2. Never touch the real repository. The only thing read from it is
#     .gitignore, which is copied out; every plant, stage and reset happens in
#     a throwaway `git init` repo under $TEST_TMP.
#  3. Every landmine BASENAME is assembled at runtime with printf. The guard's
#     content rules do not describe these names today, but this project has
#     already been bitten once by a fixture literal that its own guard refused
#     (a hard-coded absolute home path), and a committed literal is exactly the
#     thing that turns a new content rule into a suite that cannot be
#     committed. Assembling costs one function call.
#  4. Where a test stages something it clears the INDEX afterwards
#     (`git rm --cached` / `git reset`) and asserts the index is empty. `rm` on
#     the working file does not unstage anything.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"

guard="$REPO_ROOT/scripts/check-no-secrets.sh"

# ── the planted tree ─────────────────────────────────────────────────────────
# Paths that MUST be trackable: the tool, its tests and its docs of record.
legit_paths() {
  printf '%s\n' \
    .gitignore \
    CLAUDE.md \
    README.md \
    LICENSE \
    install.sh \
    bin/claude-multi \
    lib/util.sh \
    lib/config.sh \
    scripts/check-no-secrets.sh \
    tests/run.sh \
    tests/assert.sh \
    tests/fake-claude
}

# Landmines that MUST NOT be trackable. Basenames assembled at runtime (rule 3);
# the directory parts are ordinary words and carry nothing sensitive.
landmine_paths() {
  printf 'tests/.%s.json\n' "credentials"
  printf 'shared/CLAUDE.md\n'
  printf 'lib/account-backup.%s\n' "tgz"
  printf 'tests/tmp/scratch\n'
  printf 'scripts/run.%s\n' "log"
  printf '.trash/work-1.%s\n' "tgz"
  printf 'docs/superpowers/spec.md\n'
  printf 'Makefile\n'
}

# The subset of the landmines that the SECOND gate also covers.
#
# `Makefile` is deliberately not in it. The two gates are layered, not
# duplicated: .gitignore's job is deny-by-default over the whole tree, so it
# blocks any unforeseen top-level path including a Makefile, while the guard's
# PATH_RULES describe things that are actually dangerous to publish — configs,
# credentials, archives, logs, transcripts. A Makefile is none of those, and
# adding it to the guard would be dressing a layout rule up as a secret rule.
# t_the_ignore_only_landmine_is_not_a_guard_rule states that gap out loud so
# nobody reads the loop below as "the guard catches every landmine".
guard_refused_landmines() {
  # sed, not grep: a zero-match grep exits 1 and would abort the pipeline under
  # pipefail with no diagnostic at all (hazard 2). sed exits 0 either way, and
  # the count is asserted by the caller.
  landmine_paths | sed '/^Makefile$/d'
}

# plant <path…> — create each file with the single byte body `x`, so only the
# NAME is ever under test.
plant() {
  local p
  for p in "$@"; do
    mkdir -p -- "$(dirname -- "$p")"
    printf 'x\n' >"$p"
  done
}

# mock_repo — a throwaway repo carrying the REAL .gitignore and the full
# planted tree, cd'd into. Echoes nothing.
#
# .gitignore is in legit_paths because it must be provably trackable, but it is
# the FIXTURE as well as a fixture subject: planting an `x` over it is what a
# first draft of this file did, and every ignore assertion then passed
# vacuously against an empty rule set. It is therefore skipped when planting.
mock_repo() {
  local repo p
  repo="$(mktemp -d "$TEST_TMP/mock.XXXXXX")"
  cd -- "$repo"
  git init -q -b main .
  cp -- "$REPO_ROOT/.gitignore" .gitignore
  # `if … then continue; fi`, never `[[ … ]] && continue`: the latter returns 1
  # on the last iteration that does not match and errexit kills the test.
  while IFS= read -r p; do
    if [[ "$p" == ".gitignore" ]]; then
      continue
    fi
    plant "$p"
  done < <(legit_paths; landmine_paths)
}

# ── every landmine is ignored, and the rule that caught it is named ──────────
# `git check-ignore -v` prints "<source>:<line>:<pattern>\t<path>" and exits 0
# only when the path IS ignored, so it answers both halves at once: ignored,
# and by which rule. Nothing is staged, so nothing needs unstaging.
t_every_landmine_is_ignored_by_a_named_rule() {
  mock_repo
  local p out
  while IFS= read -r p; do
    if ! git check-ignore -q -- "$p"; then
      printf '  FAIL: %s is NOT ignored — the deny-by-default guarantee is broken\n' "$p" >&2
      return 1
    fi
    out="$(git check-ignore -v -- "$p")"
    assert_contains "$out" ".gitignore:" "the ignoring rule must come from .gitignore"
    assert_contains "$out" "$p" "check-ignore must name the path it matched"
  done < <(landmine_paths)
}

# ── every legitimate file is trackable ───────────────────────────────────────
t_every_legitimate_path_is_not_ignored() {
  mock_repo
  local p
  while IFS= read -r p; do
    if git check-ignore -q -- "$p"; then
      printf '  FAIL: %s IS ignored, but the tool needs it tracked:\n' "$p" >&2
      git check-ignore -v -- "$p" >&2
      return 1
    fi
  done < <(legit_paths)
}

# ── "exactly": what git would stage is the legitimate set and nothing else ───
# `git add --dry-run` over the whole tree reports what a real `git add` would
# pick up, honouring .gitignore, and changes no index — the non-mutating
# equivalent of the `git add -A` this repository forbids.
t_a_whole_tree_add_would_stage_exactly_the_legitimate_set() {
  mock_repo
  local want got
  want="$(legit_paths | sort)"
  # sed, not grep: no zero-match exit status to trip pipefail (hazard 2), and
  # git add --dry-run prints exactly "add '<path>'" per line.
  got="$(git add --dry-run -- . | sed -n "s/^add '\\(.*\\)'\$/\\1/p" | sort)"
  assert_eq "$want" "$got" \
    "a whole-tree add must pick up the legitimate set and nothing else"
  assert_eq "" "$(git diff --cached --name-only)" \
    "--dry-run must not have staged anything"
}

# Trackable in principle is not trackable in fact: stage the legitimate set for
# real and require the index to hold exactly it.
t_the_legitimate_set_actually_stages() {
  mock_repo
  local -a want=()
  while IFS= read -r p; do want+=("$p"); done < <(legit_paths)
  git add -- "${want[@]}"
  assert_eq "$(legit_paths | sort)" "$(git diff --cached --name-only | sort)" \
    "the index must hold exactly the legitimate set"
  # Clear the INDEX, then prove it is clear.
  git rm -r -q --cached -- . >/dev/null
  git reset -q
  assert_eq "" "$(git diff --cached --name-only)" "the test must leave the index clean"
}

# ── deny-by-default, not a blocklist ─────────────────────────────────────────
# The property that matters most is about files nobody has thought of yet. A
# brand-new top-level path must be ignored because it was never allowed. If
# this test ever fails, .gitignore has been turned back into a blocklist.
t_an_unforeseen_top_level_path_is_ignored() {
  mock_repo
  plant surprise.sh vendor/thing.sh notes/whatever.md .hidden-thing
  local p
  for p in surprise.sh vendor/thing.sh notes/whatever.md .hidden-thing; do
    if ! git check-ignore -q -- "$p"; then
      printf '  FAIL: %s is NOT ignored — .gitignore is no longer deny-by-default\n' "$p" >&2
      return 1
    fi
  done
  # And the allow list is by NAME, so a new file inside an allowed directory is
  # tracked on purpose — that is the cost of the design, stated as a test.
  plant lib/brand-new.sh
  assert_fails git check-ignore -q -- lib/brand-new.sh
}

# ── the second gate catches whatever is forced past the first ────────────────
t_a_forced_landmine_is_still_refused_by_the_guard() {
  mock_repo
  local p out n=0
  while IFS= read -r p; do
    n=$((n + 1))
    git add -f -- "$p"
    if bash "$guard" >/dev/null 2>&1; then
      printf '  FAIL: the guard accepted a force-staged landmine: %s\n' "$p" >&2
      git reset -q
      return 1
    fi
    out="$(bash "$guard" 2>&1 >/dev/null || true)"
    assert_contains "$out" "REFUSED" "the guard must say REFUSED"
    assert_contains "$out" "$p" "the refusal must name the forced path"
    git rm -q --cached -- "$p" >/dev/null
    assert_eq "" "$(git diff --cached --name-only)" \
      "each iteration must leave the index clean"
  done < <(guard_refused_landmines)
  # A `while read` loop that reads nothing is silent, so the count is asserted:
  # zero iterations must never look like a pass.
  assert_eq "7" "$n" "every guard-covered landmine must have been exercised"
}

# The layering, stated as a test: this landmine is blocked by .gitignore ALONE.
# If a future change teaches the guard about it, this test fails and whoever
# made that change decides on purpose whether the layering has moved.
t_the_ignore_only_landmine_is_not_a_guard_rule() {
  mock_repo
  git check-ignore -q -- Makefile
  git add -f -- Makefile
  if ! bash "$guard" >/dev/null 2>&1; then
    printf '  FAIL: the guard now refuses Makefile; the gate layering has changed:\n%s\n' \
      "$(bash "$guard" 2>&1 >/dev/null || true)" >&2
    git reset -q
    return 1
  fi
  git rm -q --cached -- Makefile >/dev/null
  assert_eq "" "$(git diff --cached --name-only)" "the test must leave the index clean"
}

# And the legitimate set, staged for real, must pass the guard: a gate that
# refuses the tool's own files would simply be turned off by whoever hit it.
t_the_legitimate_set_passes_the_guard() {
  mock_repo
  local -a want=()
  while IFS= read -r p; do want+=("$p"); done < <(legit_paths)
  git add -- "${want[@]}"
  if ! bash "$guard" >/dev/null 2>&1; then
    printf '  FAIL: the guard refused the legitimate set:\n%s\n' \
      "$(bash "$guard" 2>&1 >/dev/null || true)" >&2
    git reset -q
    return 1
  fi
  assert_stdout_empty_bytes bash "$guard"
  git rm -r -q --cached -- . >/dev/null
  git reset -q
  assert_eq "" "$(git diff --cached --name-only)" "the test must leave the index clean"
}

# ── the dispatch below has teeth ─────────────────────────────────────────────
# Hazard 1, measured in this project rather than assumed: bash suppresses
# errexit for everything run inside an `if` condition, and the suppression
# survives both a subshell and an explicit `set -e` inside it. A test written
# as `if ! ( set -e; "$fn" ); then …` therefore keeps executing past its first
# failed assertion and is recorded as a PASS.
#
# This runs a probe that fails an assertion and then would do more work,
# through the exact construct the dispatch uses, and requires that (a) the
# status is non-zero and (b) the work after the failure never happened.
_probe_fails_early_then_would_pass() {
  printf 'phase-1\n' >>"$TEST_TMP/probe.log"
  assert_eq "expected" "actual" "the probe is supposed to fail right here"
  printf 'phase-2\n' >>"$TEST_TMP/probe.log"
}

t_dispatch_records_an_early_failure() {
  local rc=0
  rm -f -- "$TEST_TMP/probe.log"
  set +e
  ( set -euo pipefail; _probe_fails_early_then_would_pass ) 2>/dev/null
  rc=$?
  set -e
  assert_eq "1" "$rc" "an early assertion failure must surface as a non-zero status"
  assert_eq "phase-1" "$(cat -- "$TEST_TMP/probe.log")" \
    "execution must stop AT the failing assertion — phase-2 must never run"
  rm -f -- "$TEST_TMP/probe.log"
}

# ── dispatch ─────────────────────────────────────────────────────────────────
# Every t_* function defined above runs, in its own subshell so one failure
# cannot abort the rest and so a test's `cd` cannot leak into the next. Zero
# discovered tests is a loud failure, not a silent pass.
#
# Two deliberate choices, both hazards this project has already been bitten by:
#   * the subshell is run as a PLAIN COMMAND with errexit temporarily off, not
#     as `if ! ( … )` — see t_dispatch_records_an_early_failure above.
#   * discovery uses awk alone, with no grep in the pipeline. A zero-match
#     `grep` exits 1, which under pipefail kills the enclosing construct with
#     no diagnostic; the reader just sees fewer tests run. awk exits 0 whether
#     it matches or not, so the "no tests discovered" check below is the only
#     thing that can report an empty set — and it reports it loudly.
declare -a discovered=()
while IFS= read -r fn; do
  discovered+=("$fn")
done < <(declare -F | awk '$3 ~ /^t_/ { print $3 }' | sort)

if ((${#discovered[@]} == 0)); then
  printf '  FAIL: no t_* test functions discovered in %s\n' "${BASH_SOURCE[0]}" >&2
  exit 1
fi

failures=0
for fn in "${discovered[@]}"; do
  set +e
  ( set -euo pipefail; cd -- "$TEST_TMP" && "$fn" )
  rc=$?
  set -e
  if ((rc != 0)); then
    printf '  FAIL: %s (exit %d)\n' "$fn" "$rc" >&2
    failures=$((failures + 1))
  fi
done

printf '  %d test(s), %d failed\n' "${#discovered[@]}" "$failures" >&2
((failures == 0)) || exit 1
