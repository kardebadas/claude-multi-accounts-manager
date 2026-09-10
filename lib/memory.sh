#!/usr/bin/env bash
# lib/memory.sh — project-slug encoding, filtering, and reconstruction.
#
# This file is sourced by tests and later by the main command. The functions
# below emit data on stdout only from data producers. Reconstruction validates
# candidates against directories on disk; encoding and filtering are lexical.

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

# Literal alternatives to a separator for each lossy '-' in a slug.
MEMORY_LITERAL_CANDIDATES=('-' '.' '_' ' ')

# Bound the search; read the override anew for each decode call.
: "${MEMORY_DECODE_MAX_NODES:=20000}"

# Module-private search state; decode_slug is not reentrant.
_DECODE_RESULTS=()
_DECODE_COUNT=0
_DECODE_NODES=0
_DECODE_OVERFLOW=0
_DECODE_CAP=20000

# _decode_prefix_exists <dir> <prefix> -> whether an entry has this prefix.
# Quoting the prefix keeps its characters literal while '*' extends it.
_decode_prefix_exists() {
  local dir="$1" prefix="$2" e
  for e in "$dir"/"$prefix"*; do
    if [[ -e $e || -L $e ]]; then
      return 0
    fi
  done
  return 1
}

# _decode_walk <confirmed_dir> <component_so_far> <remaining_slug_chars>
# An empty confirmed_dir represents root. Results accumulate without output.
_decode_walk() {
  local dir="$1" comp="$2" rest="$3" ch lit

  _DECODE_NODES=$(( _DECODE_NODES + 1 ))
  if (( _DECODE_NODES > _DECODE_CAP )); then
    _DECODE_OVERFLOW=1
    return 0
  fi

  if [[ -z $rest ]]; then
    if [[ -n $comp && -d "$dir/$comp" ]]; then
      _DECODE_RESULTS+=("$dir/$comp")
      _DECODE_COUNT=$(( _DECODE_COUNT + 1 ))
    fi
    return 0
  fi

  ch="${rest:0:1}"
  rest="${rest:1}"
  if [[ $ch != '-' ]]; then
    _decode_walk "$dir" "$comp$ch" "$rest"
    return 0
  fi

  # A separator can descend only into an existing directory.
  if [[ -n $comp && -d "$dir/$comp" ]]; then
    _decode_walk "$dir/$comp" "" "$rest"
  fi

  # A literal character must match an existing entry's prefix.
  for lit in "${MEMORY_LITERAL_CANDIDATES[@]}"; do
    if _decode_prefix_exists "$dir" "$comp$lit"; then
      _decode_walk "$dir" "$comp$lit" "$rest"
    fi
  done
  return 0
}

# decode_slug <slug> -> the single existing absolute directory on stdout.
# 0 = unique match; 2 = none; 3 = ambiguous; 4 = search cap exceeded.
# Every nonzero exit writes zero bytes to stdout; diagnostics use stderr.
decode_slug() {
  local slug="${1:?decode_slug: slug required}"
  _DECODE_RESULTS=()
  _DECODE_COUNT=0
  _DECODE_NODES=0
  _DECODE_OVERFLOW=0
  _DECODE_CAP="${MEMORY_DECODE_MAX_NODES:-20000}"

  if [[ $slug != -* ]]; then
    return 2
  fi

  # The first '-' encodes the leading '/'.
  _decode_walk "" "" "${slug:1}"
  if (( _DECODE_OVERFLOW )); then
    warn "decode_slug: search cap ($_DECODE_CAP nodes) exceeded for $slug — skipping"
    return 4
  fi
  if (( _DECODE_COUNT == 0 )); then
    return 2
  fi
  if (( _DECODE_COUNT > 1 )); then
    warn "decode_slug: $slug is ambiguous ($_DECODE_COUNT candidates: ${_DECODE_RESULTS[*]}) — skipping"
    return 3
  fi
  printf '%s\n' "${_DECODE_RESULTS[0]}"
  return 0
}

# project_slugs <main_folder> -> one directory slug per stdout line.
project_slugs() {
  local main="${1:?project_slugs: main folder required}" d
  if [[ ! -d "$main/projects" ]]; then
    return 0
  fi
  for d in "$main"/projects/*/; do
    if [[ ! -d $d ]]; then
      continue
    fi
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done
}

# slug_is_eligible <slug> -> 0 when its memory may be shared, otherwise 1.
# This predicate returns only status; decoder diagnostics remain on stderr.
slug_is_eligible() {
  local slug="${1:?slug_is_eligible: slug required}"
  if is_worktree_slug "$slug"; then
    return 1
  fi
  if ! decode_slug "$slug" >/dev/null; then
    return 1
  fi
  return 0
}
