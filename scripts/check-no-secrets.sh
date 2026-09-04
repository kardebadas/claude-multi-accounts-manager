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
#
# WHAT THIS GUARD CANNOT SEE. It is a line-oriented regex scan over index blobs,
# so the following leaks get past it BY CONSTRUCTION. They are recorded here so
# nobody mistakes the guard for exhaustive, and so the release gate knows what
# it still has to eyeball:
#
#   * A path assembled from an expansion or a substitution. `${base}/home/<u>`,
#     `$(printf '/%s/%s' home <u>)` and `)/home/<u>` all pass, because the
#     character before the root must stay exempt for the legitimate mid-path
#     forms this repo genuinely contains ("$tmp/home/…", "${TMPDIR}/home/acct").
#     The tests in this project are REQUIRED to assemble their fixtures exactly
#     this way, so closing it would make the suite unrunnable.
#   * A leak split across two lines — a backslash continuation, or `HOME=/home`
#     on one line and `"$HOME/<u>"` on the next. grep is line-oriented.
#   * `/home/-someuser` and `/home/.someuser`. The username class demands a real
#     first character so that the placeholder `/home/<username>` this repo is
#     supposed to write does not trip the guard. Neither is a valid Linux
#     username.
#   * `/usr/home/<u>` (BSD) and `/HOME/<u>`. Not layouts on this project's
#     platforms.
#   * A secret in a shape no rule below describes. SECRET_RE is a list of known
#     formats, not a detector of entropy.
#
# Everything in that list is a known limit, deliberately accepted. Everything
# NOT in it is a bug: a fully-legible absolute home path in ordinary text must
# be caught, including the doubled-slash, file:// URL, tilde-user, WSL
# /mnt/<drive>/ and hyphen-adjacent forms, each of which has a test.
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
  # `.env.*` refuses `.env.example` too. That is deliberate and must stay:
  # this project will never contain a `.env` of any kind, so the false positive
  # is on a file that does not exist, while loosening a secret rule for a
  # hypothetical template is a real cost. `env.sample` and
  # `settings.example.json` both pass, so a template has a spelling that works.
  # Reviewed and declined as finding M-3 — do not "fix" this into a pass.
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
#     genuinely builds "$tmp/home/.claude-multi"; an unanchored root would make
#     this guard refuse the test harness. So the character before the root must
#     not be one that means "this is a continuation of something else":
#     alphanumerics and _ . - (a path segment or a word), $ } ) (an expansion or
#     a substitution), and ~ (a home-anchored relative path).
#
#     `/` is NOT in that exclusion class, and that is load-bearing. It used to
#     be, and it let `//home/<u>` and `file:///home/<u>` — the same file, the
#     same username, fully legible — walk straight past the guard. No legitimate
#     case needs it: "$tmp/home/…" is protected by `p` being alphanumeric, not
#     by the slash. `-` is out of the class for the same reason: with it in,
#     the removed side of a committed diff hunk (`-/home/<u>/…`) escaped.
#
#     Because a `/` is now itself an acceptable boundary character, a repeated
#     separator needs no separate arm: in `//home/<u>` the first slash IS the
#     boundary and the second starts the root. (A `/+` arm was tried and is
#     provably dead code — no input reaches it that the boundary does not
#     already cover.) The accepted cost is that a doubled slash mid-path,
#     `"$tmp//home/…"`, is now refused. That is a typo worth refusing.
#  3. Every root that reaches a real home directory is covered:
#     /home/<name>, /Users/<name> (macOS), /export/home/<name> (some NFS
#     layouts), /root, /mnt/<mount>/home|Users/<name> (WSL — the platform this
#     project is developed on, where it leaks the *Windows* account name), and
#     ~<name>/ (the tilde-user form, which the advice "write $HOME or ~"
#     positively invites).
#
# Every fact above is pinned by a test, including one that stages the entire
# real tracked tree and requires zero hits, and one test per escaping shape.
_boundary='(^|[^A-Za-z0-9_.$~})])'
_user='[A-Za-z0-9_][A-Za-z0-9_.-]*'
ABS_HOME_RE="${_boundary}(/export)?/(home|Users)/${_user}"
ABS_HOME_RE+="|${_boundary}/root(/|\$)"
ABS_HOME_RE+="|${_boundary}/mnt/[A-Za-z0-9_.-]+/(home|Users)/${_user}"
ABS_HOME_RE+="|${_boundary}~${_user}/"

# Anything shaped like a key or a token. Reported by line number only: the
# refusal must never echo the secret back, because the refusal itself gets
# pasted into terminals, issues and transcripts.
#
# Each arm carries a bracketed letter where it would otherwise match this very
# line — `sk-a[n]t-`, `[K]EY`, `github_[p]at_`. Where an alternation already
# breaks the literal (`ANTHROPIC_(API_…`, `gh[pousr]_`) no extra trick is
# needed.
#
# The token-name arm accepts a closing `"` or `'` and then requires a `:` or an
# `=`, which is what separates a real assignment in JSON, YAML, a shell export
# or a JS object from prose that merely names the field. An optional OPENING
# quote was tried and is dead code: the arm is unanchored, so an optional
# character at its head can never change whether it matches.
_q="[\"']?"
SECRET_RE='sk-a[n]t-'
SECRET_RE+='|ANTHROPIC_(API_[K]EY|AUTH_[T]OKEN)'
SECRET_RE+='|-----BEGIN [A-Z ]*PRIVATE KEY'
SECRET_RE+="|(access|refresh)_?[Tt]oken${_q}[[:space:]]*[:=]"
SECRET_RE+='|gh[pousr]_[A-Za-z0-9]{20}'
SECRET_RE+='|github_[p]at_[A-Za-z0-9_]{20}'
SECRET_RE+='|AKIA[0-9A-Z]{16}'
SECRET_RE+='|aws_secret_access_[k]ey|AWS_SECRET_ACCESS_[K]EY'
SECRET_RE+='|Bearer [A-Za-z0-9._~+/-]{20,}'
SECRET_RE+='|ey[J][A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
SECRET_RE+='|xox[baprs]-[A-Za-z0-9-]{10}'

# ── reporting ────────────────────────────────────────────────────────────────
# reject <path> <why> — one refusal, naming the path and the rule that caught it.
reject() {
  printf '%s: REFUSED %s\n' "$prog" "$1" >&2
  printf '%s          rule: %s\n' "$prog" "$2" >&2
}

# ── unscannable content ──────────────────────────────────────────────────────
# blob_is_unscannable <top> <path> — true when the content scans below cannot
# see inside the staged blob, so a leak in it would pass unexamined.
#
# `grep -I` is documented as "process a binary file as if it did not contain
# matching data": a staged .png, .pdf or compiled artifact carrying a home path
# or a token used to exit 0 with neither scan having looked at a single byte.
# This asks grep itself the question — an empty pattern matches every line of
# anything grep is willing to read — so the answer tracks the scanner's own
# heuristic rather than a second guess at it. An empty blob is not unscannable;
# there is simply nothing in it, so its size is checked first.
blob_is_unscannable() {
  local bytes
  bytes="$(git -C "$1" cat-file -s ":$2" 2>/dev/null || true)"
  bytes="${bytes//[^0-9]/}"
  if [[ -z "$bytes" || "$bytes" == "0" ]]; then
    return 1
  fi
  if git -C "$1" show ":$2" 2>/dev/null | grep -Iq -e ''; then
    return 1
  fi
  return 0
}

# ── the check ────────────────────────────────────────────────────────────────
check_staged() {
  local top bad=0 path rule glob why lines entry
  local -a staged=()
  local -A mode_of

  top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$top" ]]; then
    printf '%s: not inside a git repository — nothing to check\n' "$prog" >&2
    return 2
  fi

  # Additions, copies, modifications and renames. A staged DELETION is not a
  # refusal: removing a forbidden file that once slipped in must be committable,
  # and a deletion publishes nothing. Pinned by a test that deletes a path every
  # rule below would refuse as an addition.
  while IFS= read -r -d '' path; do
    staged+=("$path")
  done < <(git -C "$top" diff --cached --name-only -z --diff-filter=ACMR)

  ((${#staged[@]} > 0)) || return 0

  # Index modes, so a gitlink can be told from a blob. Each row is
  # "<mode> <object> <stage>\t<path>".
  while IFS= read -r -d '' entry; do
    mode_of["${entry#*$'\t'}"]="${entry%% *}"
  done < <(git -C "$top" ls-files --stage -z)

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

    # A gitlink (mode 160000) is a pointer to another repository's commit.
    # `git show ":<path>"` yields nothing for it, so both content scans below
    # would find nothing and wave it through. This repo has no submodules and
    # must never gain one, so the entry is refused outright rather than scanned.
    if [[ "${mode_of[$path]-}" == "160000" ]]; then
      reject "$path" "gitlink (submodule entry) — its content cannot be scanned, and this repo has no submodules"
      bad=1
      continue
    fi

    # Likewise a blob the scanner cannot read. The .gitignore allowlist only
    # ever permits .sh files plus bin/claude-multi and tests/fake-claude, so
    # there is no legitimate tracked binary to protect: refusing one is correct,
    # and strictly safer than pretending a scan happened.
    if blob_is_unscannable "$top" "$path"; then
      reject "$path" "binary content — it cannot be scanned for a home path or a token, and this repo tracks only text"
      bad=1
      continue
    fi

    # Content is read from the INDEX (":$path"), not the worktree: the staged
    # blob is what a commit would publish.
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
