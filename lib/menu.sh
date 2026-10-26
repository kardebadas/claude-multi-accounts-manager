#!/usr/bin/env bash
# lib/menu.sh — account-menu rendering, selection, and action dispatch.
# There are no ANSI escapes or terminal-widget dependencies, so the menu stays
# readable over SSH and on a bare terminal.
#
# The complete frame and prompt go to stderr. repeat_char, home_relative, and
# status_line are data producers whose stdout is captured by their callers.

G_ON='*'
G_OFF='-'
G_RULE='-'
G_ARROW='>'

# menu_glyphs — select Unicode glyphs for a UTF-8 locale, ASCII otherwise.
menu_glyphs() {
  local encoding="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  if [[ "${CLAUDE_MULTI_NO_UNICODE:-}" != "1" && "$encoding" == *[Uu][Tt][Ff]* ]]; then
    G_ON='●'
    G_OFF='○'
    G_RULE='─'
    G_ARROW='▸'
  else
    G_ON='*'
    G_OFF='-'
    G_RULE='-'
    G_ARROW='>'
  fi
}

# repeat_char <character> <count> — return exactly count copies on stdout.
repeat_char() {
  local character="$1" count="$2" result=""
  while (( count > 0 )); do
    result+="$character"
    count=$((count - 1))
  done
  printf '%s' "$result"
}

# home_relative <path> — collapse HOME itself or a path beneath it to `~`.
home_relative() {
  local path="$1"
  if [[ -n "${HOME:-}" && "$path" == "$HOME"/* ]]; then
    printf '~%s' "${path#"$HOME"}"
  elif [[ -n "${HOME:-}" && "$path" == "$HOME" ]]; then
    printf '~'
  else
    printf '%s' "$path"
  fi
}

# status_line <account> — return the current glyph and credential label.
status_line() {
  local name="$1" status
  status="$(account_status "$name")"
  if [[ "$status" == "logged-in" ]]; then
    printf '%s logged in' "$G_ON"
  else
    printf '%s no credentials' "$G_OFF"
  fi
}

# render_menu [account ...] — render a stable numbered frame and its prompt.
render_menu() {
  local -a names=("$@")
  local root shown title name index width=0
  root="$(multi_root)"
  shown="$(home_relative "$root")"
  menu_glyphs

  # The guarded expansion remains nounset-safe on Bash 4 when the array is
  # empty; the zero-account rendering itself is pinned by the next task.
  for name in ${names[@]+"${names[@]}"}; do
    if (( ${#name} > width )); then
      width=${#name}
    fi
  done
  if (( width < 8 )); then
    width=8
  fi

  title="  Claude accounts   ($shown)"
  {
    printf '\n%s\n' "$title"
    printf '  %s\n' "$(repeat_char "$G_RULE" $(( ${#title} - 2 )))"

    if (( ${#names[@]} == 0 )); then
      printf '\n   no accounts yet — press a) to add one\n'
    else
      index=1
      for name in "${names[@]}"; do
        printf '  %2d) %-*s  %s\n' \
          "$index" "$width" "$name" "$(status_line "$name")"
        index=$((index + 1))
      done
    fi

    printf '\n   a) add    d) delete\n'
    printf '   s) sync   x) doctor    q) quit\n'
    printf '\n  Select %s ' "$G_ARROW"
  } >&2
}

# menu_trim <string> — return the string without surrounding whitespace.
menu_trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

# menu_parse_index <decimal> <maximum> — validate before any arithmetic.
# The normalized result is returned through MENU_INDEX so stdout stays unused.
menu_parse_index() {
  local value="${1-}" maximum="${2-}"
  MENU_INDEX=""
  if [[ ! "$value" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  while [[ ${#value} -gt 1 && "${value:0:1}" == "0" ]]; do
    value="${value:1}"
  done
  if [[ "$value" == "0" || ${#value} -gt ${#maximum} ]]; then
    return 1
  fi
  if [[ ${#value} -eq ${#maximum} ]] && (( 10#$value > maximum )); then
    return 1
  fi
  MENU_INDEX=$((10#$value))
  return 0
}

# menu_accounts — fill the caller's names array in list_accounts order.
menu_accounts() {
  local line
  names=()
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      names+=("$line")
    fi
  done < <(list_accounts)
}

# menu_loop — render and read selections until an account launches or q quits.
menu_loop() {
  local -a names=()
  local selection index

  while :; do
    menu_accounts
    render_menu ${names[@]+"${names[@]}"}

    if ! IFS= read -r selection; then
      printf '\n' >&2
      return 0
    fi
    selection="$(menu_trim "$selection")"

    case "$selection" in
      '') continue ;;
      q|Q) return 0 ;;
      a|A) menu_do_add; continue ;;
      d|D) menu_do_delete ${names[@]+"${names[@]}"}; continue ;;
      s|S) menu_do_sync ${names[@]+"${names[@]}"}; continue ;;
      x|X) menu_do_doctor ${names[@]+"${names[@]}"}; continue ;;
    esac

    if menu_parse_index "$selection" "${#names[@]}"; then
      index="$MENU_INDEX"
      launch_account "${names[$((index - 1))]}"
    fi

    warn "invalid selection: '$selection'"
  done
}

# menu_pick <prompt> [account ...] — return a selected account name on stdout.
menu_pick() {
  local prompt="$1" selection index
  shift
  local -a names=("$@")

  if (( ${#names[@]} == 0 )); then
    warn "no accounts to choose from"
    return 1
  fi

  printf '  %s ' "$prompt" >&2
  if ! IFS= read -r selection; then
    printf '\n' >&2
    return 1
  fi
  selection="$(menu_trim "$selection")"

  if menu_parse_index "$selection" "${#names[@]}"; then
    index="$MENU_INDEX"
    printf '%s' "${names[$((index - 1))]}"
    return 0
  fi

  warn "invalid selection: '$selection'"
  return 1
}

# The action wrappers are the menu's only calls into mutating account APIs.
# They always return so menu_loop can redraw; all diagnostics remain on stderr.
menu_do_add() {
  local name
  printf '  New account name %s ' "$G_ARROW" >&2
  if ! IFS= read -r name; then
    printf '\n' >&2
    return 0
  fi
  name="$(menu_trim "$name")"
  if [[ -z "$name" ]]; then
    warn "cancelled"
    return 0
  fi
  if ! add_account "$name"; then
    warn "add failed"
    return 0
  fi
  name="$CANONICAL_NAME"
  if offer_launch "$name"; then
    launch_account "$name" || warn "launch failed"
  fi
  return 0
}

menu_do_delete() {
  local name
  if ! name="$(menu_pick "Delete which number? $G_ARROW" "$@")"; then
    return 0
  fi
  delete_account "$name" || warn "delete failed"
  return 0
}

menu_do_sync() {
  local name
  if (( $# == 0 )); then
    warn "no accounts to sync"
    return 0
  fi
  for name in "$@"; do
    warn "sync: $name"
    if ! _resolve_managed_account_dir "$name"; then
      warn "sync: $name: unsafe account target refused"
      continue
    fi
    heal_account "$name" || warn "sync: $name: link repair failed"
    sync_project_memory "$name" || warn "sync: $name: memory sync failed"
  done
  return 0
}

menu_do_doctor() {
  local name
  if (( $# == 0 )); then
    warn "no accounts to check"
    return 0
  fi
  for name in "$@"; do
    doctor_report "$name" || warn "doctor: $name: report failed"
  done
  return 0
}

# first_run_wizard — seed one complete managed root from a read-only source.
# The live root appears only through the final same-filesystem rename. No
# account is created; the caller enters the empty menu after success.
first_run_wizard() (
  local root root_canon default answer main main_canon
  local publish_target publish_parent publish_base stage_suffix stage_prefix
  local stage_template stage build_root

  root="$(multi_root)"
  validate_managed_root_source "$root" || return 1
  root_canon="$(readlink -m -- "$root")" || {
    warn "first run: cannot resolve managed root: $root"
    return 1
  }
  default="$HOME/.claude"
  menu_glyphs

  if [[ -e "$root/shared" || -L "$root/shared" || \
        -e "$root_canon/shared" || -L "$root_canon/shared" ]]; then
    warn "first run: $root/shared already exists — refusing to re-seed"
    return 1
  fi

  {
    printf '\n'
    printf '  First run. claude-multi copies the shareable parts of your main\n'
    printf '  Claude folder into %s/shared and never writes to the source.\n' \
      "$(home_relative "$root")"
    printf '\n'
  } >&2

  while :; do
    printf '  Main Claude folder [%s] %s ' \
      "$(home_relative "$default")" "$G_ARROW" >&2
    if ! IFS= read -r answer; then
      printf '\n' >&2
      warn "first run: no answer (end of input) — nothing was seeded"
      return 1
    fi
    answer="$(menu_trim "$answer")"

    if [[ -z "$answer" ]]; then
      main="$default"
    else
      case "$answer" in
        '~') main="$HOME" ;;
        '~/'*) main="$HOME/${answer#'~/'}" ;;
        *) main="$answer" ;;
      esac
    fi

    if validate_main_folder "$main"; then
      break
    fi
  done

  main_canon="$(readlink -f -- "$main")" || {
    warn "first run: cannot resolve main folder: $main"
    return 1
  }
  if _seed_paths_overlap "$main_canon" "$root_canon"; then
    warn "first run: source and managed root overlap: $main_canon <-> $root_canon"
    return 1
  fi
  if [[ -e "$root" || -L "$root" || -e "$root_canon" || -L "$root_canon" ]]; then
    warn "first run: managed root already exists — refusing to re-seed: $root_canon"
    return 1
  fi

  publish_target="$root_canon"
  stage_suffix=""
  while :; do
    publish_parent="$(dirname -- "$publish_target")" || return 1
    if [[ -d "$publish_parent" ]]; then
      break
    fi
    if [[ -e "$publish_parent" || -L "$publish_parent" ]]; then
      warn "first run: managed-root parent is not a directory: $publish_parent"
      return 1
    fi
    stage_suffix="/${publish_target##*/}$stage_suffix"
    publish_target="$publish_parent"
  done

  publish_base="${publish_target##*/}"
  stage_prefix=".$publish_base.first-run."
  if [[ "$publish_parent" == "/" ]]; then
    stage_template="/$stage_prefix"'XXXXXXXX'
  else
    stage_template="$publish_parent/$stage_prefix"'XXXXXXXX'
  fi
  if ! stage="$(mktemp -d "$stage_template")"; then
    warn "first run: cannot create staging directory beside $publish_target"
    return 1
  fi
  if ! _seed_stage_is_valid "$stage" "$publish_parent" "$stage_prefix"; then
    rmdir -- "$stage" 2>/dev/null || true
    warn "first run: created staging directory failed validation: $stage"
    return 1
  fi
  trap 'first_run_status=$?; trap - EXIT INT TERM; _seed_cleanup_stage "$stage" "$publish_parent" "$stage_prefix" || :; exit "$first_run_status"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  build_root="$stage$stage_suffix"
  if ! mkdir -p "$build_root"; then
    warn "first run: cannot create staged managed root: $build_root"
    return 1
  fi
  if ! seed_shared "$main" "$build_root/shared"; then
    warn "first run: shared seeding failed — nothing was published"
    return 1
  fi
  if [[ -f "$main_canon/settings.json" ]] && \
     ! rewrite_hook_paths "$main_canon/settings.json" \
       "$build_root/shared/settings.json" "$main" "$root_canon/shared"; then
    warn "first run: final settings rewrite failed — nothing was published"
    return 1
  fi
  if ! CLAUDE_MULTI_ROOT="$build_root" seed_project_memory "$main_canon"; then
    warn "first run: project-memory seeding failed — nothing was published"
    return 1
  fi

  if [[ -e "$publish_target" || -L "$publish_target" ]]; then
    warn "first run: destination appeared before publication: $publish_target"
    return 1
  fi
  if ! mv -T --no-clobber -- "$stage" "$publish_target" || \
     [[ -e "$stage" || -L "$stage" || ! -d "$publish_target" || -L "$publish_target" ]]; then
    warn "first run: failed to publish staged managed root: $publish_target"
    return 1
  fi
  stage=""
  trap - EXIT INT TERM

  log "first run: seeded $(home_relative "$root")/shared from $(home_relative "$main")"
  log "no account was created — press a) in the menu to add one"
  return 0
)
