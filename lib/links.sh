# shellcheck shell=bash
# lib/links.sh — per-account symlink creation, verification and repair.
#
# Sourced by bin/claude-multi as "$CLAUDE_MULTI_LIB/links.sh". No shebang, not
# executable, and deliberately no `set -euo pipefail` (it would leak into the
# caller).
#
# Consumes from lib/util.sh:   log warn
# Consumes from lib/config.sh: multi_root is_reserved_name shared_item_names
#                              account_link_target
#
# stdout discipline (see the plan's channel table — do not "fix" this):
#   DATA PRODUCERS, stdout is their return value, always read via $( ) / < <( ):
#     expected_links, link_verify
#   STATUS ONLY, print nothing at all:
#     path_has_content
#   FLOW, stdout byte-empty, narration to stderr via log/warn:
#     link_create, link_repair, heal_account, doctor_report

# expected_links <account>
# DATA PRODUCER. One TAB-separated row per expected per-account link:
#   <absolute link path>\t<expected link text>
# Order follows the shared-item table's seed order.
#
# Note it iterates shared_item_names (bare names) and takes the link text from
# account_link_target. It must NEVER iterate shared_items, whose rows are
# "<name>|<kind>|<origin>" — a name parsed out of a raw row is not a name.
expected_links() {
  local account="$1" item target
  local root
  root="$(multi_root)"
  while IFS= read -r item; do
    if [[ -z "$item" ]]; then continue; fi
    target="$(account_link_target "$item")"
    printf '%s\t%s\n' "$root/$account/$item" "$target"
  done < <(shared_item_names)
}

# link_create <link-path> <target> [rel|abs]
# FLOW. `rel` (default): <target> is the relative link text, e.g. ../shared/agents.
#       `abs`:           <target> must be absolute; used verbatim as the link text.
# Refuses a real (non-symlink) path — link_repair backs that up first.
# Validation happens BEFORE any filesystem call, so a rejected call creates
# nothing at all.
link_create() {
  local path="$1" target="$2" kind="${3:-rel}"
  case "$kind" in
    rel) ;;
    abs)
      if [[ "$target" != /* ]]; then
        warn "link_create: abs link needs an absolute target: $target"
        return 1
      fi
      ;;
    *)
      warn "link_create: unknown link kind: $kind"
      return 1
      ;;
  esac
  if [[ -e "$path" && ! -L "$path" ]]; then
    warn "link_create: refusing to overwrite a real path: $path"
    return 1
  fi
  mkdir -p "$(dirname "$path")"
  ln -sfn "$target" "$path"
}

# link_verify <path> <expected-target>
# DATA PRODUCER. Prints one status word to stdout:
#   ok | missing | wrong-target | real-file | dangling
# Always returns 0 — the word is the answer. NEVER redirect these printfs to
# stderr: they are this function's return value.
#
# The -L test comes first: `-e` follows a symlink, so a healthy link would
# otherwise be misread as a real file.
link_verify() {
  local path="$1" expected="$2" actual
  if [[ -L "$path" ]]; then
    actual="$(readlink "$path")"
    if [[ "$actual" != "$expected" ]]; then
      printf 'wrong-target\n'
    elif [[ -e "$path" ]]; then
      printf 'ok\n'
    else
      printf 'dangling\n'
    fi
  elif [[ -e "$path" ]]; then
    printf 'real-file\n'
  else
    printf 'missing\n'
  fi
}

# path_has_content <path>
# STATUS ONLY — prints nothing on either channel.
# 0 for a non-empty regular file or a non-empty directory (dotfiles count),
# 1 for an empty file or an empty directory. No shopt, no external commands.
path_has_content() {
  local path="$1" entry
  if [[ -d "$path" ]]; then
    for entry in "$path"/* "$path"/.[!.]* "$path"/..?*; do
      if [[ -e "$entry" || -L "$entry" ]]; then
        return 0
      fi
    done
    return 1
  fi
  [[ -s "$path" ]]
}

# link_repair <path> <target> <status> [rel|abs]
# FLOW. Acts on a status word from link_verify. 0 = the path is now correct,
# 1 = it cannot be repaired here. Narration to stderr only; never exits.
link_repair() {
  local path="$1" target="$2" status="$3" kind="${4:-rel}"
  case "$status" in
    ok)
      return 0
      ;;
    missing)
      link_create "$path" "$target" "$kind" || return 1
      warn "created link: $path -> $target"
      ;;
    wrong-target)
      link_create "$path" "$target" "$kind" || return 1
      warn "repaired link: $path -> $target"
      ;;
    real-file)
      local stamp backup
      if path_has_content "$path"; then
        stamp="$(date -u +%Y%m%dT%H%M%SZ)"
        backup="$path.bak.$stamp"
        mv "$path" "$backup" || { warn "cannot back up $path — leaving it in place"; return 1; }
        warn "backed up real path before relinking: $path -> $backup"
      elif [[ -d "$path" ]]; then
        rmdir "$path"          # only ever succeeds on an empty directory
      else
        rm -f "$path"
      fi
      link_create "$path" "$target" "$kind" || return 1
      warn "replaced real path with link: $path -> $target"
      ;;
    dangling)
      # The link text is right; the target is gone. Relinking would change
      # nothing and creating the target would fabricate config that was lost.
      # Report loudly and let seeding fix the shared side.
      warn "dangling link: $path -> $(readlink "$path") (target missing; re-seed shared/)"
      return 1
      ;;
    *)
      warn "link_repair: unknown status '$status' for $path"
      return 1
      ;;
  esac
  return 0
}

# heal_account <account>
# FLOW. Verify + repair every expected link for one account. Narrates only
# changes, to stderr; stdout stays byte-empty. 0 = everything is ok now,
# 1 = at least one item is unrepairable. One bad item never aborts the pass.
#
# link_verify is read through $( ) — that is its return channel, and this is
# the call site that breaks silently if anyone redirects it to stderr.
heal_account() {
  local account="$1" path target status rc=0
  while IFS=$'\t' read -r path target; do
    status="$(link_verify "$path" "$target")"
    if [[ "$status" == "ok" ]]; then
      continue
    fi
    if ! link_repair "$path" "$target" "$status" rel; then
      rc=1
      continue
    fi
    status="$(link_verify "$path" "$target")"
    if [[ "$status" != "ok" ]]; then
      if ! link_repair "$path" "$target" "$status" rel; then
        rc=1
      fi
    fi
  done < <(expected_links "$account")
  return "$rc"
}
