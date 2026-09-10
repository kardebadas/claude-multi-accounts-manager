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
