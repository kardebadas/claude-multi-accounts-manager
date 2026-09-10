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
    *)
      warn "link_repair: unknown status '$status' for $path"
      return 1
      ;;
  esac
  return 0
}
