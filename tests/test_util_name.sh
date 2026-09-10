#!/usr/bin/env bash
# The account-name grammar: ^[a-z0-9][a-z0-9-]{0,31}$, reserved names,
# leading dots, and uppercase lowercased with a notice.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"
source "$REPO_ROOT/lib/config.sh"
source "$REPO_ROOT/lib/util.sh"

# ── accepted ─────────────────────────────────────────────────────────────────
validate_name "work";            assert_eq "work" "$CANONICAL_NAME"
validate_name "personal";        assert_eq "personal" "$CANONICAL_NAME"
validate_name "personal-mother"; assert_eq "personal-mother" "$CANONICAL_NAME"
validate_name "a";               assert_eq "a" "$CANONICAL_NAME"
validate_name "0";               assert_eq "0" "$CANONICAL_NAME"
validate_name "a1-b2-c3";        assert_eq "a1-b2-c3" "$CANONICAL_NAME"
validate_name "work-";           assert_eq "work-" "$CANONICAL_NAME"

# Exactly 32 characters is the boundary and must pass.
n32="$(printf 'a%.0s' {1..32})"
validate_name "$n32"
assert_eq "32" "${#CANONICAL_NAME}"

# ── uppercase is lowercased, with a notice on stderr and nothing on stdout ───
err="$(validate_name "Work-Two" 2>&1 >/dev/null)"
assert_contains "$err" "work-two"
assert_contains "$err" "lowercase"
validate_name "Work-Two" 2>/dev/null
assert_eq "work-two" "$CANONICAL_NAME"
assert_no_stdout validate_name "Work-Two"
assert_stdout_empty_bytes validate_name "Work-Two"
validate_name "WORK" 2>/dev/null
assert_eq "work" "$CANONICAL_NAME"

# ── rejected by the grammar ──────────────────────────────────────────────────
n33="$(printf 'a%.0s' {1..33})"
for bad in "" "-lead" "under_score" "has space" "has/slash" "has.dot" \
           "$n33" "bad!" $'tab\tinside' "a+b"; do
  assert_fails validate_name "$bad"
done
assert_contains "$(validate_name "has space" 2>&1 >/dev/null || true)" \
  "invalid account name"
assert_no_stdout validate_name "has space"
assert_stdout_empty_bytes validate_name "has space"

# The grammar is a whole-string path guard, not a search for a valid substring.
# Traversal, line breaks, and surrounding whitespace must all be rejected.
for bad in "../work" "work/.." "work/../shared" \
           " work" "work " $'\twork' $'work\t' \
           $'\nwork' $'work\n' $'work\nshared'; do
  assert_fails validate_name "$bad"
done

# ── leading dot ──────────────────────────────────────────────────────────────
assert_fails validate_name ".hidden"
assert_fails validate_name "."
assert_fails validate_name ".."
assert_contains "$(validate_name ".hidden" 2>&1 >/dev/null || true)" \
  "may not start with"

# ── reserved ─────────────────────────────────────────────────────────────────
assert_fails validate_name "shared"
assert_fails validate_name "plugin-cache"
assert_fails validate_name "project-memory"
assert_fails validate_name ".trash"
assert_contains "$(validate_name "shared" 2>&1 >/dev/null || true)" "reserved"
# Lowercased first, so the reserved check still catches it.
assert_fails validate_name "Shared"
assert_fails validate_name "PLUGIN-CACHE"

# ── a rejection must clear CANONICAL_NAME ────────────────────────────────────
validate_name "work" 2>/dev/null
assert_eq "work" "$CANONICAL_NAME"
assert_fails validate_name "shared"
assert_eq "" "$CANONICAL_NAME" "a rejected name must not leave a stale value"
assert_fails validate_name "has space"
assert_eq "" "$CANONICAL_NAME"
validate_name "work" 2>/dev/null
assert_fails validate_name $'work\nshared'
assert_eq "" "$CANONICAL_NAME"
