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

# account_status — the credential dot. A20: existence test ONLY. This file is
# never read, parsed, copied or deleted, here or anywhere else.
account_status() {
  local name="$1" acct
  acct="$(multi_root)/$name"
  if [[ -s "$acct/.credentials.json" ]]; then
    printf 'logged-in\n'
  else
    printf 'no-credentials\n'
  fi
}

# add_account — A12 validation, A31 stub, all shared links, then memory sync.
# Link creation is delegated to heal_account (the launch/sync repair path, not
# the report-only doctor path, A35) so the shared-item table has one consumer.
add_account() {
  local raw="${1:-}" name acct
  if ! validate_name "$raw"; then
    return 1
  fi
  # validate_name owns lowercasing and delegates reserved-name rejection to
  # is_reserved_name, then returns the one canonical spelling through this
  # stdout-safe variable.
  name="$CANONICAL_NAME"
  acct="$(account_dir "$name")"
  if [[ -e "$acct" || -L "$acct" ]]; then
    log "account '$name' already exists at $acct"
    return 1
  fi

  mkdir -p "$acct"
  chmod 700 "$acct"

  if ! heal_account "$name"; then
    warn "some shared links for '$name' could not be created; run sync after fixing shared/"
  fi

  printf '%s\n' '{"hasCompletedOnboarding":true,"projects":{}}' > "$acct/.claude.json"
  chmod 600 "$acct/.claude.json"

  if ! sync_project_memory "$name"; then
    warn "project-memory sync for '$name' did not complete; run sync from the menu"
  fi

  log "created account '$name' at $acct"
}

# offer_launch — A17. Returns a decision; the caller (menu) does the exec.
# rc 0 = the user wants to launch now. CLAUDE_MULTI_NO_LAUNCH=1 suppresses the
# prompt entirely, which is how the test suite and any non-interactive caller
# drive the add path.
offer_launch() {
  local name="${1:?offer_launch needs an account name}" reply
  if [[ -n "${CLAUDE_MULTI_NO_LAUNCH:-}" ]]; then
    log "not launching; run: claude-multi $name"
    return 1
  fi
  printf "launch claude in '%s' now to log in? [Y/n] " "$name" >&2
  if ! IFS= read -r reply; then
    printf '\n' >&2
    log "no answer; not launching. run: claude-multi $name"
    return 1
  fi
  case "$reply" in
    ''|y|Y|yes|Yes|YES) return 0 ;;
    *) log "not launching; run: claude-multi $name"; return 1 ;;
  esac
}

# describe_account — A13: show what is about to be destroyed before asking.
# All output is UI on stderr. Credential presence comes from account_status, so
# this function never names or opens the credentials file itself.
describe_account() {
  local name="${1:-}" acct size creds
  if ! validate_name "$name"; then
    return 1
  fi
  name="$CANONICAL_NAME"
  acct="$(account_dir "$name")"
  if [[ ! -d "$acct" ]]; then
    log "describe_account: no such account: $name"
    return 1
  fi

  size="$(du -sh -- "$acct" 2>/dev/null | awk 'NR==1{print $1}')"
  if [[ -z "$size" ]]; then
    size="unknown"
  fi
  if [[ "$(account_status "$name")" == "logged-in" ]]; then
    creds="present — NOT included in the backup; you will need to log in again"
  else
    creds="absent"
  fi
  log "about to delete account '$name'"
  log "  path:        $acct"
  log "  size:        $size"
  log "  credentials: $creds"
}

# confirm_exact_name — A13. Typing the account name is the only confirmation.
# A bare 'y' is explicitly not accepted.
confirm_exact_name() {
  local name="${1:?confirm_exact_name needs an account name}" reply
  printf "type the account name '%s' to confirm deletion: " "$name" >&2
  if ! IFS= read -r reply; then
    printf '\n' >&2
    log "aborted: no input"
    return 1
  fi
  if [[ "$reply" == "$name" ]]; then
    return 0
  fi
  log "aborted: '$reply' does not match '$name'"
  return 1
}

# account_in_use — A36.1. Is any live process using this account as its
# CLAUDE_CONFIG_DIR? rc 0 = yes (PIDs logged), rc 1 = no, rc 2 = the check
# could not run. rc 2 is NOT "no": delete_account refuses on it.
#
# Own-uid /proc/<pid>/environ is matched line-by-line and never printed because
# process environments can contain secrets. If /proc is unavailable, lsof is
# the fail-closed fallback.
account_in_use() {
  local name="${1:?account_in_use needs an account name}"
  local procdir="${CLAUDE_MULTI_PROC:-/proc}"
  local lsof_cmd="${CLAUDE_MULTI_LSOF:-lsof}"
  local root dir p pid hits="" lsof_output="" lsof_rc=0

  root="$(multi_root)"
  dir="$root/$name"

  if [[ -d "$procdir" && -r "$procdir/self/environ" ]]; then
    for p in "$procdir"/[0-9]*; do
      if [[ ! -r "$p/environ" ]]; then continue; fi
      pid="${p##*/}"
      if [[ "$pid" == "$$" ]]; then continue; fi
      if tr '\0' '\n' < "$p/environ" 2>/dev/null \
         | grep -qxF "CLAUDE_CONFIG_DIR=$dir"; then
        hits="$hits $pid"
      fi
    done
    if [[ -n "$hits" ]]; then
      log "refusing: account '$name' is in use by pid(s):$hits"
      log "  close those sessions first; there is no override for this check"
      return 0
    fi
    return 1
  fi

  if command -v "$lsof_cmd" >/dev/null 2>&1; then
    if lsof_output="$("$lsof_cmd" -t -- "$dir" 2>/dev/null)"; then
      lsof_rc=0
    else
      lsof_rc=$?
    fi
    if [[ -n "$lsof_output" ]]; then
      hits="${lsof_output//$'\n'/ }"
      log "refusing: account '$name' has open files held by pid(s): $hits"
      return 0
    fi
    if (( lsof_rc == 0 || lsof_rc == 1 )); then
      return 1
    fi
    log "could not determine whether '$name' is in use: $lsof_cmd failed with status $lsof_rc"
    log "  refusing to delete rather than guessing"
    return 2
  fi

  log "could not determine whether '$name' is in use: no readable $procdir and no $lsof_cmd"
  log "  refusing to delete rather than guessing"
  return 2
}

# check_headroom — A36.4. Require about 2x the account size free on the
# filesystem that holds .trash: transcripts compress poorly, and .trash sits on
# the same filesystem as the account, so the write competes with live sessions.
# df is called by bare name so tests can substitute a shell function.
check_headroom() {
  local name="${1:?check_headroom needs an account name}"
  local root trash need avail want
  root="$(multi_root)"
  trash="$root/.trash"
  mkdir -p "$trash"

  if need="$(du -sk -- "$root/$name" 2>/dev/null | awk 'NR==1{print $1}')"; then
    :
  else
    need=""
  fi
  if [[ ! "$need" =~ ^[0-9]+$ ]]; then
    log "refusing to delete '$name': cannot measure account size under $root"
    return 1
  fi
  want=$(( need * 2 ))

  if avail="$(df -Pk -- "$trash" 2>/dev/null | awk 'NR==2{print $4}')"; then
    :
  else
    avail=""
  fi
  if [[ ! "$avail" =~ ^[0-9]+$ ]]; then
    log "refusing to delete '$name': cannot measure free space under $trash"
    return 1
  fi
  if (( avail < want )); then
    log "refusing to delete '$name': the backup wants ${want}K (2x the ${need}K account) under $trash, only ${avail}K free"
    return 1
  fi
  return 0
}
