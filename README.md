# claude-multi

[![CI](https://github.com/hanslemm/claude-multi/actions/workflows/ci.yml/badge.svg)](https://github.com/hanslemm/claude-multi/actions/workflows/ci.yml)

One Claude Code login per terminal.

Claude Code keeps a single login in `~/.claude` (and, on macOS, a Keychain entry keyed to that
directory). Account rotators such as `cswap` (claude-swap) swap that one login, so switching in one
terminal switches every terminal — a personal and a work subscription, or several accounts used to
spread rate limits, cannot run side by side. Claude Code's own isolation mechanism is
`CLAUDE_CONFIG_DIR`: it relocates the whole config tree and keys the credential to it. claude-multi
gives every account its own `CLAUDE_CONFIG_DIR`, a launcher, and a way to pin a terminal to it, while
settings, MCP servers, CLAUDE.md, commands, agents, skills and per-repo memory stay shared.

## Quick start

Guided (recommended): install the skill, then type `/claude-multi` in Claude Code and follow along.

```sh
npx skills add hanslemm/claude-multi -g     # -g installs for every project; omit it for the current one only
```

Manual: download the script and follow the prompts (`install.sh` runs the script from
`~/.claude-multi`; piping `claude-multi-setup.sh` itself into `bash` works but cannot self-install).

```sh
curl -fsSL https://raw.githubusercontent.com/hanslemm/claude-multi/main/install.sh | sh
```

Plugin: from inside Claude Code.

```
/plugin marketplace add hanslemm/claude-multi
/plugin install claude-multi@claude-multi
```

All three end in the same place: `~/.claude-multi/claude-multi-setup.sh` installed, one directory per
account under `~/.claude-accounts/`, and `~/.claude-multi/aliases.sh` ready to be sourced. Then, once
per account, run `claude-<slug>` and `/login` — the tool never copies a login.

## Daily use

| Command | What it does |
|---|---|
| `claude-<slug> [args]` | start Claude Code as that account; extra arguments pass through to `claude` |
| `claude1` … `claudeN` | the same, by slot number |
| `cuse <slug\|slot>` | pin this terminal to an account (exports `CLAUDE_CONFIG_DIR`); plain `claude` then uses it |
| `cuse default` | unpin this terminal (back to `~/.claude`) |
| `cwho` | which account this terminal is on, plus the login state of every account |
| `~/.claude-multi/claude-multi-setup.sh add <email> [--slot N]` | register an account and create its dir + launcher |
| `~/.claude-multi/claude-multi-setup.sh remove <email>` | drop the launcher; the account dir and its login are kept |
| `~/.claude-multi/claude-multi-setup.sh status` | script path, cswap, shared dir, rc line, this terminal, every account, what to do next |
| `~/.claude-multi/claude-multi-setup.sh [setup] [--dry-run] [--relink] [--rc[=FILE]] [--no-input]` | (re)run setup; `--help` lists the flags |

`cswap` is optional: if it is in `PATH` its account list is discovered; otherwise the script asks for
emails, or takes them from `add <email>` or the `ACCOUNT_ROWS` environment variable.

## What is shared, what is not

| Item | Where | How |
|---|---|---|
| `settings.json` | `~/.claude-shared/settings.json` | passed as `--settings` on every launch |
| MCP servers (`mcp.json`) | `~/.claude-shared/mcp.json` | passed as `--mcp-config` (merged with the account's own) |
| `CLAUDE.md`, `commands/`, `agents/`, `skills/`, `output-styles/` | `~/.claude-shared/<name>` | symlinked into every account dir |
| Per-repo auto-memory | `~/.claude/projects/<p>/memory/` | symlinked into every account (`projects/<p>/memory`) |
| Login / credentials | `~/.claude-accounts/<slug>/` (+ Keychain on macOS) | per account, never copied |
| `.claude.json` (sessions, per-project trust, `claude mcp add` servers) | per account dir | per account |
| `plugins/`, history, sessions | per account dir | per account; plugins install themselves on first start |
| `~/.claude`, `~/.claude.json` | the default account | never modified; read once as the seed for `~/.claude-shared` |

## How it works

- **One config dir per account.** `~/.claude-accounts/<slug>/` (mode 700) is the `CLAUDE_CONFIG_DIR`
  for that account. On macOS the Keychain credential is keyed to the directory; on Linux the credential
  file lives inside it. Either way, a terminal that exports the variable reads that account's login.
- **Flags, not symlinks, for `settings.json` and `mcp.json`.** Claude Code rewrites `settings.json`
  when `/config` changes something; a symlink would be replaced by a plain file and silently un-shared.
  The launchers pass `--mcp-config ~/.claude-shared/mcp.json --settings ~/.claude-shared/settings.json`
  (root options, in that order, before any user arguments). Read-only items are symlinked.
- **API-key precedence.** `ANTHROPIC_API_KEY` outranks a subscription login; a launcher that left it
  in place would bill the API. The launcher unsets it (and `CLAUDE_CODE_OAUTH_TOKEN`,
  `ANTHROPIC_AUTH_TOKEN`, which override the login the same way) inside its own subshell; your shell
  keeps them. The setup warns if the seeded `~/.claude-shared/settings.json` carries an
  `env.ANTHROPIC_API_KEY` or `apiKeyHelper`, since `--settings` would re-inject it on every launch.
- **One `/login` per account, never a migration.** The Keychain key derivation is undocumented, so
  tokens are never copied between directories. Each account is logged in once, interactively.
- **Memory is shared.** For every `~/.claude/projects/<p>/memory/` that exists, each account gets a
  symlink to it. The canonical folder stays in `~/.claude`; nothing is moved. `--relink` picks up a
  repo that gained memory later.
- **Idempotent and safe.** A re-run with nothing new prints `No changes — everything was already in
  place.` and leaves the filesystem byte-identical. The tool never deletes an account dir, never
  overwrites a seeded shared file, never modifies `~/.claude` or `~/.claude.json`, never touches an
  rc file without `--rc`, never leaves the cswap export on disk, never migrates credentials, never
  prints tokens. `--dry-run` prints every change and creates nothing, not even `~/.claude-multi`.

## Requirements

- macOS or Linux; bash 3.2 or newer to run the script (`/bin/bash` on macOS is fine)
- zsh or bash as the interactive shell (`aliases.sh` is sourced by both)
- Claude Code installed (`claude` in `PATH`)
- Optional: `cswap` for automatic account discovery; `jq` or `python3` to extract MCP servers from
  `~/.claude.json` (without them `mcp.json` is seeded empty with a warning)

## Uninstall

1. Remove the rc line from `~/.zshrc` / `~/.bashrc` (or the `--rc=FILE` you chose):
   `[ -f "$HOME/.claude-multi/aliases.sh" ] && . "$HOME/.claude-multi/aliases.sh"`
2. `rm -rf ~/.claude-multi` (script, aliases, account registry).
3. `rm -rf ~/.claude-shared` — only if you do not want the shared settings, MCP config and CLAUDE.md
   any more; they are copies, the originals in `~/.claude` are untouched.
4. `~/.claude-accounts/<slug>/` holds each account's login, sessions and plugins. Delete a directory
   only when you are done with that account (on macOS, also remove its `Claude Code-credentials`
   Keychain entry). The tool itself never deletes these.

`~/.claude` and `~/.claude.json` were never modified, so the default account keeps working.

## Development

- `tests/harness.sh` — the test matrix (T1–T18 in the contract); builds a throwaway `HOME` per case
  with a stub `claude` and a stub `cswap`. Run it with `/bin/bash tests/harness.sh` (bash 3.2 on
  macOS) and with `bash tests/harness.sh`.
- CI (`.github/workflows/ci.yml`): macOS + Ubuntu, `bash -n`, `shellcheck -S warning -s bash` on the script and
  the harness, `sh -n install.sh`, then the harness under both bash versions.
- The contract is [`docs/design.md`](docs/design.md): flags, file formats, output shapes, safety
  invariants. When a file disagrees with it, the file is the bug.

Layout: `skills/claude-multi/` (the skill: `SKILL.md` + `scripts/claude-multi-setup.sh`),
`install.sh`, `.claude-plugin/` (plugin + marketplace manifests), `tests/`, `docs/`.

License: MIT.
