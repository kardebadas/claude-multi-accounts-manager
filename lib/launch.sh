#!/usr/bin/env bash
# lib/launch.sh — repair an account, then replace this process with Claude.

# _account_launch_paths_safe <account>
# Safe repair failures may leave local memory intact; redirected private state
# and unexpected memory links must never reach Claude.
_account_launch_paths_safe() {
  local account="$1" acct projects path target resolved slug store
  _resolve_managed_account_dir "$account" || return 1
  acct="$_SAFE_ACCOUNT_DIR"
  for path in "$acct"/* "$acct"/.[!.]* "$acct"/..?*; do
    if [[ ! -L "$path" ]]; then continue; fi
    if ! target="$(account_link_target "${path##*/}")" || \
       [[ "$(readlink -- "$path")" != "$target" ]]; then
      warn "refusing launch through an unexpected account symlink: $path"
      return 1
    fi
  done

  projects="$acct/projects"
  if ! resolved="$(readlink -m -- "$projects")" || [[ "$resolved" != "$projects" ]]; then
    warn "refusing launch through an unsafe projects path: $projects"
    return 1
  fi
  if [[ ! -d "$projects" ]]; then return 0; fi
  for path in "$projects"/* "$projects"/.[!.]* "$projects"/..?*; do
    if [[ ! -e "$path" && ! -L "$path" ]]; then continue; fi
    if [[ -L "$path" ]] || ! resolved="$(readlink -m -- "$path")" || \
       [[ "$resolved" != "$path" ]]; then
      warn "refusing launch through an unsafe project directory: $path"
      return 1
    fi
    if [[ ! -d "$path" || ! -L "$path/memory" ]]; then continue; fi
    slug="${path##*/}"
    target="$(memory_link_target "$slug")"
    store="${acct%/*}/shared/project-memory/$slug"
    if [[ "$(readlink -- "$path/memory")" != "$target" ]] || \
       ! _memory_sync_paths_safe "$account" "$slug" || [[ ! -d "$store" ]] || \
       ! resolved="$(readlink -e -- "$path/memory")" || [[ "$resolved" != "$store" ]]; then
      warn "refusing launch through an unsafe project memory link: $path/memory"
      return 1
    fi
  done
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
