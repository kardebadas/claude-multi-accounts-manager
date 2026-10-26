#!/usr/bin/env bash
# Symlink bin/claude-multi into ~/.local/bin. Nothing else. No profile edits.
set -euo pipefail

: "${HOME:?HOME must be set}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
src="$script_dir/bin/claude-multi"
bin_dir="$HOME/.local/bin"
target="$bin_dir/claude-multi"

say() { printf 'install.sh: %s\n' "$*" >&2; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

force=0
mode=install
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --uninstall) mode=uninstall ;;
    -h|--help)
      say "usage: install.sh [--force] [--uninstall]"
      exit 0
      ;;
    *)
      printf 'install.sh: unknown option: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

[[ -f "$src" ]] || die "not found: $src — run install.sh from inside its own clone"
[[ -x "$src" ]] || die "not executable: $src — run: chmod +x bin/claude-multi"

if [[ "$mode" == uninstall ]]; then
  if [[ ! -L "$target" && ! -e "$target" ]]; then
    say "nothing to uninstall: $target does not exist"
    exit 0
  fi
  if [[ ! -L "$target" ]]; then
    die "refusing to remove $target — it is not a symlink, so it is not ours"
  fi
  current="$(readlink -- "$target")"
  if [[ "$current" != "$src" ]]; then
    die "refusing to remove $target — it points to $current, not $src"
  fi
  rm -- "$target"
  say "removed: $target"
  exit 0
fi

if [[ -L "$target" ]]; then
  current="$(readlink -- "$target")"
  if [[ "$current" == "$src" ]]; then
    say "already installed: $target -> $src"
    exit 0
  fi
  if (( force )); then
    rm -- "$target"
    say "replaced foreign link that pointed to: $current"
  else
    die "refusing to clobber $target — it is a symlink to $current (re-run with --force to replace it)"
  fi
elif [[ -e "$target" ]]; then
  die "refusing to clobber $target — it exists and is not a symlink (move it aside yourself)"
fi

mkdir -p -- "$bin_dir"
ln -s -- "$src" "$target"
say "installed: $target -> $src"
