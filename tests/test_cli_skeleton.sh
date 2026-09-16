#!/usr/bin/env bash
# The entry point must be BOTH executable and source-able, and must never
# write to stdout.
set -euo pipefail
source "$REPO_ROOT/tests/assert.sh"

bin="$REPO_ROOT/bin/claude-multi"

if [[ ! -x "$bin" ]]; then
  printf '  FAIL: %s is not executable\n' "$bin" >&2
  exit 1
fi
assert_eq "#!/usr/bin/env bash" "$(head -1 "$bin")"

# ── --help ──────────────────────────────────────────────────────────────────────────────
err="$("$bin" --help 2>&1 >/dev/null)"
assert_contains "$err" "Usage:"
assert_contains "$err" "claude-multi <account>"
assert_contains "$err" "--version"
assert_no_stdout "$bin" --help
"$bin" --help 2>/dev/null
"$bin" -h 2>/dev/null

# ── --version ──────────────────────────────────────────────────────────────────
err="$("$bin" --version 2>&1 >/dev/null)"
assert_contains "$err" "claude-multi"
assert_contains "$err" "0.1.0"
assert_no_stdout "$bin" --version

# ── no args: the menu path (Phase 6 fills it in) ────────────────────────────
mkdir -p "$CLAUDE_MULTI_ROOT/shared"
err="$("$bin" </dev/null 2>&1 >/dev/null)"
assert_contains "$err" "Claude accounts"
assert_contains "$err" "no accounts yet"
assert_no_stdout "$bin" </dev/null

# ── an account name is validated, and a bad one exits 1 ─────────────────────
assert_fails "$bin" "Bad Name"
assert_contains "$("$bin" "Bad Name" 2>&1 >/dev/null || true)" "invalid account name"
assert_no_stdout "$bin" "Bad Name"

assert_fails "$bin" "shared"
assert_contains "$("$bin" "shared" 2>&1 >/dev/null || true)" "reserved"
assert_no_stdout "$bin" "shared"

assert_fails "$bin" ".hidden"
assert_contains "$("$bin" ".hidden" 2>&1 >/dev/null || true)" "may not start with"

# a valid but absent name reaches non-first-run account resolution
assert_fails "$bin" work
err="$("$bin" work 2>&1 >/dev/null || true)"
assert_contains "$err" "work"
assert_contains "$err" "unknown account"
assert_no_stdout "$bin" work
# uppercase is lowercased on the way through
assert_fails "$bin" WORK
assert_contains "$("$bin" WORK 2>&1 >/dev/null || true)" "work"

# ── no CLI verbs: 'add' is just an account name ─────────────────────────────
for verb in add delete sync doctor; do
  assert_fails "$bin" "$verb"
  err="$("$bin" "$verb" 2>&1 >/dev/null || true)"
  assert_contains "$err" "$verb"
  assert_eq "" "$(printf '%s' "$err" | grep -i "unknown command" || true)" \
    "$verb must be treated as an account name, not a verb"
done

# ── a relative CLAUDE_MULTI_ROOT is refused before anything happens ─────────────
assert_fails env CLAUDE_MULTI_ROOT="relative/root" "$bin" work
assert_contains "$(env CLAUDE_MULTI_ROOT="relative/root" "$bin" work 2>&1 >/dev/null || true)" \
  "absolute"

# ── source-able: the main guard must not run main ────────────────────────────
source "$bin"
assert_eq "claude-multi" "$CLAUDE_MULTI_PROG"
assert_eq "0.1.0" "$CLAUDE_MULTI_VERSION"
if [[ ! -d "$CLAUDE_MULTI_LIB" ]]; then
  printf '  FAIL: CLAUDE_MULTI_LIB [%s] is not a directory\n' "$CLAUDE_MULTI_LIB" >&2
  exit 1
fi
# both libraries came with it
validate_name "work" 2>/dev/null
assert_eq "work" "$CANONICAL_NAME"
assert_eq "$CLAUDE_MULTI_ROOT" "$(multi_root)"
assert_eq "7" "$(shared_item_names | wc -l | tr -d '[:space:]')"
# and functions are callable directly, which is the whole point of the guard
assert_no_stdout usage
assert_contains "$(usage 2>&1 >/dev/null)" "Usage:"

# ── lib discovery survives the ~/.local/bin install symlink ────────────────────────
mkdir -p "$TEST_TMP/local-bin"
ln -sf "$bin" "$TEST_TMP/local-bin/claude-multi"
assert_contains "$("$TEST_TMP/local-bin/claude-multi" --help 2>&1 >/dev/null)" "Usage:"
