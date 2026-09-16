# claude-multi

`claude-multi` runs several Claude Code accounts side by side on one machine.
Each account gets its own `CLAUDE_CONFIG_DIR`, while configuration that should
stay identical across accounts lives once under `~/.claude-multi/shared/`.

Global instructions, skills, agents, hooks, commands, settings, and selected
memory are shared. Logins, conversations, shell history, and other session
state remain per account.

## Requirements

- Bash 4 or newer
- `claude` on `PATH`
- GNU coreutils and `tar`
- `~/.local/bin` on `PATH`; the installer does not edit shell profiles
- Linux `/proc`, or `lsof` as a fallback, for the fail-closed account-in-use
  check before deletion

## Install

Clone the repository, then run the installer from the clone:

```bash
git clone <repository-url> claude-multi-accounts-manager
cd claude-multi-accounts-manager
./install.sh
```

The installer creates one symlink:
`~/.local/bin/claude-multi` points to `bin/claude-multi` in the clone. Keep the
clone in place after installation.

| Command | Behavior |
| --- | --- |
| `./install.sh` | Create the link. Re-running is an idempotent no-op. |
| `./install.sh --force` | Replace a symlink that points somewhere else. |
| `./install.sh --uninstall` | Remove the link only when it points to this clone. |
| `./install.sh --help` | Show installer usage. |

The installer never edits `.bashrc`, `.profile`, `.zshrc`, or any other shell
configuration, and it does not create aliases. Its output goes to stderr.

An existing regular file at `~/.local/bin/claude-multi` is never overwritten,
even with `--force`. Without `--force`, a foreign symlink is also left alone.
Uninstalling is a no-op when the destination is absent and refuses to remove a
regular file or a link owned by another installation.

## First run

Run `claude-multi`. When `~/.claude-multi` does not exist, the first-run wizard
asks for the main Claude configuration folder, defaulting to `~/.claude`. The
folder must contain `settings.json` or `CLAUDE.md`.

The wizard copies only the shareable configuration into a private staging
directory beside the destination, rewrites matching hook paths in the copied
`settings.json`, seeds eligible project memory, and publishes the complete
managed root with one final rename. The source folder is read-only: it is not
modified, and source and destination are refused when either contains the
other. A failure or interruption does not publish a partial live root.

First run creates no account. After seeding, the empty account menu appears;
choose `a` to add the first account.

## Usage

```text
claude-multi                 # interactive account menu
claude-multi <name> [args]   # heal that account, then launch Claude Code
```

```text
  Claude accounts   (~/.claude-multi)
  -----------------------------------
   1) personal          * logged in
   2) personal-mother   * logged in
   3) work              - no credentials

   a) add    d) delete
   s) sync   x) doctor    q) quit

  Select >
```

The menu uses Unicode glyphs in a UTF-8 locale and the ASCII equivalents shown
above otherwise.

| Menu action | What it does |
| --- | --- |
| `a) add` | Create an account directory, shared links, and a private `.claude.json` stub, then offer to launch Claude Code for login. |
| `d) delete` | Archive and remove an account through the guarded flow described below. |
| `s) sync` | Repair shared links and project-memory links for every account without launching Claude Code. |
| `x) doctor` | Report only: print the status of expected links without changing anything. |
| `q) quit` | Exit the menu. |

`doctor` never repairs. Repairs happen automatically before an account is
launched or when `sync` is selected. If a shared link has been replaced by a
real file or directory, the repair path preserves that content in a timestamped
backup before relinking rather than silently discarding it.

Everything after the account name is passed to `claude` unchanged. Tool
diagnostics and repair messages go to stderr, leaving stdout to Claude Code:

```bash
claude-multi work -p 'summarize this' --output-format json | jq .
```

There are no command-line verbs. `add`, `delete`, `sync`, and `doctor` are menu
actions, so `claude-multi add` means “launch the account named `add`.”

## Account names

Names match `^[a-z0-9][a-z0-9-]{0,31}$`: lowercase letters, digits, and
hyphens, with a maximum length of 32 characters. Uppercase input is lowercased
with a notice. Leading dots and leading hyphens are rejected.

The structural names `shared`, `.trash`, `plugin-cache`, and `project-memory`
are reserved and cannot be accounts.

## Sharing boundary

Each account links the shared items below to the one canonical copy under
`~/.claude-multi/shared/`.

| Shared | Notes |
| --- | --- |
| `CLAUDE.md` | Global instructions remain identical across accounts. |
| `skills/` | Seeded from the main folder. A source symlink is resolved so it can remain shared with Codex. |
| `agents/` | Shared agent definitions. |
| `hooks/` | Shared hook scripts. Matching source paths in the copied settings are rewritten here. |
| `commands/` | Shared commands; created empty when absent from the source. |
| `agent-memory/` | Shared agent memory. |
| `settings.json` | One settings file for every managed account. |
| `project-memory/<slug>/` | Linked into an account as `projects/<slug>/memory`. |
| Plugin cache | Shared through `CLAUDE_CODE_PLUGIN_CACHE_DIR`, not through a `plugins/` symlink. |

The following state is deliberately real and per account, rather than linked:

| Not shared | Notes |
| --- | --- |
| `.credentials.json` | Account login state. The tool only tests whether this file is non-empty; it never reads or parses it. |
| `.claude.json` | A private stub is created when an account is added. |
| `daemon/`, `remote-settings.json`, `policy-limits.json` | Account-linked state. Daemon isolation is still unverified; see Limitations. |
| `projects/` transcripts, `sessions/`, `session-env/`, `jobs/`, `tasks/` | Conversation and task state. |
| `shell-snapshots/`, `file-history/`, `paste-cache/`, `downloads/`, `debug/`, `cache/`, `*-cache.json` | Session- or machine-derived state. |
| `history.jsonl` | Kept private so work prompts do not appear in a personal account. |
| `security/` | Per-session security-plugin state and lock files; no link or environment override is created. |
| `plugins/` | Kept per account because plugin install locations cannot be shared safely by symlink. |

### Project memory

On first run, existing memory directories are copied into
`shared/project-memory/<slug>/` only when the encoded project slug decodes to a
unique directory that exists. Paths containing `.claude/worktrees` or a path
component exactly named `wt` are treated as ephemeral worktrees and skipped;
similarly named components such as `wt-dashboard` are not skipped.

There is no general system-path or “junk path” filter. For example, `-tmp` is
eligible when it uniquely decodes to the existing `/tmp` directory and has a
memory directory in the source. `sync` creates or repairs account links for
the memories already in the shared store. The current release does not
automatically enroll a newly appeared account project into that store.

## Deleting an account

Deletion is fail-closed and deliberately difficult to trigger accidentally:

1. The account name and managed root are validated, and reserved names,
   symlinked account paths, and unsafe roots are refused.
2. An in-use check searches live process environments for the account's
   `CLAUDE_CONFIG_DIR`, with `lsof` as a fallback. An active account or an
   inconclusive check blocks deletion; there is no override.
3. The tool shows the account path, size, and whether credentials are present.
   You must type the account name exactly; a bare `y` is not accepted.
4. A disk-headroom check requires about twice the measured account size to be
   available on the filesystem holding `.trash`.
5. A private archive is created under
   `~/.claude-multi/.trash/<name>-<timestamp>.tgz` with mode `0600`. The archive
   is published only after `tar` succeeds.
6. The archive is read back with `tar -tzf` and checked before removal. If it
   is missing, empty, truncated, suspiciously small, or contains an excluded
   account-state file, the live account remains untouched.
7. Recursive removal runs only after every preceding guard passes. The target
   is revalidated immediately before removal.

Both `.credentials.json` and `.claude.json` are excluded from the archive.
Restoring therefore means extracting the backup into place and logging in
again. Shared symlinks are archived as symlinks; shared content is not copied
into the backup.

After a successful deletion, `.trash` keeps the newest three regular `.tgz`
archives by default. Set `CLAUDE_MULTI_TRASH_KEEP` to a positive decimal number
to choose a different retention count. Unrelated entries, directories, and
symlinks are never pruning candidates.

## Security guard and its limits

`scripts/check-no-secrets.sh` scans staged additions, copies, modifications,
and renames for forbidden private paths, configuration trees, archives,
absolute home paths, binary content, and credential-shaped text. It can install
itself as this repository's pre-commit hook:

```bash
bash scripts/check-no-secrets.sh --install-hook
```

This hook is defense in depth, not a complete publication boundary. Git's
`--no-verify` option bypasses pre-commit hooks, and merge commits can be created
without this pre-commit hook running. The guard also examines the staged index,
not untracked or unstaged content. Before releasing or publishing, run
`bash scripts/check-no-secrets.sh` explicitly on the intended staged tree and
independently review the complete tracked inventory and history.

## Limitations

- **Background daemon and Remote Control are unverified (`INCONCLUSIVE_AUTH`).**
  A credential-free experiment with Claude Code 2.1.273 used both a fake
  `HOME` and a separate fake `CLAUDE_CONFIG_DIR`. No daemon artifacts appeared
  in either location, but the only session-capable probe stopped at the login
  gate. That absence is not evidence that the daemon is disabled or that its
  state relocates correctly. Treat Remote Control availability and account
  isolation as unknown for managed accounts.
- All accounts share one plugin cache. Install or update plugins from one
  account at a time.
- `settings.json` is genuinely shared. Account-specific settings placed there
  affect every account.
- The shared skills directory can also be the directory used by Codex.
- `doctor` is report-only. Use `sync` or launch an account to repair links.
- The installed command is a symlink into the clone. If the clone moves,
  reinstall it from the new location with `./install.sh --force`.
- The project is Bash-only and provides no shell completion or profile setup.

## Publication status

This project is currently distributed from source; there is no tagged or
packaged release. At the time this README was committed, the complete P7
release candidate remained on a local feature branch and `origin/main`
contained an earlier implementation checkpoint. Updating `origin/main` was
authorized only after the remaining release gates pass. This workflow does not
create or merge a pull request.

## License

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for the
canonical license text.

```text
Copyright 2026 kardebadas
```

### Change statements

The repository currently contains original project files and therefore has no
third-party Apache-2.0 modifications to declare. If Apache-2.0 code is vendored
later, changed files must carry a prominent change notice and any accompanying
`NOTICE` file must be preserved as required by the license.
