#!/usr/bin/env bash
# lib/accounts.sh — list, add and delete managed Claude accounts.
# Sourced by bin/claude-multi after util.sh, config.sh, links.sh, seed.sh,
# memory.sh. Never executed directly, so it sets no shell options.
#
# stdout discipline: only list_accounts, account_status and archive_account
# write to stdout, and only machine-readable data. Everything human goes to
# stderr via log/warn.

# list_accounts — one account name per line. No output if there are none.
#
# ORDER IS A GUARANTEE, NOT A CONVENIENCE: byte-wise ascending under LC_ALL=C,
# identical on every locale and every filesystem. Phase 6's menu numbers the
# accounts by their position in this list and `d) delete` acts on the number the
# user typed, so an order that shifts between two runs deletes the wrong
# account. Glob expansion is sorted by LC_COLLATE (a locale where '-' collates
# differently reorders `personal-mother` against `personalx`), and readdir order
# is filesystem-defined, so neither is trusted: the names go through
# `LC_ALL=C sort` before they are printed.
list_accounts() {
  local root path base
  root="$(multi_root)"
  if [[ ! -d "$root" ]]; then
    return 0
  fi
  for path in "$root"/*; do
    if [[ ! -d "$path" ]]; then continue; fi
    base="${path##*/}"
    if [[ "$base" == .* ]]; then continue; fi
    if is_reserved_name "$base"; then continue; fi
    printf '%s\n' "$base"
  done | LC_ALL=C sort
}
