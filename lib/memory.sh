#!/usr/bin/env bash
# lib/memory.sh — project-slug encoding and worktree-slug filtering.
#
# This file is sourced by tests and later by the main command. The functions
# below are lexical and filesystem-free; callers receive data on stdout only
# from the data producer and no function emits status narration.

WORKTREE_SLUG_PATTERNS=(
  '*--claude-worktrees-*'
  '*-wt-*'
)

# slug_of_path <abs_path> -> slug
slug_of_path() {
  local p="${1:?slug_of_path: path required}"
  printf '%s\n' "${p//[!a-zA-Z0-9]/-}"
}

# is_worktree_slug <slug> -> 0 for an ephemeral worktree slug, 1 otherwise.
is_worktree_slug() {
  local slug="${1:?is_worktree_slug: slug required}" pat
  for pat in "${WORKTREE_SLUG_PATTERNS[@]}"; do
    # shellcheck disable=SC2053
    if [[ $slug == $pat ]]; then
      return 0
    fi
  done
  return 1
}
