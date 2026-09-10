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
