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

for arg in "$@"; do
  case "$arg" in
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

if [[ -L "$target" ]] && [[ "$(readlink -- "$target")" == "$src" ]]; then
  say "already installed: $target -> $src"
  exit 0
fi

mkdir -p -- "$bin_dir"
ln -s -- "$src" "$target"
say "installed: $target -> $src"
