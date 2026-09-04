# CLAUDE.md — claude-multi

Instructions for any agent working in this repository. These override default
behavior.

## What this repo is

`claude-multi` — a single bash script that manages **multiple Claude Code
accounts** by pointing `CLAUDE_CONFIG_DIR` at a per-account config folder, while
one `shared/` folder is symlinked into every account so global rules, skills,
agents, hooks, commands, plugins and memory stay identical across all of them.

This repository contains **the tool only**. It contains no user configuration,
and it never will.

## THIS REPOSITORY IS PUBLIC

`kardebadas/claude-multi-session` is a public GitHub repository. Everything
committed here is world-readable, scraped, and mirrored within minutes. Deleting
a file later does not unpublish it.

**Never commit, under any circumstance:**

- The user's own `CLAUDE.md`, skills, agents, hooks or commands — the real ones
  live in `~/.claude-multi/shared/` and stay there.
- Anything from `~/.claude`: credentials, `projects/` transcripts, `history.jsonl`,
  `agent-memory/`, `projects/*/memory/`, `settings.json`, `.claude.json`.
- Any credential, token, cookie, or `.credentials.json` — real or captured.
- Auto-memory or project-memory content. It describes private projects in detail.
- Account tarballs from the delete path (`*.tgz`), logs, or captured terminal output.
- Absolute home paths. Write `$HOME` or `~`, never `/home/<username>/...` — a
  committed absolute path leaks the username and machine layout.
- Anything under `docs/superpowers/` — see below.

`.gitignore` is **deny-by-default**: everything is ignored unless explicitly
allowed. Do not replace it with a blocklist. The point is that a file a future
agent carelessly drops here — a copied config, a tarball, a log — is ignored
because nobody allowed it, rather than committed because nobody thought to deny
it. To add a legitimately new tracked path, add an explicit `!` rule for it.

Before any `git add`, run `git status --porcelain` and `git diff --cached` and
read what is actually staged. `git add -A` in this repo is a mistake.

## Repo layout

```
bin/claude-multi        the tool (single bash script)
install.sh              symlinks bin/claude-multi into ~/.local/bin
tests/run.sh            zero-dependency test runner
tests/assert.sh         assertion helpers
tests/test_*.sh         one file per area
README.md               public-facing usage
CLAUDE.md               this file
docs/superpowers/       LOCAL ONLY — gitignored, never committed
```

`docs/superpowers/` holds pipeline run state, the assumptions register and the
design spec. It quotes the user's own answers and absolute paths, and it is
deliberately never tracked. Anything from it that must survive the work goes
into `README.md` or a commit message, not into git as-is.

## Runtime layout — what the tool manages, and is NOT part of this repo

```
~/.claude-multi/
  shared/       CLAUDE.md · skills/ · agents/ · hooks/ · commands/
                plugins/ · agent-memory/ · project-memory/<slug>/
                security/ · settings.json
  <account>/    each of the above as a symlink to ../shared/
                .credentials.json, projects/, sessions/  REAL, per-account
  .trash/       delete backups

~/.claude       READ-ONLY source. Seeds shared/ once. Never written to again.
```

## Hard safety rules

1. **`~/.claude` is read-only.** Never write, move, delete, or symlink anything
   inside it. It is the user's live 6.4G config with live credentials. The tool
   reads from it exactly once, to seed `shared/`, and never touches it again.
2. **Never create or modify the real `~/.claude-multi` while developing or
   testing.** Every test drives the script against a temporary `HOME` and a
   temporary root.
3. **Credentials are existence-checked only.** `[[ -s "$acct/.credentials.json" ]]`
   and nothing more — never read, parse, copy, move, or delete that file, and
   never touch `~/.claude.json`, `daemon/`, `remote-settings.json`, or
   `policy-limits.json`.
4. **Destructive paths need a real guard.** Deleting an account requires typing
   the account name exactly (never a bare `y`), and tars the folder to
   `.trash/<name>-<timestamp>.tgz` before `rm -rf`. If the backup fails, the
   delete does not proceed.
5. **Never `rm -rf` an unvalidated variable.** Every deletion target is
   validated against the account-name grammar and confirmed to sit inside the
   multi root first.

## Coding conventions

- Bash only. `#!/usr/bin/env bash`, `set -euo pipefail`, bash 4+.
- **No external dependencies.** No `whiptail`, `dialog`, `fzf`, `jq`, `python`.
  The menu is `printf` + `read`. It must work over SSH on a bare terminal.
- Quote every expansion. `"$var"`, `"${arr[@]}"`. Paths contain spaces.
- Small named functions, one job each. The script must be readable top to bottom.
- **Injectable roots for testability:** honor `CLAUDE_MULTI_ROOT` (default
  `$HOME/.claude-multi`) and resolve the Claude binary through a variable so
  tests can substitute a stub instead of launching the real one.
- **Heal/status output goes to stderr, never stdout.** `claude-multi work -p "…"`
  pipes Claude's output; anything the tool prints to stdout corrupts it.
- Account names match `^[a-z0-9][a-z0-9-]{0,31}$`. `shared` and `.trash` are
  reserved. Uppercase input is lowercased with a notice.

## Tests

```bash
tests/run.sh
```

Zero dependencies — no bats, no shellcheck required. Every test builds a fake
`HOME` and a fake multi root in a temp dir and removes it afterwards. Any test
that would touch the real `~/.claude` or the real `~/.claude-multi` is a bug in
the test, not a passing test.

## Commits

- **No attribution trailers of any kind.** No `Co-Authored-By`, no
  `Generated with`, no assistant or model name anywhere in a commit message.
- **No session links or session IDs.** Not in commit messages, code, docs, or
  config. Never.
- No AI/assistant references in file contents or authorship.
- No email addresses or domains in commits or file contents.
