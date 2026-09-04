# shellcheck shell=bash
# lib/config.sh — where things live, and what is shared.
#
# Sourced as "$CLAUDE_MULTI_LIB/config.sh", never executed: no shebang, not
# executable, and deliberately no `set -euo pipefail` — those options would
# leak into whatever sourced this file. Sourcing it twice is a no-op beyond
# redefining the same functions and re-assigning the same table.
#
# Everything here is a pure getter or a predicate: nothing creates a directory,
# nothing writes state, nothing reads the filesystem, and nothing calls die().
# A getter is used as "$(multi_root)", and an exit inside a command
# substitution would kill only the subshell, leaving the caller running with an
# empty path — which is exactly how an `rm -rf "$root/$name"` becomes
# `rm -rf "/$name"`. Validation is therefore a separate predicate that returns.
#
# ── CHANNELS (load-bearing; do not "purge stdout" here) ─────────────────────
# stdout is reserved project-wide for data and for `exec claude`, and these
# functions split cleanly into two kinds:
#
#   DATA PRODUCERS — write their value to stdout and nothing else. Their value
#   is consumed via $( ), so moving it to stderr breaks every caller. They emit
#   nothing on stderr at all.
#       multi_root        the managed root
#       shared_dir        <root>/shared
#       trash_dir         <root>/.trash
#       account_dir       <root>/<name>
#       shared_items         one "<name>|<kind>|<origin>" row per line
#       shared_item_names    the seven item names, one per line, in seed order
#       shared_item_kind     `file` or `dir`, for one item
#       shared_item_origin   `copy`/`create`/`link`/`rewrite`, for one item
#       account_link_target  `../shared/<name>`, the account-side link target
#   Callers MUST capture them — `root="$(multi_root)"`. Nothing in bin/ or
#   lib/ may call one bare, or the value lands on claude's stdout.
#
#   The four per-item accessors refuse an unknown or empty name by returning 1
#   and printing NOTHING on either channel — the same rule account_dir follows.
#   The caller decides what to say about it; a getter that narrated would put
#   its sentence on claude's stdout.
#
#   DIAGNOSTIC PREDICATES — return 0/1 and write only to stderr, never stdout.
#       validate_root_path   one error line to stderr on refusal
#       is_reserved_name     silent; no output on either channel
#
# So: a stdout audit must leave the nine producers alone, and hold the two
# predicates to zero bytes of stdout. `_shared_item_row` is internal and is a
# producer too, for the same reason.

# ── reserved names ───────────────────────────────────────────────────────────
# Names that can never be an account, because the layout already uses them:
# `shared` and `.trash` sit directly in the managed root, and `plugin-cache`
# and `project-memory` are shared/ subdirectories that are refused as well so
# a stray directory at the root can never be listed or launched as an account.
# Phase 5's list_accounts and add_account both hang off this table; a missing
# entry is a directory launched as if it were an account.
#
# A plain assignment, not `readonly` and not `+=`: re-sourcing must replace the
# table rather than append to it or abort.
CLAUDE_MULTI_RESERVED_NAMES=(shared .trash plugin-cache project-memory)

# is_reserved_name <name> -> 0 if the name is reserved.
# Case-sensitive on purpose: validate_name lowercases its input before asking.
# Matched literally, so `shared-work` and `share` are ordinary names.
# Silent on both channels: it is a predicate, not a reporter.
is_reserved_name() {
  local candidate="${1-}" reserved
  if [[ -z "$candidate" ]]; then
    return 1
  fi
  for reserved in "${CLAUDE_MULTI_RESERVED_NAMES[@]}"; do
    if [[ "$candidate" == "$reserved" ]]; then
      return 0
    fi
  done
  return 1
}

# ── root resolution ──────────────────────────────────────────────────────────
# _strip_trailing_slashes <path> -> the path without trailing "/", except "/".
_strip_trailing_slashes() {
  local path="${1-}"
  while [[ "$path" == */ && "$path" != "/" ]]; do
    path="${path%/}"
  done
  printf '%s' "$path"
}

# multi_root -> the managed root. Test seam 2.
#
# $CLAUDE_MULTI_ROOT when non-empty, else $HOME/.claude-multi. HOME is read on
# every call, never captured at source time, so a test that swaps HOME gets an
# answer under its own temp home instead of the developer's real one.
#
# DATA PRODUCER: the path on stdout, nothing on stderr.
multi_root() {
  local root="${CLAUDE_MULTI_ROOT:-}" home=""
  if [[ -z "$root" ]]; then
    home="$(_strip_trailing_slashes "$HOME")"
    # HOME=/ would otherwise produce "//.claude-multi"
    if [[ "$home" == "/" ]]; then
      home=""
    fi
    root="$home/.claude-multi"
  fi
  printf '%s\n' "$(_strip_trailing_slashes "$root")"
}

# _root_join <suffix> -> <root>/<suffix>, with the same normalisation
# multi_root applies to HOME=/: a root of "/" composes to "/shared", never
# "//shared". Every derived getter goes through here so the composition rule
# lives in exactly one place. Internal; the suffix is appended verbatim.
_root_join() {
  local root
  root="$(multi_root)"
  if [[ "$root" == "/" ]]; then
    root=""
  fi
  printf '%s\n' "$root/${1-}"
}

# shared_dir -> <root>/shared      DATA PRODUCER
shared_dir() {
  _root_join shared
}

# trash_dir -> <root>/.trash       DATA PRODUCER
trash_dir() {
  _root_join .trash
}

# account_dir <name> -> <root>/<name>   DATA PRODUCER
#
# PRECONDITION: <name> MUST already have passed validate_name. This function
# performs no validation of its own — it composes a path and nothing else, so
# `..`, a leading dot, an absolute path and any other grammar violation are
# appended verbatim. The grammar and the traversal guard live in validate_name,
# deliberately in one place: duplicating them here would give the project two
# gates to keep in sync, and the weaker one would decide. Callers that go on to
# remove the composed path — Phase 5's purge and trash paths — are the reason
# the precondition is written down rather than left to be inferred.
#
# Returns 1 and prints nothing for an empty name: "$root/" is the root itself,
# and handing that to a caller that is about to remove it is how the tool
# deletes everything. That guard is here, not in validate_name, because it
# protects the composition rather than the name.
account_dir() {
  local name="${1-}"
  if [[ -z "$name" ]]; then
    return 1
  fi
  _root_join "$name"
}

# validate_root_path <path> -> 0 if usable, else one stderr line and 1.
# An absolute root is a precondition for every destructive path in Phase 5.
# DIAGNOSTIC PREDICATE: stderr only, never stdout, and silent when it passes.
validate_root_path() {
  local root="${1-}"
  if [[ -z "$root" ]]; then
    printf '%s: error: the managed root is empty\n' \
      "${CLAUDE_MULTI_PROG:-claude-multi}" >&2
    return 1
  fi
  if [[ "$root" != /* ]]; then
    printf '%s: error: CLAUDE_MULTI_ROOT must be an absolute path: %s\n' \
      "${CLAUDE_MULTI_PROG:-claude-multi}" "$root" >&2
    return 1
  fi
  return 0
}

# ── the shared-item table ─────────────────────────────────────────────────────
# The single source of truth for what lives in shared/ and is symlinked into
# every account. Phase 2 iterates it to create and verify the account-side
# links; Phase 3 iterates it to seed shared/ from the read-only main folder.
#
# Row format: "<name>|<kind>|<origin>"
#   kind    file | dir            what shared/<name> must be
#   origin  how shared/<name> comes into being on first run:
#           copy     recursive copy from the main folder
#           create   created empty (the source does not exist: ~/.claude/commands)
#           link     shared/<name> is itself an absolute symlink to the
#                    resolved target (skills -> the real shared skills dir,
#                    which Codex uses too; copying the link would produce a
#                    dangling one and silently lose every skill)
#           rewrite  copied with its content edited (settings.json's hook
#                    command must point at shared/hooks, never back into the
#                    read-only main folder)
#
# The order is the seed order, and it is part of the contract: Phase 3 seeds in
# it and Phase 2 links in it.
#
# Every account-side link is relative ("../shared/<name>"), so the whole root
# can be moved without rewriting a single link. Only shared/skills is absolute.
#
# Deliberately absent — these are NOT account-side links and must never be
# added here: plugin-cache (the target of CLAUDE_CODE_PLUGIN_CACHE_DIR, not a
# link), project-memory (per-slug links, one per project), plugins (its
# installLocation is checked lexically against the account's own config dir, so
# it cannot be shared), security/ (per-session state and pinned venv shebangs).
#
# NEVER hand-split a row. Consumers use shared_item_names, shared_item_kind,
# shared_item_origin and account_link_target; a consumer that iterated the raw
# rows as if they were names would create a link called
# "CLAUDE.md|file|copy" — a real defect caught in review before Phase 2 was
# implemented. shared_items exists for reporting the table, not for parsing it.
#
# A plain assignment, not `readonly` and not `+=`: re-sourcing must replace the
# table rather than append to it or abort. Fourteen rows would mean every link
# is created twice.
CLAUDE_MULTI_SHARED_ITEMS=(
  "CLAUDE.md|file|copy"
  "skills|dir|link"
  "agents|dir|copy"
  "hooks|dir|copy"
  "commands|dir|create"
  "agent-memory|dir|copy"
  "settings.json|file|rewrite"
)

# shared_items -> every raw row, one per line.   DATA PRODUCER
shared_items() {
  local row
  for row in "${CLAUDE_MULTI_SHARED_ITEMS[@]}"; do
    printf '%s\n' "$row"
  done
}

# shared_item_names -> the names, one per line, in seed order.   DATA PRODUCER
# This is what Phase 2 iterates; pair it with account_link_target.
shared_item_names() {
  local row
  for row in "${CLAUDE_MULTI_SHARED_ITEMS[@]}"; do
    printf '%s\n' "${row%%|*}"
  done
}

# _shared_item_row <name> -> the raw row for <name>, or 1 and nothing.
# Internal. Matches the name literally, so a near miss is a miss. An empty name
# is refused up front: "${row%%|*}" can never be empty, but relying on that
# would make the guard an accident of the table's content.
_shared_item_row() {
  local want="${1-}" row
  if [[ -z "$want" ]]; then
    return 1
  fi
  for row in "${CLAUDE_MULTI_SHARED_ITEMS[@]}"; do
    if [[ "${row%%|*}" == "$want" ]]; then
      printf '%s\n' "$row"
      return 0
    fi
  done
  return 1
}

# shared_item_kind <name> -> file | dir     DATA PRODUCER; 1 for an unknown name
shared_item_kind() {
  local row=""
  row="$(_shared_item_row "${1-}")" || return 1
  row="${row#*|}"
  printf '%s\n' "${row%%|*}"
}

# shared_item_origin <name> -> copy | create | link | rewrite
# DATA PRODUCER; returns 1 for an unknown name.
shared_item_origin() {
  local row=""
  row="$(_shared_item_row "${1-}")" || return 1
  printf '%s\n' "${row##*|}"
}

# account_link_target <name> -> the relative target of <account>/<name>.
# DATA PRODUCER; returns 1 for an unknown name.
#
# Independent of the managed root by design: the value is relative, so moving
# the root leaves every link intact. The membership check is what makes an
# unknown name an error instead of a plausible-looking "../shared/typo".
account_link_target() {
  local name="${1-}"
  _shared_item_row "$name" >/dev/null || return 1
  printf '%s\n' "../shared/$name"
}
