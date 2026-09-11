#!/usr/bin/env bash
# lib/menu.sh — account-menu rendering and selection. Runtime actions other
# than account launch and quit are added by later Phase 6 tasks.
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
    esac

    if [[ "$selection" =~ ^[0-9]+$ ]]; then
      index=$((10#$selection))
      if (( index >= 1 && index <= ${#names[@]} )); then
        launch_account "${names[$((index - 1))]}"
      fi
    fi

    warn "invalid selection: '$selection'"
  done
}
