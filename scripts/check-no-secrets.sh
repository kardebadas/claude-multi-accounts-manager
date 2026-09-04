#!/usr/bin/env bash
# scripts/check-no-secrets.sh — staged-content guard for a PUBLIC repository.
#
# .gitignore in this repo is deny-by-default, which stops an *accidental* stage.
# It cannot stop a deliberate one: `git add -f` walks straight past it. This is
# the second gate. It inspects what is actually in the index and refuses the
# commit if anything there looks like user configuration, account state, a
# credential, an archive, a log, or an absolute home path.
#
#   scripts/check-no-secrets.sh     check the staged index
#
# Exit status:
#   0  nothing objectionable is staged
#   1  something is refused (each one named on stderr, with the rule)
#   2  the invocation itself is wrong (unknown argument, or not in a repo)
#
# Output: everything goes to STDERR. This script writes NOTHING to stdout, ever
# — not even on success — so it composes into any pipeline and matches the
# project-wide rule that stdout belongs to claude. It returns no data, so there
# is nothing here for a caller to capture with $( ).
#
# It may be run from any directory inside the worktree: a pre-commit hook gets
# whatever cwd the committer had, so every git call is anchored to the worktree
# root and every reported path is relative to that root.
#
# THE SELF-MATCH PROPERTY. This guard is meant to run over the whole staged
# tree, itself included, so its patterns must not match the file that defines
# them. Each one is written to break on its own source text: the path roots are
# spelled `/(home|Users)/` rather than as literals, the username class demands a
# real first character, and the key prefixes carry a bracketed letter
# (`sk-a[n]t-`) that matches a real key without matching itself.
# tests/test_check_no_secrets.sh stages this file and asserts it passes — that
# assertion is the regression lock on the property.
set -euo pipefail

prog="check-no-secrets"

# ── path rules ───────────────────────────────────────────────────────────────
# Each row is "<glob>|<why>", matched with bash's own `==` against the staged
# path (relative to the worktree root, so a rule can be anchored by omitting
# the leading */). The first matching row wins, so order is severity order.
#
# `settings.json` and `projects/*` are here because CLAUDE.md names both as
# never-commit while no ignore rule and no earlier rule table covered either
# (finding F-001). settings.local.json rides along: same file, same risk.
PATH_RULES=(
  ".credentials.json|credential file — never commit, real or captured"
  "*/.credentials.json|credential file — never commit, real or captured"
  "*.credentials.json|credential file — never commit, real or captured"
  ".claude.json|Claude account state"
  "*/.claude.json|Claude account state"
  "*.claude.json|Claude account state"
  ".env|environment file — may hold tokens"
  ".env.*|environment file — may hold tokens"
  "*/.env|environment file — may hold tokens"
  "*/.env.*|environment file — may hold tokens"
  "*.tgz|archive (the delete path tars accounts into one)"
  "*.tar|archive"
  "*.tar.gz|archive"
  "*.zip|archive"
  "*.log|captured output — can hold home paths and account names"
  "*.out|captured output — can hold home paths and account names"
  "history.jsonl|prompt history"
  "*/history.jsonl|prompt history"
  "settings.json|user settings from a real config tree"
  "*/settings.json|user settings from a real config tree"
  "settings.local.json|user settings from a real config tree"
  "*/settings.local.json|user settings from a real config tree"
  "projects/*|session transcripts and project memory"
  "*/projects/*|session transcripts and project memory"
  ".claude/*|a real Claude config tree"
  "*/.claude/*|a real Claude config tree"
  ".claude-multi/*|a real claude-multi root"
  "*/.claude-multi/*|a real claude-multi root"
  "shared/*|a real shared config folder"
  "*/shared/*|a real shared config folder"
  ".trash/*|a delete-path backup"
  "*/.trash/*|a delete-path backup"
  "agent-memory/*|auto-memory content — describes private projects"
  "*/agent-memory/*|auto-memory content — describes private projects"
  "project-memory/*|project-memory content — describes private projects"
  "*/project-memory/*|project-memory content — describes private projects"
  "docs/superpowers/*|local-only pipeline state"
  "tests/tmp/*|test scratch (a fake HOME or fake multi root)"
  "tests/.tmp/*|test scratch (a fake HOME or fake multi root)"
  "*/tests/tmp/*|test scratch (a fake HOME or fake multi root)"
)

# ── content rules ────────────────────────────────────────────────────────────
# An absolute home path leaks the username and the machine layout. Three things
# make this pattern usable rather than merely strict:
#
#  1. A real username must follow the root. The first character has to be
#     [A-Za-z0-9_], so the placeholder form this repo is *supposed* to write —
#     /home/<username>/... in CLAUDE.md, the text of the rule itself — does not
#     match, and neither does a bare /home/.something.
#  2. The root must start a path, not sit in the middle of one. tests/run.sh
#     genuinely builds "$tmp/home/.claude-multi"; an unanchored /home/ would
#     make this guard refuse the test harness. So the character before the root
#     must not be one that means "this is a continuation": alphanumerics, _ . -
#     (a path segment), $ } ) (an expansion or substitution), / and ~ (a
#     relative or home-anchored path).
#  3. All four shapes of the same leak are covered — /home/<name>,
#     /Users/<name> (macOS), /export/home/<name> (some NFS layouts) and /root.
#
# Both facts in (1) and (2) are pinned by tests, and by a test that stages the
# entire real tracked tree and requires zero hits.
_boundary='(^|[^A-Za-z0-9_.$~/})-])'
ABS_HOME_RE="${_boundary}(/export)?/(home|Users)/[A-Za-z0-9_][A-Za-z0-9_.-]*|${_boundary}/root(/|\$)"

# Anything shaped like a key or a token. Reported by line number only: the
# refusal must never echo the secret back, because the refusal itself gets
# pasted into terminals, issues and transcripts.
SECRET_RE='sk-a[n]t-|ANTHROPIC_API_[K]EY|-----BEGIN [A-Z ]*PRIVATE KEY|"access[T]oken"|"refresh[T]oken"|ghp_[A-Za-z0-9]{20}|AKIA[0-9A-Z]{16}'

# ── reporting ────────────────────────────────────────────────────────────────
# reject <path> <why> — one refusal, naming the path and the rule that caught it.
reject() {
  printf '%s: REFUSED %s\n' "$prog" "$1" >&2
  printf '%s          rule: %s\n' "$prog" "$2" >&2
}

# ── the check ────────────────────────────────────────────────────────────────
check_staged() {
  local top bad=0 path rule glob why lines
  local -a staged=()

  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$top" ]]; then
    printf '%s: not inside a git repository — nothing to check\n' "$prog" >&2
    return 2
  fi

  # Additions, copies, modifications and renames. A staged DELETION is not a
  # refusal: removing a forbidden file that once slipped in must be committable.
  while IFS= read -r -d '' path; do
    staged+=("$path")
  done < <(git -C "$top" diff --cached --name-only -z --diff-filter=ACMR)

  ((${#staged[@]} > 0)) || return 0

  for path in "${staged[@]}"; do
    for rule in "${PATH_RULES[@]}"; do
      glob="${rule%%|*}"
      why="${rule#*|}"
      # shellcheck disable=SC2053  # an unquoted glob comparison is the point
      if [[ "$path" == $glob ]]; then
        reject "$path" "$why"
        bad=1
        break
      fi
    done

    # Content is read from the INDEX (":$path"), not the worktree: the staged
    # blob is what a commit would publish. -I skips binaries.
    lines="$(git -C "$top" show ":$path" 2>/dev/null \
      | grep -InE -e "$ABS_HOME_RE" \
      | cut -d: -f1 | head -5 | tr '\n' ' ' || true)"
    if [[ -n "${lines// /}" ]]; then
      reject "$path" "absolute home path at line(s): ${lines% } — write \$HOME or ~"
      bad=1
    fi

    lines="$(git -C "$top" show ":$path" 2>/dev/null \
      | grep -InE -e "$SECRET_RE" \
      | cut -d: -f1 | head -5 | tr '\n' ' ' || true)"
    if [[ -n "${lines// /}" ]]; then
      reject "$path" "looks like a credential at line(s): ${lines% } — content not shown on purpose"
      bad=1
    fi
  done

  if ((bad)); then
    printf '%s: commit refused. This repository is PUBLIC — deleting a file\n' "$prog" >&2
    printf '%s: later does not unpublish it.\n' "$prog" >&2
    printf '%s: unstage the paths above with: git restore --staged <path>\n' "$prog" >&2
    return 1
  fi
  return 0
}

main() {
  # --install-hook arrives in T12; until then it must not silently pass.
  case "${1-}" in
    "") check_staged ;;
    *)
      printf '%s: unknown argument: %s\n' "$prog" "$1" >&2
      printf '%s: usage: %s   (no arguments; checks the staged index)\n' "$prog" "$prog" >&2
      return 2
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
