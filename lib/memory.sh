#!/usr/bin/env bash
# lib/memory.sh — project-slug encoding, filtering, and reconstruction.
#
# This file is sourced by tests and later by the main command. The functions
# below emit data on stdout only from data producers. Reconstruction validates
# candidates against directories on disk; worktree filtering uses that decoded
# path so lossy slug punctuation cannot create false positives.
# Mutating account sync consumes links.sh's _resolve_managed_account_dir so its
# canonical name, root, and containment policy stays identical to link healing.

# slug_of_path <abs_path> -> slug
slug_of_path() {
  local p="${1:?slug_of_path: path required}"
  printf '%s\n' "${p//[!a-zA-Z0-9]/-}"
}

# _memory_path_is_worktree <decoded_path> -> exact component match only.
_memory_path_is_worktree() {
  local path="/${1#/}/"
  if [[ $path == */.claude/worktrees/* || $path == */wt/* ]]; then
    return 0
  fi
  return 1
}

# is_worktree_slug <slug> -> 0 for an ephemeral worktree slug, 1 otherwise.
# Predicate diagnostics stay silent; eligibility performs its own decode so it
# can preserve the decoder's ambiguity and search-cap warnings.
is_worktree_slug() {
  local slug="${1:?is_worktree_slug: slug required}" path
  if ! path="$(decode_slug "$slug" 2>/dev/null)"; then
    return 1
  fi
  _memory_path_is_worktree "$path"
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
  local slug="${1:?slug_is_eligible: slug required}" path
  if ! path="$(decode_slug "$slug")"; then
    return 1
  fi
  if _memory_path_is_worktree "$path"; then
    return 1
  fi
  return 0
}

# project_memory_store -> shared/project-memory under the active managed root.
# shared_dir follows multi_root on every call, including a caller-owned staging
# root used to assemble first-run state before one outer atomic publication.
project_memory_store() {
  printf '%s\n' "$(shared_dir)/project-memory"
}

# A memory link lives at <root>/<account>/projects/<slug>/memory. From its
# containing directory, the managed root is exactly three levels up.
MEMORY_LINK_UPLEVELS='../../../'

# memory_link_path <account> <slug> -> absolute account-side symlink path.
# account_dir owns active-root composition, including caller-owned staging.
memory_link_path() {
  local account="${1:?memory_link_path: account required}"
  local slug="${2:?memory_link_path: slug required}"
  printf '%s\n' "$(account_dir "$account")/projects/$slug/memory"
}

# memory_link_target <slug> -> relative target from the account project dir.
memory_link_target() {
  local slug="${1:?memory_link_target: slug required}"
  printf '%s\n' "${MEMORY_LINK_UPLEVELS}shared/project-memory/$slug"
}

# seed_project_memory <main_folder>
# Copy eligible existing project memories into the active root. This function
# composes within the caller's root (which may be a validated staging root); it
# never publishes or renames the managed root itself. Narration is stderr-only.
seed_project_memory() {
  local main="${1:?seed_project_memory: main folder required}"
  local dest src slug seeded=0
  local -a seeded_slugs=()
  dest="$(project_memory_store)"
  if ! mkdir -p "$dest"; then
    warn "project-memory: cannot create destination: $dest"
    return 1
  fi

  while IFS= read -r slug; do
    if [[ -z $slug ]]; then
      continue
    fi
    src="$main/projects/$slug/memory"
    if [[ ! -d $src ]]; then
      continue
    fi
    if [[ -e "$dest/$slug" ]]; then
      continue
    fi
    if ! slug_is_eligible "$slug"; then
      continue
    fi
    if ! mkdir -p "$dest/$slug"; then
      warn "project-memory: cannot create destination for $slug"
      return 1
    fi
    if ! cp -a "$src/." "$dest/$slug/"; then
      warn "project-memory: failed to copy $slug"
      return 1
    fi
    seeded_slugs+=("$slug")
    seeded=$((seeded + 1))
  done < <(project_slugs "$main")

  if (( seeded > 0 )); then
    for slug in ${seeded_slugs[@]+"${seeded_slugs[@]}"}; do
      log "project-memory: seeded $slug"
    done
    log "project-memory: seeded $seeded project memory folder(s)"
  fi
  return 0
}

# store_slugs -> one seeded slug per stdout line.
store_slugs() {
  local store d
  store="$(project_memory_store)"
  if [[ ! -d "$store" ]]; then
    return 0
  fi
  for d in "$store"/*/; do
    if [[ ! -d "$d" ]]; then
      continue
    fi
    d="${d%/}"
    printf '%s\n' "${d##*/}"
  done
}

# Validate every directory component before memory sync follows or creates it.
_memory_sync_paths_safe() {
  local account="$1" slug="${2:-}" root path resolved
  _resolve_managed_account_dir "$account" || return 1
  root="${_SAFE_ACCOUNT_DIR%/*}"
  if [[ ! -d "$root/shared" ]]; then
    warn "project-memory: shared directory is missing"
    return 1
  fi
  local -a paths=("$root/shared" "$root/shared/project-memory" "$_SAFE_ACCOUNT_DIR/projects")
  if [[ -n "$slug" ]]; then
    if [[ "$slug" == */* || "$slug" == . || "$slug" == .. ]]; then
      warn "project-memory: invalid project slug"
      return 1
    fi
    paths+=("$_SAFE_ACCOUNT_DIR/projects/$slug" "$root/shared/project-memory/$slug")
  fi
  for path in "${paths[@]}"; do
    if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
      warn "project-memory: refusing non-directory or symlinked path: $path"
      return 1
    fi
    if ! resolved="$(readlink -m -- "$path")" || [[ "$resolved" != "$path" ]]; then
      warn "project-memory: path escapes its managed directory: $path"
      return 1
    fi
  done
  return 0
}

# sync_project_memory <account>
# Enroll eligible account projects, then repair links to the shared store.
# Zero bytes on stdout; unsafe paths are refused without exiting the caller.
sync_project_memory() {
  local account="${1:?sync_project_memory: account required}"
  local account_path store path slug link link_status linked=0
  _memory_sync_paths_safe "$account" || return 1
  account_path="$_SAFE_ACCOUNT_DIR"
  store="${account_path%/*}/shared/project-memory"
  if ! mkdir -p -- "$store"; then
    warn "project-memory: cannot create shared store"
    return 1
  fi
  _memory_sync_paths_safe "$account" || return 1

  for path in "$account_path/projects"/*; do
    if [[ ! -e "$path" && ! -L "$path" ]]; then continue; fi
    slug="${path##*/}"
    _memory_sync_paths_safe "$account" "$slug" || return 1
    if [[ -d "$store/$slug" ]] || ! slug_is_eligible "$slug"; then continue; fi
    _memory_sync_paths_safe "$account" "$slug" || return 1
    if [[ -d "$store/$slug" ]]; then continue; fi
    link="$path/memory"
    if [[ -d "$link" && ! -L "$link" ]]; then
      # Preserve the physical directory without merging competing memories.
      if ! mv -nT -- "$link" "$store/$slug" || \
         [[ -e "$link" || -L "$link" || ! -d "$store/$slug" || -L "$store/$slug" ]]; then
        warn "project-memory: could not enroll existing memory for $account/$slug"
        return 1
      fi
    elif ! mkdir -- "$store/$slug"; then
      warn "project-memory: could not enroll empty memory for $account/$slug"
      return 1
    fi
    log "project-memory: enrolled $account/$slug"
  done

  for path in "$store"/*; do
    if [[ ! -e "$path" && ! -L "$path" ]]; then continue; fi
    slug="${path##*/}"
    if _memory_link_sync_one "$account" "$slug"; then
      linked=$((linked + 1))
    else
      link_status=$?
      if (( link_status != 1 )); then
        warn "sync_project_memory: refused unsafe relink for $account/$slug"
        return 1
      fi
    fi
  done

  if (( linked > 0 )); then
    log "project-memory: $account — $linked link(s) created or repaired"
  fi
  return 0
}

# _memory_link_sync_one <account> <slug>
# 0 = created or repaired (and narrated), 1 = already correct (silent),
# 2 = refused because a safe, lossless repair could not be established.
# Zero bytes on stdout in every branch.
_memory_link_sync_one() {
  local account="$1" slug="$2" label="$1/$2" link target
  local parent target_path old_target replacement backup
  _memory_sync_paths_safe "$account" "$slug" || return 2
  parent="$_SAFE_ACCOUNT_DIR/projects/$slug"
  link="$parent/memory"
  target="$(memory_link_target "$slug")"
  if ! mkdir -p "$parent"; then
    warn "project-memory: unable to prepare link directory for $label"
    return 2
  fi
  _memory_sync_paths_safe "$account" "$slug" || return 2
  target_path="${_SAFE_ACCOUNT_DIR%/*}/shared/project-memory/$slug"
  if [[ ! -d "$target_path" ]]; then
    warn "project-memory: store target is not an existing directory for $label"
    return 2
  fi

  if [[ -L "$link" ]]; then
    old_target="$(readlink "$link")"
    if [[ "$old_target" == "$target" && -d "$link" ]]; then
      return 1
    fi
    replacement="$link.relink-$$"
    while [[ -e "$replacement" || -L "$replacement" ]]; do
      replacement="$replacement.1"
    done
    if ! ln -s "$target" "$replacement"; then
      warn "project-memory: unable to prepare replacement link for $label"
      return 2
    fi
    if ! mv -fT "$replacement" "$link"; then
      rm -f "$replacement"
      warn "project-memory: unable to repoint $label; previous link retained"
      return 2
    fi
    warn "project-memory: repointed $label"
    return 0
  fi

  if [[ -e "$link" ]]; then
    backup="$link.backup-$(date -u +%Y%m%dT%H%M%SZ)"
    while :; do
      while [[ -e "$backup" || -L "$backup" ]]; do
        backup="$backup.1"
      done
      if ! mv -nT "$link" "$backup"; then
        warn "project-memory: unable to back up existing $label; refusing relink"
        return 2
      fi
      if [[ ! -e "$link" && ! -L "$link" ]]; then
        break
      fi
      backup="$backup.1"
    done

    if ! ln -s "$target" "$link"; then
      if mv -T "$backup" "$link"; then
        warn "project-memory: relink failed for $label; restored existing content"
      else
        warn "project-memory: relink failed for $label; content preserved at ${backup##*/}"
      fi
      return 2
    fi
    warn "project-memory: backed up existing $label to ${backup##*/}"
    log "project-memory: linked $label"
    return 0
  fi

  if ! ln -s "$target" "$link"; then
    warn "project-memory: unable to link $label"
    return 2
  fi
  log "project-memory: linked $label"
  return 0
}
