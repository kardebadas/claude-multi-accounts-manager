#!/usr/bin/env bash
# lib/seed.sh — first-run seeding of shared/ from the read-only main folder.
# Sourced by bin/claude-multi. Requires lib/util.sh (log/warn/die),
# lib/config.sh (multi_root), and lib/links.sh (link_create). Writes nothing
# outside the shared dir.

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
    mkdir -p "$shared/skills"
    cp -a "$src/." "$shared/skills/"
    log "seeded skills/ (source is a real directory)"
    return 0
  fi

  log "skipped skills (absent in $main)"
  return 0
}

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

  seed_skills_link "$main" "$shared" || return 1

  if [[ -f "$main/settings.json" ]]; then
    rewrite_hook_paths "$main/settings.json" "$shared/settings.json" "$main" "$shared" || return 1
    log "seeded settings.json (hook paths rewritten into $shared/hooks)"
  else
    log "skipped settings.json (absent in $main)"
  fi

  return 0
}

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

  mv "$tmp" "$dst"
  return 0
}
