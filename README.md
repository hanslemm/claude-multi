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
At the end it offers to append the rc line and to log each account in; answer `n` to do either later.

```sh
curl -fsSL https://raw.githubusercontent.com/hanslemm/claude-multi/main/install.sh | sh
```

Plugin: from inside Claude Code.

```
/plugin marketplace add hanslemm/claude-multi
/plugin install claude-multi@claude-multi
```

All three end in the same place: `~/.claude-multi/claude-multi-setup.sh` installed, one directory per
account under `~/.claude-accounts/`, and `~/.claude-multi/aliases.sh` ready to be sourced. Open a new
terminal (or `source ~/.claude-multi/aliases.sh`), then `claude-multi login --all` — it walks every
account that is not logged in yet through Claude Code's own browser login, one at a time; the tool
never copies a login.

## Daily use

| Command | What it does |
|---|---|
| `claude-<slug> [args]` | start Claude Code as that account; extra arguments pass through to `claude` |
| `claude1` … `claudeN` | the same, by slot number |
| `cuse <slug\|slot>` | pin this terminal to an account (exports `CLAUDE_CONFIG_DIR` and `CLAUDE_MULTI_ACCOUNT`); plain `claude`, and any script that runs `claude`, then use it |
| `cuse default` | unpin this terminal (back to `~/.claude`); both variables are unset |
| `cwho` | which account this terminal is on, plus the login state of every account |
| `claude-multi use <slug\|slot\|default>` | the same as `cuse` |
| `claude-multi who` | the same as `cwho` |
| `claude-multi add <email> [--slot N]` | register an account and create its dir + launcher |
| `claude-multi remove <email>` | drop the launcher; the account dir and its login are kept |
| `claude-multi status [--verify]` | script path, cswap, shared dir, rc line, this terminal, every account, what to do next; `--verify` asks `claude auth status` under each account dir instead of guessing from `.claude.json` (Claude Code may leave its own first-start `.claude.json` in a dir that was never started; harmless) |
| `claude-multi login <slug\|slot\|email>` | log that account in: `claude auth login --email <email>` under its dir (opens a browser), then confirms with `claude auth status` |
| `claude-multi login --all` | the same for every account that is not logged in yet, in slot order |
| `claude-multi update [--dry-run]` | download the latest script from GitHub (`CLAUDE_MULTI_REF` picks a branch or tag), install it and re-run setup so `aliases.sh` gains any new commands |
| `claude-multi setup [--dry-run] [--rc[=FILE]] [--no-input]` | (re)run setup; `claude-multi help` lists the verbs, `~/.claude-multi/claude-multi-setup.sh --help` the flags |
| `claude-multi relink` | recreate the shared + memory symlinks inside the existing account dirs (a repo that gained memory later) |
| `claude-multi help` | the verb table |

`claude-multi` is a shell function defined in `aliases.sh`, so it needs a sourced terminal; the
long form `~/.claude-multi/claude-multi-setup.sh <verb>` works everywhere except for `use` and `who`,
which have to run in your shell to change it.

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
| `claude agents` fleet view, background jobs, `/tasks`, `--resume`, the daemon | per account dir | per account — Claude Code keeps that registry inside the config dir, so a view opened as one account lists only that account's sessions and jobs; `cswap list` still shows every running instance, because it scans processes rather than a registry |
| `~/.claude`, `~/.claude.json` | the default account | never modified; read once as the seed for `~/.claude-shared` |

## Prompt and status line

`cuse` exports `CLAUDE_MULTI_ACCOUNT=<slug>` next to `CLAUDE_CONFIG_DIR` (and `cuse default` unsets
both), so a prompt can show which account the terminal is pinned to. Put the line after the rc line
that sources `aliases.sh`:

```sh
# zsh (~/.zshrc)
setopt prompt_subst
PROMPT='${CLAUDE_MULTI_ACCOUNT:+[$CLAUDE_MULTI_ACCOUNT] }'$PROMPT

# bash (~/.bashrc)
PS1='${CLAUDE_MULTI_ACCOUNT:+[$CLAUDE_MULTI_ACCOUNT] }'"$PS1"
```

The single quotes matter: the variable is expanded when the prompt is drawn, so the tag appears and
disappears as you `cuse` and `cuse default`. zsh only does that expansion with `prompt_subst` on
(oh-my-zsh and most prompt themes set it already; without it the prompt shows the literal `${…}`).

Inside Claude Code, a `statusLine` can name the account too. The status-line command runs with the
session's environment, and `CLAUDE_CONFIG_DIR` is set whenever a launcher or `cuse` started that
session, so its basename is the slug (the launchers set the variable even in an unpinned terminal, so
this works for `claude-<slug>` as well as for `cuse` + `claude`). In `~/.claude-shared/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "printf '%s' \"${CLAUDE_CONFIG_DIR:+[${CLAUDE_CONFIG_DIR##*/}] }\"; jq -r '.model.display_name'"
  }
}
```

`jq -r '.model.display_name'` reads the JSON Claude Code pipes into the status-line command; drop it,
or replace it with your own script, if you already have one. An unpinned session prints no tag.

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
  keeps them. `claude-multi login` unsets the same three around `claude auth login`. The setup warns
  if the seeded `~/.claude-shared/settings.json` carries an `env.ANTHROPIC_API_KEY` or `apiKeyHelper`,
  since `--settings` would re-inject it on every launch.
- **One login per account, never a migration.** The Keychain key derivation is undocumented, so
  tokens are never copied between directories. Each account is logged in once, interactively —
  `claude-multi login <slug>` runs `claude auth login --email <email>` with `CLAUDE_CONFIG_DIR` set to
  that account's dir and confirms the result with `claude auth status`; `/login` inside
  `claude-<slug>` does the same thing by hand.
- **Memory is shared.** For every `~/.claude/projects/<p>/memory/` that exists, each account gets a
  symlink to it. The canonical folder stays in `~/.claude`; nothing is moved. `claude-multi relink`
  picks up a repo that gained memory later.
- **Idempotent and safe.** A re-run with nothing new prints `No changes — everything was already in
  place.` and leaves the filesystem byte-identical. The tool never deletes an account dir, never
  overwrites a seeded shared file, never modifies `~/.claude` or `~/.claude.json`, never touches an
  rc file without `--rc` or your `y` at the prompt, never leaves the cswap export on disk, never
  migrates credentials, never prints tokens. `--dry-run` prints every change and creates nothing, not
  even `~/.claude-multi`. `update` refuses a download that is not this script and leaves the
  installed copy untouched.

## FAQ

### Why not `cswap run`?

`cswap run` is claude-swap's own answer to the same wish, and its help text describes it as
`[EXPERIMENTAL] Launch Claude Code as a stored account in this terminal only (the default login and
other terminals are unaffected).` Its README puts it this way: "Launch Claude Code as a specific
account in the current terminal only — every other terminal and the VS Code extension stay on your
default account, so two accounts can work in parallel", and "Sessions use your normal `~/.claude`
setup (settings, CLAUDE.md, skills, MCP servers, etc.), but each account keeps its own chat history".
It takes a slot number or an email, forwards everything after `--` to `claude`, can map a directory to
an account (`cswap map`), and has `--share-history`, `--no-share` and `--require-session` switches.
The README does not spell out how the per-terminal session is built (whether it is a separate config
directory, a copied profile, or something else), and this project has not read cswap's source, so
nothing here claims to know — only what the two tools promise differs.

The difference is what each launch is:

- **`cswap run` is one launch.** It starts Claude Code as a stored account for the length of that
  command, in that terminal. claude-swap's model stays one default login that `cswap switch` rotates
  plus a stored backup per account; `run` borrows an account for a session. Its README also notes
  that running the account that is already the default login launches plain `claude` on that login
  (hence `--require-session`), and that `cswap switch` refuses to move onto an account whose session
  is still running when the stored backup has fallen behind.
- **claude-multi is a permanent config dir plus credential per account.** Every account is logged in
  once and stays logged in, side by side, no rotation and nothing to capture back. Bare `claude` —
  and any script, editor integration or hook that runs `claude` — follows `cuse`, because the pin is
  an exported `CLAUDE_CONFIG_DIR`, not a wrapper around one command. Settings, MCP servers,
  CLAUDE.md, commands, agents, skills and per-repo memory are shared by design; sessions, `--resume`,
  the `claude agents` fleet view and background jobs are per account, which is Claude Code's own
  design for a config dir. None of it needs cswap installed.

cswap remains a fine way to *discover* the accounts: when it is in `PATH`, setup reads its list and
you never type an email. Keep using it for what it does well; just do not `cswap switch` in one
terminal expecting the others to stay put.

### Does `cuse` affect other terminals?

No. It exports two variables in the shell where you ran it. A new terminal starts unpinned (the
default account) unless your rc file runs `cuse` itself.

### Where do plugins go?

Per account, into `~/.claude-accounts/<slug>/plugins/`. The first start of an account installs them,
so it may take a moment.

## Requirements

- macOS or Linux; bash 3.2 or newer to run the script (`/bin/bash` on macOS is fine)
- zsh or bash as the interactive shell (`aliases.sh` is sourced by both)
- Claude Code installed (`claude` in `PATH`); `claude-multi login` and `status --verify` use its
  `claude auth login` / `claude auth status` subcommands
- `curl` or `wget` for `claude-multi update`
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

- `tests/harness.sh` — the test matrix (T1–T23 in the contract); builds a throwaway `HOME` per case
  with a stub `claude` and a stub `cswap`. Run it with `/bin/bash tests/harness.sh` (bash 3.2 on
  macOS) and with `bash tests/harness.sh`.
- CI (`.github/workflows/ci.yml`): macOS + Ubuntu, `bash -n`, `shellcheck -S warning -s bash` on the script and
  the harness, `sh -n install.sh`, then the harness under both bash versions.
- The contract is [`docs/design.md`](docs/design.md): flags, file formats, output shapes, safety
  invariants. When a file disagrees with it, the file is the bug.
- One version number everywhere: `VERSION` in the script, `version` in both `.claude-plugin/*.json`,
  and the git tag. `claude-multi-setup.sh --version` prints it bare.

Layout: `skills/claude-multi/` (the skill: `SKILL.md` + `scripts/claude-multi-setup.sh`),
`install.sh`, `.claude-plugin/` (plugin + marketplace manifests), `tests/`, `docs/`.

License: MIT.
