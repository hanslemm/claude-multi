---
name: claude-multi
description: Guided installer for claude-multi, which gives each terminal its own Claude Code login (one CLAUDE_CONFIG_DIR per account, shared settings, MCP servers and memory) so a personal and a work subscription, or several accounts, can run side by side. Use when the user has two or more Claude subscriptions or accounts (a Max and a Pro, personal and work) and wants to use both at once, wants to log in as another account without logging the first one out, wants to switch account per terminal, says cswap / claude-swap switches every terminal, mentions CLAUDE_CONFIG_DIR, hits a rate limit and wants to use their other account, asks which account am I on, or wants to add or remove an account from claude-multi.
license: MIT
compatibility: macOS or Linux, zsh or bash, Claude Code installed, and a terminal the user can type into for the one-time browser logins.
metadata:
  author: hanslemm
  repository: https://github.com/hanslemm/claude-multi
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/claude-multi-setup.sh *) Bash(${HOME}/.claude-multi/claude-multi-setup.sh *)
---

# claude-multi — one Claude Code login per terminal

## Mental model

- Claude Code keeps ONE login in `~/.claude` + `~/.claude.json` (macOS: a Keychain entry keyed to that directory). Rotators like `cswap` swap it for every terminal at once.
- `CLAUDE_CONFIG_DIR` relocates that whole tree, so one directory per account (`~/.claude-accounts/<slug>/`) means one login per directory; a terminal that exports the variable is pinned to that account.
- Shared things live in `~/.claude-shared/` (settings, MCP servers, CLAUDE.md, commands, agents, skills, output styles) and per-repo memory stays in `~/.claude`, linked into every account.
- Logins cannot be copied between directories. Each account logs in ONCE, by the user, with `/login`. You cannot do that step.

## Script location

Use the first path that exists, in this order:

1. `${CLAUDE_SKILL_DIR}/scripts/claude-multi-setup.sh`
2. `scripts/claude-multi-setup.sh` next to this SKILL.md (when the placeholder is not substituted)
3. `~/.claude-multi/claude-multi-setup.sh` — the self-installed copy, present after the first run; every message the script prints refers to it

Call it `$SETUP` below. Always pass `--no-input`; the script prompts otherwise and you cannot answer a prompt.

## Guided flow

Run the steps in order. Report the script's output to the user at each step; do not paraphrase paths or commands.

### 1. Status

```
$SETUP status
```

Exit code is always 0; parse the `key: value` lines. Tell the user: whether `cswap` was found, whether the shared dir / aliases / rc line exist, which account this terminal is on (`terminal:`), the `account:` lines, and the `next:` hint. If everything is `ok` and `next: all accounts logged in`, skip to step 7.

### 2. Accounts

- `cswap: found at …` → accounts are discovered from cswap by the next setup or dry run; `status` does no discovery, so before the first setup there are no `account:` lines yet. Go to step 3 and read the accounts from the dry run's `Accounts (source: cswap …):` block.
- `cswap: not found` and no `account:` lines → ask the user for the email of EACH Claude account they want. Never guess or infer an email. `add` WRITES immediately (it is the setup pass: dir, symlinks, shared files, aliases), so preview each one first and ask for a go:

```
$SETUP add <email> --dry-run --no-input     # shows the `[dry-run] would …` lines for that account; writes nothing
$SETUP add <email> --no-input               # only after the user's go
```

An email that is already registered is a no-op. Use `--slot N` only if the user asks for a specific number. After the real `add`s, steps 3–4 print `No changes — everything was already in place.`; run them anyway, they are the confirmation that nothing is left to do.

### 3. Dry run

```
$SETUP --dry-run --no-input
```

Show the user the `[dry-run] would …` lines verbatim: which dirs, symlinks, shared files and aliases would be created. Nothing is written by this command, not even `~/.claude-multi`. Ask for a go before continuing.

### 4. Setup

```
$SETUP setup --no-input
```

Show the summary: `Accounts (source: …)`, `Shared config`, `Shared memory`, `Aliases`, `rc file`, and the `One-time login` list. A re-run prints `No changes — everything was already in place.` and touches nothing.

### 5. Shell rc line

The rc file is never touched without `--rc`. Ask the user first: "May I append one line to your shell rc file so the launchers load in every new terminal?" Only on a yes:

```
$SETUP --rc --no-input          # picks ~/.zshrc or ~/.bashrc from $SHELL
$SETUP --rc=/path/to/file --no-input
```

On a no, show the line the summary prints and let them add it themselves. Either way, tell them to open a new terminal or run `source ~/.claude-multi/aliases.sh` before step 6.

### 6. One-time logins (the user does these)

You cannot log an account in: the browser flow needs a real terminal and a real browser. For EACH account with `not-logged-in`, give the user this, with the real slug and email filled in:

> In a new terminal run `claude-<slug>`, type `/login`, choose "Claude account with subscription", and in the browser pick or sign in as `<email>`. Then come back here.

After each one, confirm with `$SETUP status` and read its `account:` line and `next:` hint. Repeat until `next: all accounts logged in`. If an account still shows `not-logged-in`, see Troubleshooting.

### 7. Daily use

Explain, briefly:

| Command | Effect |
|---|---|
| `claude-<slug> [args]` | start Claude Code as that account (any `claude` arguments pass through) |
| `claude1`, `claude2`, … | the same, by slot number |
| `cuse <slug\|slot>` | pin THIS terminal to an account (`CLAUDE_CONFIG_DIR` exported); plain `claude` then uses it |
| `cuse default` | unpin; back to `~/.claude` |
| `cwho` | which account this terminal is on, plus the login state of every account |

Shared across accounts: `~/.claude-shared/settings.json` and `mcp.json` (passed as `--settings` / `--mcp-config` flags), `CLAUDE.md`, `commands/`, `agents/`, `skills/`, `output-styles/` (symlinked), and per-repo auto-memory (`~/.claude/projects/<p>/memory`, symlinked; a repo that gains memory later needs a re-run or `$SETUP --relink --no-input`).

Per account, never shared: the login, `.claude.json` (sessions, per-project trust, MCP servers added with `claude mcp add`), history, and `plugins/`. Plugins install themselves per account on the first start of that account; the first launch may take a moment.

Settings changes go in `~/.claude-shared/settings.json`; a change made through `/config` inside one account lands in that account's own file and is not shared.

### 8. Later: add or remove an account

```
$SETUP add <email> --no-input        # then step 6 for the new account
$SETUP remove <email> --no-input     # launcher disappears; the dir and its login are KEPT
$SETUP status
```

After `add`, the user must open a new terminal (or re-source `aliases.sh`) to see the new launcher, then do the `/login` for it. After `remove`, if cswap still lists the email the script says so — it returns on the next run until removed there too.

## Rules

- Never migrate, copy or read tokens or credentials; never touch `~/.claude`, `~/.claude.json`, the Keychain, or a `.credentials.json`.
- Never edit an rc file yourself and never pass `--rc` without the user's explicit yes in this conversation.
- Never set or export `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `CLAUDE_CODE_OAUTH_TOKEN` for these accounts: they outrank the subscription login (the API key bills the API). The launchers unset all three in their subshell on purpose.
- Never run `cswap switch` (or any rotator) as a substitute: that changes every terminal, which is the problem this tool removes.
- Never delete an account dir under `~/.claude-accounts/`; `remove` keeps it on purpose.
- Never run the script without `--no-input`; a prompt you cannot answer hangs the session.
- Never invent an email; ask.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `status` says `not-logged-in` right after the user logged in | They ran `/login` in a terminal where `CLAUDE_CONFIG_DIR` was not exported (plain `claude`, or a terminal opened before the rc line). Repeat in a new terminal via `claude-<slug>`. |
| Usage is billed to the API, not the subscription | `ANTHROPIC_API_KEY` is set in the shell (unset it in the rc file; the launchers strip it, but `cuse` + plain `claude` does not), or `~/.claude-shared/settings.json` carries an `env.ANTHROPIC_API_KEY` / `apiKeyHelper` — the script warns about the file; remove the key from it. |
| Plugins missing in one account | Plugins are per account; the first start of that account installs them. Start it once and wait. |
| `cwho` shows `not managed by claude-multi` | Something else sets `CLAUDE_CONFIG_DIR` (rc file, direnv, an IDE). Remove that export or run `cuse <slug>` to override it for this terminal. |
| A settings change is not shared | It was made with `/config`, which writes the account's own file. Edit `~/.claude-shared/settings.json` instead. |
| `claude-<slug>: command not found` | `aliases.sh` is not sourced in this terminal. Open a new terminal, or `source ~/.claude-multi/aliases.sh`. |
| `error: could not find any Claude account.` | No cswap, no registry. Ask for the emails and use `add <email>` (step 2). |
