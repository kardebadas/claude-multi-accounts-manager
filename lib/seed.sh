#!/usr/bin/env bash
# lib/seed.sh — first-run seeding of shared/ from the read-only main folder.
# Sourced by bin/claude-multi. Requires lib/util.sh (log/warn/die),
# lib/config.sh (multi_root), and lib/links.sh (link_create). A new destination
# is assembled in a validated sibling staging directory and published at once.

# A directory is a Claude config folder if it holds one of these.
CLAUDE_MARKERS=("settings.json" "CLAUDE.md")

validate_main_folder() {
  local path="${1-}"

  if [[ -z "$path" ]]; then
    warn "main folder: no path given"
    return 1
  fi
  if [[ "$path" != /* ]]; then
    warn "main folder must be an absolute path: $path"
    return 1
  fi
  if [[ ! -d "$path" ]]; then
    warn "main folder does not exist or is not a directory: $path"
    return 1
  fi

  local canon root root_canon
  canon=$(readlink -f "$path") || { warn "cannot resolve main folder: $path"; return 1; }
  root=$(multi_root)
  root_canon=$(readlink -f "$root" 2>/dev/null || printf '%s' "$root")
  if [[ "$canon" == "$root_canon" ]]; then
    warn "main folder must not be the claude-multi root itself: $path"
    return 1
  fi

  local marker
  for marker in "${CLAUDE_MARKERS[@]}"; do
    [[ -e "$path/$marker" ]] && return 0
  done
  warn "not a Claude config folder (no settings.json or CLAUDE.md): $path"
  return 1
}

# Directories copied verbatim from the main folder into shared/.
# `skills` and `commands` are NOT in this list — they need special handling.
SEED_COPY_DIRS=("agents" "hooks" "agent-memory")

# shared/skills must point at the RESOLVED target of the source link.
# Copying the link is the silent-data-loss failure mode: ~/.claude/skills is
# `../.codex-skills`, which inside shared/ resolves to a path that does not exist.
seed_skills_link() {
  local main="$1" shared="$2"
  local src="$main/skills" target

  if [[ -L "$src" ]]; then
    target=$(readlink -f "$src" 2>/dev/null || true)
    if [[ -z "$target" || ! -d "$target" ]]; then
      warn "skills: source link is dangling ($src -> $(readlink "$src")); shared/skills not created"
      return 0
    fi
    link_create "$shared/skills" "$target" abs || return 1
    log "linked skills -> $target (resolved from the source symlink)"
    return 0
  fi

  if [[ -d "$src" ]]; then
    if ! mkdir -p "$shared/skills" || ! cp -a "$src/." "$shared/skills/"; then
      warn "skills: failed to copy source directory ($src)"
      return 1
    fi
    log "seeded skills/ (source is a real directory)"
    return 0
  fi

  log "skipped skills (absent in $main)"
  return 0
}

# A cleanup path is eligible only when it is the real directory created by our
# exact mktemp template in the expected parent. This prevents a failure handler
# from widening a removal to an unrelated lookalike path.
_seed_stage_is_valid() {
  local stage="$1" parent="$2" prefix="$3"
  local stage_parent stage_base stage_suffix stage_canon

  [[ "$stage" == /* && "$parent" == /* ]] || return 1
  [[ -d "$stage" && ! -L "$stage" ]] || return 1
  stage_parent=$(dirname -- "$stage") || return 1
  [[ "$stage_parent" == "$parent" ]] || return 1
  stage_base=${stage##*/}
  [[ "$stage_base" == "$prefix"* ]] || return 1
  stage_suffix=${stage_base#"$prefix"}
  [[ "$stage_suffix" =~ ^[[:alnum:]]{8}$ ]] || return 1
  stage_canon=$(readlink -f "$stage") || return 1
  [[ "$stage_canon" == "$stage" ]]
}

_seed_cleanup_stage() {
  local stage="$1" parent="$2" prefix="$3"
  [[ -n "$stage" ]] || return 0
  if ! _seed_stage_is_valid "$stage" "$parent" "$prefix"; then
    warn "refusing to clean an unvalidated seed staging path: $stage"
    return 1
  fi
  rm -rf -- "$stage"
}

# Return success when either path is equal to or contains the other.
_seed_paths_overlap() {
  local left="${1%/}" right="${2%/}"
  [[ "$left" == "$right" || "$left" == "$right/"* || "$right" == "$left/"* ]]
}

seed_shared() (
  local main="${1-}"
  local requested_shared="${2:-$(multi_root)/shared}"
  local main_canon shared root root_canon skills_canon
  local publish_target publish_parent publish_base stage_suffix stage_prefix
  local stage_template stage build_shared

  validate_main_folder "$main" || return 1

  if [[ "$requested_shared" != /* ]]; then
    warn "shared destination must be an absolute path: $requested_shared"
    return 1
  fi

  main_canon=$(readlink -f "$main") || {
    warn "cannot resolve main folder: $main"
    return 1
  }
  shared=$(readlink -m -- "$requested_shared") || {
    warn "cannot resolve shared destination: $requested_shared"
    return 1
  }

  # Containment is rejected before the A38 existence guard or any filesystem
  # write. The resolved external skills source is protected as source data too.
  if _seed_paths_overlap "$main_canon" "$shared"; then
    warn "source and shared destination overlap: $main_canon <-> $shared"
    return 1
  fi
  if [[ -L "$main/skills" ]]; then
    skills_canon=$(readlink -f "$main/skills" 2>/dev/null || true)
    if [[ -n "$skills_canon" ]] && _seed_paths_overlap "$skills_canon" "$shared"; then
      warn "resolved skills source and shared destination overlap: $skills_canon <-> $shared"
      return 1
    fi
  fi

  # A38: first-run seeding never updates an existing live destination. For the
  # canonical live location, even an otherwise empty multi-root is live state.
  if [[ -e "$requested_shared" || -L "$requested_shared" || -e "$shared" || -L "$shared" ]]; then
    warn "shared/ is already seeded: $shared (refusing to re-seed)"
    return 1
  fi
  root=$(multi_root)
  root_canon=$(readlink -m -- "$root") || {
    warn "cannot resolve claude-multi root: $root"
    return 1
  }
  if [[ "$shared" == "$root_canon/shared" && ( -e "$root" || -L "$root" || -e "$root_canon" || -L "$root_canon" ) ]]; then
    warn "shared/ is already seeded: $shared (live root exists; refusing to re-seed)"
    return 1
  fi

  # Publish the highest missing ancestor. On the normal first run this is the
  # complete multi-root; inside a caller-owned P6 root stage it is shared/.
  publish_target="$shared"
  stage_suffix=""
  while :; do
    publish_parent=$(dirname -- "$publish_target") || return 1
    if [[ -d "$publish_parent" ]]; then
      break
    fi
    if [[ -e "$publish_parent" || -L "$publish_parent" ]]; then
      warn "shared destination parent is not a directory: $publish_parent"
      return 1
    fi
    stage_suffix="/${publish_target##*/}$stage_suffix"
    publish_target="$publish_parent"
  done

  publish_base=${publish_target##*/}
  stage_prefix=".${publish_base}.seed."
  if [[ "$publish_parent" == "/" ]]; then
    stage_template="/$stage_prefix"'XXXXXXXX'
  else
    stage_template="$publish_parent/$stage_prefix"'XXXXXXXX'
  fi
  if ! stage=$(mktemp -d "$stage_template"); then
    warn "cannot create seed staging directory beside $publish_target"
    return 1
  fi
  if ! _seed_stage_is_valid "$stage" "$publish_parent" "$stage_prefix"; then
    # Validation has not authorized recursive cleanup. rmdir targets only the
    # exact empty directory returned by mktemp and cannot traverse a replacement.
    rmdir -- "$stage" 2>/dev/null || true
    warn "created seed staging directory failed validation: $stage"
    return 1
  fi
  trap 'seed_status=$?; trap - EXIT INT TERM; _seed_cleanup_stage "$stage" "$publish_parent" "$stage_prefix" || :; exit "$seed_status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  build_shared="$stage$stage_suffix"
  if ! mkdir -p "$build_shared" "$build_shared/commands" "$build_shared/plugin-cache"; then
    warn "cannot create staged shared directories: $build_shared"
    return 1
  fi

  if [[ -f "$main/CLAUDE.md" ]]; then
    if ! cp -p "$main/CLAUDE.md" "$build_shared/CLAUDE.md"; then
      warn "failed to seed CLAUDE.md"
      return 1
    fi
    log "seeded CLAUDE.md"
  else
    log "skipped CLAUDE.md (absent in $main)"
  fi

  local d
  for d in "${SEED_COPY_DIRS[@]}"; do
    if [[ -d "$main/$d" ]]; then
      if ! mkdir -p "$build_shared/$d"; then
        warn "failed to create staged $d/"
        return 1
      fi
      # "$src/." copies the CONTENTS, so a re-run does not nest src inside dst.
      if ! cp -a "$main/$d/." "$build_shared/$d/"; then
        warn "failed to seed $d/"
        return 1
      fi
      log "seeded $d/"
    else
      log "skipped $d/ (absent in $main)"
    fi
  done

  # Verified fact: the real ~/.claude has NO commands/ dir. Created empty above,
  # so an absent source is a no-op instead of a `set -e` abort.
  if [[ -d "$main/commands" ]]; then
    if ! cp -a "$main/commands/." "$build_shared/commands/"; then
      warn "failed to seed commands/"
      return 1
    fi
    log "seeded commands/"
  else
    log "created commands/ empty (absent in $main)"
  fi

  seed_skills_link "$main" "$build_shared" || return 1

  if [[ -f "$main/settings.json" ]]; then
    rewrite_hook_paths "$main/settings.json" "$build_shared/settings.json" "$main" "$shared" || return 1
    log "seeded settings.json (hook paths rewritten into $shared/hooks)"
  else
    log "skipped settings.json (absent in $main)"
  fi

  # Destination was validated absent before staging; check again immediately
  # before the sole target-exposing operation.
  if [[ -e "$publish_target" || -L "$publish_target" ]]; then
    warn "seed destination appeared before publication: $publish_target"
    return 1
  fi
  if ! mv -T --no-clobber -- "$stage" "$publish_target" || \
     [[ -e "$stage" || -L "$stage" || ! -d "$publish_target" || -L "$publish_target" ]]; then
    warn "failed to publish staged seed root: $publish_target"
    return 1
  fi
  stage=""
  trap - EXIT INT TERM
  return 0
)

# Copy settings.json, rewriting every "<main>/hooks/" prefix to "<shared>/hooks/".
# jq is NOT an allowed dependency, so this is a pure text transform. awk does
# literal index()/substr() replacement — no regex, so paths containing spaces,
# dots, brackets or other metacharacters need no escaping. Values arrive through
# ENVIRON rather than -v, because -v applies backslash-escape processing.
rewrite_hook_paths() {
  local src="$1" dst="$2" main="$3" shared="$4"
  local from="${main%/}/hooks/" to="${shared%/}/hooks/"
  local tmp="$dst.tmp.$$"

  if ! SEED_FROM="$from" SEED_TO="$to" awk '
    BEGIN { from = ENVIRON["SEED_FROM"]; to = ENVIRON["SEED_TO"] }
    {
      line = $0; out = ""
      while ((p = index(line, from)) > 0) {
        out = out substr(line, 1, p - 1) to
        line = substr(line, p + length(from))
      }
      print out line
    }
  ' "$src" > "$tmp"; then
    rm -f "$tmp"
    warn "settings.json: hook path rewrite failed ($src)"
    return 1
  fi

  # Anything still pointing into the main folder would be executed from the
  # read-only source. Report it loudly; it is a config shape we have not seen.
  if grep -qF "${main%/}/" "$tmp"; then
    warn "settings.json: still references the main folder after rewrite: ${main%/}"
  fi

  if ! mv -- "$tmp" "$dst"; then
    rm -f "$tmp"
    warn "settings.json: failed to publish rewritten file ($dst)"
    return 1
  fi
  return 0
}
