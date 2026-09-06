---
title: One Claude Code login per terminal
published: false
description: claude-multi gives each Claude account its own CLAUDE_CONFIG_DIR and credential, shares settings, MCP servers, skills and memory across them, and pins a terminal to an account with one command.
tags: claude, cli, devtools, productivity
---

Claude Code keeps exactly one login per machine. It lives in `~/.claude` and `~/.claude.json`, and on macOS the credential sits in a Keychain entry keyed to that directory. Two subscriptions, a personal and a work account, or several accounts to spread rate limits over: whichever one is logged in is logged in everywhere.

Account switchers work around that by rotating which account occupies the slot. `cswap` (claude-swap) does it well, but a rotation is machine-wide: switch in one terminal and every other terminal, and the VS Code extension, switch with it. Running two accounts side by side is exactly the case that model cannot express.

**claude-multi** takes the other route: no rotation. Each account gets its own configuration directory and stays logged in; a terminal picks which one it uses.

## The mechanism is Claude Code's own

`CLAUDE_CONFIG_DIR` relocates the entire `~/.claude` tree and `~/.claude.json`. On macOS the Keychain entry is keyed to that directory too, so a session started with a different `CLAUDE_CONFIG_DIR` reads a different credential. On Linux the credential file lives inside the directory, so the isolation follows for free. One directory per account is therefore one login per account, and exporting the variable in a shell pins that shell.

Everything else in claude-multi is bookkeeping around that fact.

```
~/.claude-accounts/<slug>/   one CLAUDE_CONFIG_DIR per account: its login, sessions, plugins
~/.claude-shared/            settings.json, mcp.json, CLAUDE.md, commands/, agents/, skills/, output-styles/
~/.claude-multi/             the script, the generated aliases.sh, the account list
~/.claude                    untouched: the default account, read once as the seed
```

## Shared where it should be, and how

Sharing configuration across the directories is the part with traps.

`CLAUDE.md`, `commands/`, `agents/`, `skills/` and `output-styles/` are only ever read by Claude Code, so they are symlinked from every account directory into `~/.claude-shared`. `settings.json` is different: `/config` rewrites it, and a rewrite replaces a symlink with a plain file, silently un-sharing it. So `settings.json` and the MCP server list are passed on the command line instead, at a precedence above the per-directory files:

```
claude --mcp-config ~/.claude-shared/mcp.json --settings ~/.claude-shared/settings.json
```

Two details of that line are load-bearing. Both are root options, so they must come before any subcommand (`claude mcp list --settings x` is rejected). And `--mcp-config` is variadic: it keeps consuming arguments until it meets another option, so `--settings` follows it on purpose, to terminate the list before the user's own arguments start.

Per-repo auto-memory is shared too: for every `~/.claude/projects/<repo>/memory/` that exists, each account gets a symlink to it. The canonical folder stays in `~/.claude`; nothing is moved.

Per account, on purpose: the credential, `.claude.json` (sessions, per-project trust, servers added with `claude mcp add`), `plugins/`, history, and the `claude agents` fleet view with its background jobs. Claude Code keeps that registry inside the config directory, so a fleet view opened as one account lists that account's sessions only.

| What | Shared? | How |
|---|---|---|
| `settings.json`, `mcp.json` | yes | `--settings` / `--mcp-config` flags on every launch |
| `CLAUDE.md`, commands, agents, skills, output styles | yes | symlinks into each account dir |
| per-repo memory | yes | symlink to `~/.claude/projects/<repo>/memory` |
| login, `.claude.json`, plugins, sessions, fleet view | no | per account dir |

## Daily use

`aliases.sh` is generated once and sourced by zsh or bash:

```
claude-work                  # run Claude Code as the "work" account, this command only
claude2                      # the same, by slot number
cuse work                    # pin this terminal: bare `claude`, and any script that runs it, follow
cuse default                 # unpin
cwho                         # which account is this terminal on, plus every account's login state
claude-multi login --all     # log in every account that is not logged in yet
claude-multi add x@y.com     # register another account
claude-multi status --verify # ask Claude Code itself which accounts are logged in
```

`cuse` exports `CLAUDE_CONFIG_DIR` and `CLAUDE_MULTI_ACCOUNT`, so a prompt can show the account:

```sh
PROMPT='${CLAUDE_MULTI_ACCOUNT:+[$CLAUDE_MULTI_ACCOUNT] }'$PROMPT
```

## The API key that outranks your login

`ANTHROPIC_API_KEY` outranks a subscription login in Claude Code's credential precedence. A launcher that inherits it silently bills the API instead of using the account, with nothing on screen to say so. The launchers unset it, together with `ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN`, inside their own subshell; the shell keeps its variables. Setup also warns when the seeded `settings.json` carries an `env.ANTHROPIC_API_KEY` or `apiKeyHelper`, because `--settings` would re-inject it on every launch.

## Logins are never copied

The natural shortcut, copying a stored token into each new directory's Keychain entry, is the one thing claude-multi refuses to do. The key derivation for those entries is undocumented, and guessing it is not acceptable for a credential. Each account is logged in once, interactively:

```
claude-multi login work
```

runs `claude auth login --email <that account's email>` under the account's directory; the browser opens with the email pre-filled, and `claude auth status` confirms the result. `login --all` walks every account that is not logged in yet, in order.

## Install

Three paths, same result:

```sh
# guided, inside Claude Code: install the skill, then type /claude-multi
npx skills add hanslemm/claude-multi -g

# manual: the script asks for the accounts, offers the rc line, offers each login
curl -fsSL https://raw.githubusercontent.com/hanslemm/claude-multi/main/install.sh | sh

# plugin, inside Claude Code
/plugin marketplace add hanslemm/claude-multi
/plugin install claude-multi@claude-multi
```

If `cswap` is installed, its account list is discovered and no email is typed. Setup is idempotent: a second run with nothing new prints `No changes — everything was already in place.` and leaves the filesystem byte-identical. `--dry-run` prints every change and creates nothing. Setup never deletes an account directory, never modifies `~/.claude`, and never touches a shell rc file without `--rc` or a `y` at the prompt.

## What it deliberately does not do

- No machine-wide switch. A terminal is pinned, or it is on the default account. That is the point.
- No token migration. One browser login per account.
- No cross-account fleet view; Claude Code's session registry is per config directory.

## How it is tested

The behaviour is written down first, in a contract (`docs/design.md`: flags, file formats, exact output lines, the safety invariants), and a 23-case harness asserts it. Every case builds a throwaway `HOME` with stub `claude` and `cswap` binaries and covers discovery from JSON, from a token-bearing export that must never leave a mode-700 temp dir, and from ANSI-coloured output; the slug collision rules; idempotence down to mtimes; the memory links; `update` refusing a truncated download. It runs under `/bin/bash` 3.2 on macOS and bash 5 on Ubuntu in CI, with shellcheck.

MIT. Source, contract and issues: https://github.com/hanslemm/claude-multi
