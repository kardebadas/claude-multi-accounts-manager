#!/usr/bin/env bash
# lib/launch.sh — repair an account, then replace this process with Claude.

# _account_launch_paths_safe <account>
# Safe repair failures may leave local memory intact; redirected private state
# and unexpected memory links must never reach Claude.
_account_launch_paths_safe() {
  local account="$1" acct path relative target actual resolved slug store
  _resolve_managed_account_dir "$account" || return 1
  acct="$_SAFE_ACCOUNT_DIR"
  # Do not follow allowed shared links; their tree is checked separately once.
  while IFS= read -r -d '' path; do
    if [[ -z "$path" ]] || ! IFS= read -r -d '' actual < <(readlink -z -- "$path"); then
      warn "cannot establish safe account symlink targets"
      return 1
    fi
    relative="${path#"$acct"/}"
    if [[ "$relative" != */* ]] && \
       target="$(account_link_target "$relative")" && [[ "$actual" == "$target" ]]; then
      continue
    fi
    if [[ "$relative" == projects/*/memory ]]; then
      slug="${relative#projects/}"
      slug="${slug%/memory}"
      if [[ -n "$slug" && "$slug" != */* ]]; then
        target="$(memory_link_target "$slug")"
        store="${acct%/*}/shared/project-memory/$slug"
        if [[ "$actual" == "$target" ]] && \
           _memory_sync_paths_safe "$account" "$slug" && [[ -d "$store" ]] && \
           resolved="$(readlink -e -- "$path")" && [[ "$resolved" == "$store" ]]; then
          continue
        fi
      fi
    fi
    warn "refusing launch through an unexpected account symlink: $path"
    return 1
  done < <(find -P "$acct" -type l -print0 || printf '\0')
  return 0
}

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
  _account_launch_paths_safe "$name" || return 1
  _shared_symlink_targets_safe "${_SAFE_ACCOUNT_DIR%/*}/shared" || return 1

  log "launching claude in '$name'"
  exec env CLAUDE_CONFIG_DIR="$acct" \
           CLAUDE_CODE_PLUGIN_CACHE_DIR="$root/shared/plugin-cache" \
           claude "$@"
}
