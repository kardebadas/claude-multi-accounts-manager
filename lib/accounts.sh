#!/usr/bin/env bash
# lib/accounts.sh — list, add and delete managed Claude accounts.
# Sourced by bin/claude-multi after util.sh, config.sh, links.sh, seed.sh,
# memory.sh. Never executed directly, so it sets no shell options.
#
# stdout discipline: only list_accounts, account_status and archive_account
# write to stdout, and only machine-readable data. Everything human goes to
# stderr via log/warn.

# list_accounts — one account name per line. No output if there are none.
#
# ORDER IS A GUARANTEE, NOT A CONVENIENCE: byte-wise ascending under LC_ALL=C,
# identical on every locale and every filesystem. Phase 6's menu numbers the
# accounts by their position in this list and `d) delete` acts on the number the
# user typed, so an order that shifts between two runs deletes the wrong
# account. Glob expansion is sorted by LC_COLLATE (a locale where '-' collates
# differently reorders `personal-mother` against `personalx`), and readdir order
# is filesystem-defined, so neither is trusted: the names go through
# `LC_ALL=C sort` before they are printed.
list_accounts() {
  local root path base
  root="$(multi_root)"
  if [[ ! -d "$root" ]]; then
    return 0
  fi
  for path in "$root"/*; do
    if [[ ! -d "$path" ]]; then continue; fi
    base="${path##*/}"
    if [[ "$base" == .* ]]; then continue; fi
    if is_reserved_name "$base"; then continue; fi
    printf '%s\n' "$base"
  done | LC_ALL=C sort
}

# account_status — the credential dot. A20: existence test ONLY. This file is
# never read, parsed, copied or deleted, here or anywhere else.
account_status() {
  local name="$1" acct
  acct="$(multi_root)/$name"
  if [[ -s "$acct/.credentials.json" ]]; then
    printf 'logged-in\n'
  else
    printf 'no-credentials\n'
  fi
}

# add_account — A12 validation, A31 stub, all shared links, then memory sync.
# Link creation is delegated to heal_account (the launch/sync repair path, not
# the report-only doctor path, A35) so the shared-item table has one consumer.
add_account() {
  local raw="${1:-}" name acct
  if ! validate_name "$raw"; then
    return 1
  fi
  # validate_name owns lowercasing and delegates reserved-name rejection to
  # is_reserved_name, then returns the one canonical spelling through this
  # stdout-safe variable.
  name="$CANONICAL_NAME"
  acct="$(account_dir "$name")"
  if [[ -e "$acct" || -L "$acct" ]]; then
    log "account '$name' already exists at $acct"
    return 1
  fi

  mkdir -p "$acct"
  chmod 700 "$acct"

  if ! heal_account "$name"; then
    warn "some shared links for '$name' could not be created; run sync after fixing shared/"
  fi

  printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{}}' > "$acct/.claude.json"
  chmod 600 "$acct/.claude.json"

  if ! sync_project_memory "$name"; then
    warn "project-memory sync for '$name' did not complete; run sync from the menu"
  fi

  log "created account '$name' at $acct"
}

# offer_launch — A17. Returns a decision; the caller (menu) does the exec.
# rc 0 = the user wants to launch now. CLAUDE_MULTI_NO_LAUNCH=1 suppresses the
# prompt entirely, which is how the test suite and any non-interactive caller
# drive the add path.
offer_launch() {
  local name="${1:?offer_launch needs an account name}" reply
  if [[ -n "${CLAUDE_MULTI_NO_LAUNCH:-}" ]]; then
    log "not launching; run: claude-multi $name"
    return 1
  fi
  printf "launch claude in '%s' now to log in? [Y/n] " "$name" >&2
  if ! IFS= read -r reply; then
    printf '\n' >&2
    log "no answer; not launching. run: claude-multi $name"
    return 1
  fi
  case "$reply" in
    ''|y|Y|yes|Yes|YES) return 0 ;;
    *) log "not launching; run: claude-multi $name"; return 1 ;;
  esac
}
