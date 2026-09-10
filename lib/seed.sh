#!/usr/bin/env bash
# lib/seed.sh — first-run seeding of shared/ from the read-only main folder.
# Sourced by bin/claude-multi. Requires lib/util.sh (log/warn/die) and
# lib/config.sh (multi_root). Writes nothing outside the shared dir.

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

seed_shared() {
  local main="${1-}"
  local shared="${2:-$(multi_root)/shared}"

  validate_main_folder "$main" || return 1

  mkdir -p "$shared" "$shared/commands" "$shared/plugin-cache"

  if [[ -f "$main/CLAUDE.md" ]]; then
    cp -p "$main/CLAUDE.md" "$shared/CLAUDE.md"
    log "seeded CLAUDE.md"
  else
    log "skipped CLAUDE.md (absent in $main)"
  fi

  local d
  for d in "${SEED_COPY_DIRS[@]}"; do
    if [[ -d "$main/$d" ]]; then
      mkdir -p "$shared/$d"
      # "$src/." copies the CONTENTS, so a re-run does not nest src inside dst.
      cp -a "$main/$d/." "$shared/$d/"
      log "seeded $d/"
    else
      log "skipped $d/ (absent in $main)"
    fi
  done

  # Verified fact: the real ~/.claude has NO commands/ dir. Created empty above,
  # so an absent source is a no-op instead of a `set -e` abort.
  if [[ -d "$main/commands" ]]; then
    cp -a "$main/commands/." "$shared/commands/"
    log "seeded commands/"
  else
    log "created commands/ empty (absent in $main)"
  fi

  return 0
}
