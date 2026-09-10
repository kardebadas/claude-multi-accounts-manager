#!/usr/bin/env bash
# Fixture main folder mirroring the real ~/.claude quirks:
#   1. skills        -> RELATIVE symlink to ../.codex-skills (target outside the folder)
#   2. commands/     -> ABSENT
#   3. settings.json -> hooks[].command is an absolute path into this folder
#   4. agent-memory/ -> has per-agent subdirectories
# Sourced by tests. Never touches the real HOME.

kind() {
  if   [[ -L "$1" ]]; then printf 'link'
  elif [[ -d "$1" ]]; then printf 'dir'
  elif [[ -f "$1" ]]; then printf 'file'
  else                     printf 'absent'
  fi
}

make_fixture_main() {
  local parent="$1" name="${2:-.claude}"
  local main="$parent/$name"

  mkdir -p "$main/agents" "$main/hooks" "$main/projects" \
           "$main/agent-memory/software-engineer" \
           "$main/agent-memory/brainstorm-architect"
  mkdir -p "$parent/.codex-skills/brainstorm" "$parent/.codex-skills/review"

  printf '# fixture global CLAUDE.md\n' > "$main/CLAUDE.md"
  printf 'agent: brainstorm-architect\n' > "$main/agents/brainstorm-architect.md"
  printf '#!/usr/bin/env bash\nprintf hook\n'  > "$main/hooks/post-commit-practices.sh"
  chmod 0755 "$main/hooks/post-commit-practices.sh"
  printf 'se note\n' > "$main/agent-memory/software-engineer/notes.md"
  printf 'ba note\n' > "$main/agent-memory/brainstorm-architect/notes.md"
  printf '# skill\n'  > "$parent/.codex-skills/brainstorm/SKILL.md"
  printf '{}\n' > "$main/.credentials.json"
  chmod 0600 "$main/.credentials.json"

  # Quirk 1 — relative link, exactly as the real folder has it.
  ln -sfn ../.codex-skills "$main/skills"

  # Quirk 2 — commands/ deliberately NOT created.

  # Quirk 3 — absolute hook path; plus autoMode, which must survive the rewrite.
  cat > "$main/settings.json" <<EOF
{
  "permissions": { "allow": [] },
  "model": "opus[1m]",
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "$main/hooks/post-commit-practices.sh"
          }
        ]
      }
    ]
  },
  "autoMode": { "environment": "work-profile" }
}
EOF

  printf '%s' "$main"
}

# Type, relative path, mode, mtime (ns), size, symlink target for every entry,
# then a content checksum for every regular file. Any write under $1 changes this.
snapshot_tree() {
  local root="$1"
  find "$root" -mindepth 0 -printf '%y|%P|%m|%T@|%s|%l\n' | LC_ALL=C sort
  find "$root" -type f -print0 | LC_ALL=C sort -z | xargs -0 -r md5sum
}
