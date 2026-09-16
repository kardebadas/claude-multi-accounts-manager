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
    if [[ ! -d "$path" || -L "$path" ]]; then continue; fi
    base="${path##*/}"
    if [[ "$base" == .* ]]; then continue; fi
    if is_reserved_name "$base"; then continue; fi
    if ! validate_name "$base" 2>/dev/null || [[ "$CANONICAL_NAME" != "$base" ]]; then
      continue
    fi
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

# _resolve_managed_root — resolve the one safe, real managed-root directory.
# The result is returned through _SAFE_MANAGED_ROOT so guard functions remain
# silent on stdout. Both trash operations and the final purge use this path;
# keeping one resolver prevents their containment rules from drifting apart.
_resolve_managed_root() {
  local root resolved_root home_root
  _SAFE_MANAGED_ROOT=""
  root="$(multi_root)"

  if ! validate_root_path "$root"; then
    log "refusing operation: unsafe managed root '$root'"
    return 1
  fi
  case "$root" in
    ""|"/"|"$HOME")
      log "refusing operation: unsafe managed root '$root'"
      return 1
      ;;
  esac
  if [[ -L "$root" || ! -d "$root" ]]; then
    log "refusing operation: managed root '$root' is not a real directory"
    return 1
  fi
  if ! resolved_root="$(readlink -f -- "$root" 2>/dev/null)" \
     || [[ -z "$resolved_root" ]]; then
    log "refusing operation: cannot resolve managed root '$root'"
    return 1
  fi
  if ! home_root="$(readlink -f -- "$HOME" 2>/dev/null)" \
     || [[ -z "$home_root" ]]; then
    log "refusing operation: cannot resolve HOME"
    return 1
  fi
  case "$resolved_root" in
    ""|"/"|"$home_root")
      log "refusing operation: unsafe resolved root '$resolved_root'"
      return 1
      ;;
  esac
  _SAFE_MANAGED_ROOT="$resolved_root"
}

# _prepare_trash_dir [create|existing|optional] — validate the physical trash
# directory and expose its canonical path through _SAFE_TRASH_DIR. `create`
# may create the literal child after the root itself is proven safe; `optional`
# returns 2 for an absent trash directory so pruning can retain its no-op case.
_prepare_trash_dir() {
  local mode="${1:-existing}" root trash resolved_trash
  _SAFE_TRASH_DIR=""
  if ! _resolve_managed_root; then
    return 1
  fi
  root="$_SAFE_MANAGED_ROOT"
  trash="$root/.trash"

  if [[ -L "$trash" ]]; then
    log "refusing operation: trash path '$trash' is a symlink"
    return 1
  fi
  if [[ ! -e "$trash" ]]; then
    case "$mode" in
      create)
        if ! mkdir -- "$trash"; then
          log "refusing operation: cannot create trash directory '$trash'"
          return 1
        fi
        ;;
      optional) return 2 ;;
      existing)
        log "refusing operation: trash directory '$trash' does not exist"
        return 1
        ;;
      *)
        log "refusing operation: invalid trash guard mode '$mode'"
        return 1
        ;;
    esac
  fi
  if [[ -L "$trash" || ! -d "$trash" ]]; then
    log "refusing operation: trash path '$trash' is not a real directory"
    return 1
  fi
  if ! resolved_trash="$(readlink -f -- "$trash" 2>/dev/null)" \
     || [[ -z "$resolved_trash" ]]; then
    log "refusing operation: cannot resolve trash directory '$trash'"
    return 1
  fi
  if [[ "$resolved_trash" != "$root/.trash" ]]; then
    log "refusing operation: trash directory resolves outside the managed root"
    return 1
  fi
  _SAFE_TRASH_DIR="$resolved_trash"
}

# _remove_safe_trash_file <path> — best-effort cleanup only after revalidating
# the current trash directory. The candidate must be one literal child; a
# changed symlink is safer to leave untouched than to follow during cleanup.
_remove_safe_trash_file() {
  local candidate="${1:-}" trash
  if ! _prepare_trash_dir existing; then
    return 1
  fi
  trash="$_SAFE_TRASH_DIR"
  case "$candidate" in
    "$trash"/*)
      if [[ "${candidate#"$trash"/}" == */* ]]; then
        return 1
      fi
      ;;
    *) return 1 ;;
  esac
  rm -f -- "$candidate"
}

# Decimal helpers keep filesystem measurements out of Bash's signed integer
# evaluator. Inputs become one canonical digit string, doubling is bounded to
# one digit plus carry, and comparison uses only length then byte order.
_decimal_canonicalize() {
  local value="${1:-}"
  _DECIMAL_VALUE=""
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  while [[ ${#value} -gt 1 && "${value:0:1}" == "0" ]]; do
    value="${value:1}"
  done
  _DECIMAL_VALUE="$value"
}

_decimal_double() {
  local value="${1:-}" out="" digit doubled carry=0 idx
  _DECIMAL_VALUE=""
  for (( idx=${#value} - 1; idx >= 0; idx-- )); do
    digit="${value:idx:1}"
    doubled=$(( 10#$digit * 2 + carry ))
    out="$(( doubled % 10 ))$out"
    carry=$(( doubled / 10 ))
  done
  if (( carry )); then
    out="$carry$out"
  fi
  _DECIMAL_VALUE="$out"
}

_decimal_less_than() {
  local left="$1" right="$2"
  local LC_ALL=C
  if (( ${#left} != ${#right} )); then
    (( ${#left} < ${#right} ))
    return
  fi
  [[ "$left" < "$right" ]]
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
    # lsof +D reports status 1 both for a complete no-hit scan and for some
    # incomplete traversals. Establish completeness independently before the
    # probe, then check it again before accepting an empty result as free.
    if ! find "$dir" -type d -print >/dev/null 2>&1; then
      log "could not determine whether '$name' is in use: account tree traversal failed"
      log "  refusing to delete rather than guessing"
      return 2
    fi
    if lsof_output="$("$lsof_cmd" -t +D "$dir" 2>/dev/null)"; then
      lsof_rc=0
    else
      lsof_rc=$?
    fi
    if [[ -n "$lsof_output" ]]; then
      hits="${lsof_output//$'\n'/ }"
      log "refusing: account '$name' has open files held by pid(s): $hits"
      return 0
    fi
    if ! find "$dir" -type d -print >/dev/null 2>&1; then
      log "could not determine whether '$name' is in use: account tree traversal failed"
      log "  refusing to delete rather than guessing"
      return 2
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
  if ! _prepare_trash_dir create; then
    log "refusing to delete '$name': cannot prepare a safe trash directory"
    return 1
  fi
  root="$_SAFE_MANAGED_ROOT"
  trash="$_SAFE_TRASH_DIR"

  if need="$(du -sk -- "$root/$name" 2>/dev/null | awk 'NR==1{print $1}')"; then
    :
  else
    need=""
  fi
  if ! _decimal_canonicalize "$need"; then
    log "refusing to delete '$name': cannot measure account size under $root"
    return 1
  fi
  need="$_DECIMAL_VALUE"
  _decimal_double "$need"
  want="$_DECIMAL_VALUE"

  if avail="$(df -Pk -- "$trash" 2>/dev/null | awk 'NR==2{print $4}')"; then
    :
  else
    avail=""
  fi
  if ! _decimal_canonicalize "$avail"; then
    log "refusing to delete '$name': cannot measure free space under $trash"
    return 1
  fi
  avail="$_DECIMAL_VALUE"
  if _decimal_less_than "$avail" "$want"; then
    log "refusing to delete '$name': the backup wants ${want}K (2x the ${need}K account) under $trash, only ${avail}K free"
    return 1
  fi
  return 0
}

# archive_account — A14, A30. Build the private archive under a temporary name
# on .trash's filesystem, then publish it with one atomic rename. The live
# account is never modified. Symlinks are archived as symlinks: tar is not
# given -h/--dereference, so shared data is not copied into the account backup.
archive_account() {
  local name="${1:?archive_account needs an account name}"
  local root acct trash ts tmp final
  if ! _prepare_trash_dir create; then
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  root="$_SAFE_MANAGED_ROOT"
  acct="$root/$name"
  trash="$_SAFE_TRASH_DIR"

  if ! _prepare_trash_dir existing || [[ "$_SAFE_TRASH_DIR" != "$trash" ]]; then
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  if ! chmod 700 "$trash"; then
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  if ! ts="$(date -u +%Y%m%dT%H%M%SZ)" || [[ -z "$ts" ]]; then
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi

  final="$trash/$name-$ts.tgz"
  tmp="$trash/.tmp.$name-$ts.$$.tgz"

  if ! _prepare_trash_dir existing || [[ "$_SAFE_TRASH_DIR" != "$trash" ]]; then
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  if ! ( umask 077
         tar --exclude=./.credentials.json --exclude=./.claude.json \
             -czf "$tmp" -C "$acct" . ); then
    _remove_safe_trash_file "$tmp" || true
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  if ! _prepare_trash_dir existing || [[ "$_SAFE_TRASH_DIR" != "$trash" ]]; then
    _remove_safe_trash_file "$tmp" || true
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  if ! chmod 600 "$tmp"; then
    _remove_safe_trash_file "$tmp" || true
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  if ! _prepare_trash_dir existing || [[ "$_SAFE_TRASH_DIR" != "$trash" ]]; then
    _remove_safe_trash_file "$tmp" || true
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi
  if ! mv -T --no-clobber -- "$tmp" "$final" || \
     [[ -e "$tmp" || -L "$tmp" || ! -f "$final" || -L "$final" ]]; then
    _remove_safe_trash_file "$tmp" || true
    log "backup failed; account '$name' was NOT deleted"
    return 1
  fi

  printf '%s\n' "$final"
}

# verify_archive — A36.2. Read the completed archive back before any account is
# destroyed. One captured table-of-contents read supplies every check: a tar
# error cannot be hidden by a later pipeline, and an untrusted archive is never
# opened repeatedly. This examines archive metadata only, never a live file.
verify_archive() {
  local tgz="${1:?verify_archive needs an archive path}"
  local listing entry count=0

  if [[ ! -r "$tgz" || ! -s "$tgz" ]]; then
    log "backup verification failed: $tgz is missing or empty"
    return 1
  fi
  if ! listing="$(tar -tzf "$tgz" 2>/dev/null)"; then
    log "backup verification failed: $tgz is unreadable or truncated"
    return 1
  fi

  if [[ -n "$listing" ]]; then
    while IFS= read -r entry; do
      count=$(( count + 1 ))
    done <<< "$listing"
  fi
  if (( count < 2 )); then
    log "backup verification failed: $tgz has too few entries ($count)"
    return 1
  fi

  if printf '%s\n' "$listing" | grep -qxF './.credentials.json'; then
    log "backup verification failed: $tgz contains an excluded file"
    return 1
  fi
  if printf '%s\n' "$listing" | grep -qxF './.claude.json'; then
    log "backup verification failed: $tgz contains an excluded file"
    return 1
  fi
  return 0
}

# prune_trash — A36.3. Keep the newest regular archives by their UTC timestamp,
# using the complete filename as a deterministic tie-breaker. Only literal
# top-level archives with the tool's account-timestamp name under the resolved
# trash directory are candidates; symlinks, directories and unrelated entries
# are never counted or removed.
prune_trash() {
  local keep trash f base key idx pos total retained=0 trash_rc=0
  local LC_ALL=C
  local -a archives=()
  local -a archive_keys=()

  if (( $# > 1 )); then
    log "invalid trash retention: expected at most one positive decimal integer"
    return 1
  fi
  if (( $# == 1 )); then
    keep="$1"
  else
    keep="${CLAUDE_MULTI_TRASH_KEEP:-3}"
  fi
  if [[ ! "$keep" =~ ^[1-9][0-9]*$ ]]; then
    log "invalid trash retention '$keep': expected a positive decimal integer"
    return 1
  fi

  _prepare_trash_dir optional || trash_rc=$?
  if (( trash_rc == 2 )); then
    return 0
  fi
  if (( trash_rc != 0 )); then
    return 1
  fi
  trash="$_SAFE_TRASH_DIR"
  for f in "$trash"/*.tgz; do
    base="${f##*/}"
    if [[ -f "$f" && ! -L "$f" && \
          "$base" =~ ^[a-z0-9][a-z0-9-]{0,31}-([0-9]{8}T[0-9]{6}Z)\.tgz$ ]]; then
      archives+=("$f")
      archive_keys+=("${BASH_REMATCH[1]}"$'\t'"$base")
    fi
  done

  total="${#archives[@]}"
  # Insertion-sort the parallel arrays. Candidate counts are intentionally
  # small (the default retention is three), and keeping paths as array values
  # avoids reparsing filenames or losing quoting through a text pipeline.
  for (( idx=1; idx<total; idx++ )); do
    f="${archives[$idx]}"
    key="${archive_keys[$idx]}"
    pos="$idx"
    while (( pos > 0 )) && [[ "$key" < "${archive_keys[$((pos - 1))]}" ]]; do
      archives[$pos]="${archives[$((pos - 1))]}"
      archive_keys[$pos]="${archive_keys[$((pos - 1))]}"
      pos=$(( pos - 1 ))
    done
    archives[$pos]="$f"
    archive_keys[$pos]="$key"
  done

  # A canonical keep value with more digits than the real candidate count is
  # necessarily larger. Return before arithmetic expansion so even an
  # arbitrarily large valid policy cannot overflow or be reinterpreted.
  if (( ${#keep} > ${#total} )); then
    return 0
  fi
  if (( keep >= total )); then
    return 0
  fi

  for (( idx=total - 1; idx >= 0; idx-- )); do
    f="${archives[$idx]}"
    if (( retained < keep )); then
      retained=$(( retained + 1 ))
      continue
    fi
    case "$f" in
      "$trash"/*.tgz) ;;
      *)
        log "refusing to prune path outside $trash: $f"
        return 1
        ;;
    esac
    if ! _prepare_trash_dir existing || [[ "$_SAFE_TRASH_DIR" != "$trash" ]]; then
      log "refusing to prune because the trash directory changed"
      return 1
    fi
    if [[ ! -f "$f" || -L "$f" ]]; then
      log "refusing to prune changed archive entry: ${f##*/}"
      return 1
    fi
    if ! rm -f -- "$f"; then
      log "could not prune old backup: ${f##*/}"
      return 1
    fi
    log "pruned old backup: ${f##*/}"
  done
}

# purge_account — the only recursive account deletion. Revalidate every input
# here immediately before removal so no caller can weaken the guard. The root
# is made canonical before the target is composed, and the only rm receives the
# literal canonical-root/canonical-name path.
purge_account() {
  local raw="${1:-}" name root target

  if ! validate_name "$raw"; then
    log "refusing to delete: '$raw' is not a valid account name"
    return 1
  fi
  name="$CANONICAL_NAME"
  if is_reserved_name "$name"; then
    log "refusing to delete the reserved name '$name'"
    return 1
  fi

  if ! _resolve_managed_root; then
    log "refusing to delete: unsafe managed root"
    return 1
  fi
  root="$_SAFE_MANAGED_ROOT"

  target="$root/$name"
  if [[ -L "$target" ]]; then
    log "refusing to delete: '$target' is a symlink, not an account directory"
    return 1
  fi
  if [[ ! -d "$target" ]]; then
    log "refusing to delete: '$target' is not an account directory"
    return 1
  fi

  if ! rm -rf -- "$root/$name"; then
    log "could not delete account '$name' at $target"
    return 1
  fi
}

# delete_account — compose the destructive workflow in one fail-closed order.
# Every check before purge leaves the live account untouched. If the archive
# cannot be verified, remove only the archive created by this invocation.
delete_account() {
  local raw="${1:-}" name root acct archive use_rc=0

  if ! validate_name "$raw"; then
    log "refusing to delete: '$raw' is not a valid account name"
    return 1
  fi
  name="$CANONICAL_NAME"
  if is_reserved_name "$name"; then
    log "refusing to delete the reserved name '$name'"
    return 1
  fi

  root="$(multi_root)"
  acct="$root/$name"
  if [[ ! -d "$acct" || -L "$acct" ]]; then
    log "no such account: '$name'"
    return 1
  fi

  account_in_use "$name" || use_rc=$?
  if (( use_rc == 0 )); then
    log "account '$name' is in use; refusing to delete"
    return 1
  fi
  if (( use_rc != 1 )); then
    log "could not determine whether account '$name' is in use; refusing to delete"
    return 1
  fi

  if ! describe_account "$name"; then
    return 1
  fi
  if ! confirm_exact_name "$name"; then
    return 1
  fi
  if ! check_headroom "$name"; then
    return 1
  fi
  if ! archive="$(archive_account "$name")"; then
    return 1
  fi
  if ! verify_archive "$archive"; then
    if ! _remove_safe_trash_file "$archive"; then
      log "could not safely remove the unverified backup: $archive"
    fi
    log "backup could not be verified; account '$name' was NOT deleted"
    return 1
  fi
  if ! purge_account "$name"; then
    log "account '$name' was NOT deleted; verified backup kept at $archive"
    return 1
  fi
  if ! prune_trash; then
    warn "deleted '$name', but old backup cleanup failed; verified backup kept at $archive"
  fi

  log "deleted '$name'; backup: $archive (credentials and .claude.json excluded)"
  return 0
}
