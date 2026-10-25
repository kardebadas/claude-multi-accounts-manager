#!/usr/bin/env bash
# lib/launch.sh — repair an account, then replace this process with Claude.

# launch_account <name> [claude-args...]
# On success this does not return: exec preserves Claude's streams and status.
launch_account() {
  local raw="${1:-}" name root acct
  if ! validate_name "$raw"; then
    return 1
  fi
  name="$CANONICAL_NAME"
  shift

  root="$(multi_root)"
  acct="$root/$name"
  if [[ ! -d "$acct" || -L "$acct" ]]; then
    die "unknown account: '$name' (run claude-multi with no arguments to see the list)"
  fi

  _resolve_managed_account_dir "$name" || return 1

  if ! heal_account "$name"; then
    warn "some shared links for '$name' could not be repaired; launching anyway"
  fi
  if ! sync_project_memory "$name"; then
    warn "project memory for '$name' could not be synchronized; launching anyway"
  fi
  _resolve_managed_account_dir "$name" || return 1

  log "launching claude in '$name'"
  exec env CLAUDE_CONFIG_DIR="$acct" \
           CLAUDE_CODE_PLUGIN_CACHE_DIR="$root/shared/plugin-cache" \
           claude "$@"
}
