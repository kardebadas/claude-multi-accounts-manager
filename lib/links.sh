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

# _resolve_managed_account_dir <account>
# Validate a mutating heal/sync target independently of its caller and expose
# its canonical path through _SAFE_ACCOUNT_DIR. Account enumeration and launch
# have their own guards; this one prevents direct heal calls from following a
# root or account symlink outside the managed tree.
_resolve_managed_account_dir() {
  local account="${1:-}" root resolved_root resolved_account
  local shared source path resolved
  _SAFE_ACCOUNT_DIR=""

  if ! validate_name "$account" || [[ "$account" != "$CANONICAL_NAME" ]]; then
    warn "refusing account mutation for invalid account name: $account"
    return 1
  fi
  root="$(multi_root)"
  if ! validate_managed_root_source "$root" || [[ -L "$root" || ! -d "$root" ]]; then
    warn "refusing account mutation through an unsafe managed root: $root"
    return 1
  fi
  if ! resolved_root="$(readlink -f -- "$root" 2>/dev/null)" || \
     [[ -z "$resolved_root" ]]; then
    warn "refusing account mutation because the managed root cannot be resolved"
    return 1
  fi
  if [[ -L "$root/$account" || ! -d "$root/$account" ]]; then
    warn "refusing account mutation for a non-directory or symlinked account: $account"
    return 1
  fi
  if ! resolved_account="$(readlink -f -- "$root/$account" 2>/dev/null)" || \
     [[ -z "$resolved_account" || "$resolved_account" != "$resolved_root/$account" ]]; then
    warn "refusing account mutation outside the managed root: $account"
    return 1
  fi
  shared="$resolved_root/shared"
  if [[ -L "$shared" || ! -d "$shared" ]] || \
     ! resolved="$(readlink -f -- "$shared")" || [[ "$resolved" != "$shared" ]]; then
    warn "refusing account mutation through an unsafe shared directory: $shared"
    return 1
  fi
  source="$(readlink -m -- "$HOME/.claude")" || return 1
  for path in "$shared"/* "$shared"/.[!.]* "$shared"/..?*; do
    if [[ ! -L "$path" ]]; then continue; fi
    if [[ "${path##*/}" != skills ]] || \
       ! resolved="$(readlink -e -- "$path")" || [[ ! -d "$resolved" ]] || \
       _seed_paths_overlap "$resolved" "$source" || \
       _seed_paths_overlap "$resolved" "$resolved_root"; then
      warn "refusing unsafe shared-item symlink: $path"
      return 1
    fi
  done
  # An empty record propagates traversal failure out of the process substitution.
  while IFS= read -r -d '' path; do
    if [[ -z "$path" ]] || ! resolved="$(readlink -m -- "$path")"; then
      warn "cannot establish safe shared symlink targets"
      return 1
    fi
    if _seed_paths_overlap "$resolved" "$source"; then
      warn "shared symlink overlaps the read-only Claude source: $path"
      return 1
    fi
  done < <(find -L "$shared" -mindepth 2 -xtype l -print0 || printf '\0')
  _SAFE_ACCOUNT_DIR="$resolved_account"
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
        while :; do
          while [[ -e "$backup" || -L "$backup" ]]; do
            backup="$backup.1"
          done
          if ! mv -nT -- "$path" "$backup"; then
            warn "cannot back up $path — leaving it in place"
            return 1
          fi
          if [[ ! -e "$path" && ! -L "$path" && \
                ( -e "$backup" || -L "$backup" ) ]]; then
            break
          fi
          backup="$backup.1"
        done
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
  if ! _resolve_managed_account_dir "$account"; then
    return 1
  fi
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

# doctor_report <account> [account...]
# FLOW. Read-only per-item status for each named account. Repairs NOTHING —
# doctor diagnoses, sync (heal_account) repairs. Every line goes to stderr.
# 0 = every item of every named account is ok, 1 = something needs attention.
#
# It takes names as arguments and deliberately does NOT enumerate accounts:
# lib/accounts.sh's list_accounts is the project's single enumerator, and a
# second directory walk here diverged from it on hidden directories. A caller
# that wants them all does:
#   mapfile -t accts < <(list_accounts); doctor_report "${accts[@]}"
doctor_report() {
  local account path target status rc=0 root
  if (( $# == 0 )); then
    warn "doctor: needs at least one account name (use list_accounts to enumerate)"
    return 1
  fi
  root="$(multi_root)"
  for account in "$@"; do
    if is_reserved_name "$account"; then
      warn "doctor: $account is a reserved directory, not an account"
      rc=1
      continue
    fi
    if [[ ! -d "$root/$account" ]]; then
      warn "doctor: no such account: $account"
      rc=1
      continue
    fi
    log "$account"
    while IFS=$'\t' read -r path target; do
      status="$(link_verify "$path" "$target")"
      if [[ "$status" != "ok" ]]; then rc=1; fi
      log "$(printf '  %-14s %s' "${path##*/}" "$status")"
    done < <(expected_links "$account")
  done
  return "$rc"
}
