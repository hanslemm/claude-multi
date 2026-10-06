---
name: claude-multi
description: Guided installer for claude-multi, which gives each terminal its own Claude Code login (one CLAUDE_CONFIG_DIR per account, shared settings, MCP servers, plugins and memory) so a personal and a work subscription, or several accounts, can run side by side. Use when the user has two or more Claude subscriptions or accounts (a Max and a Pro, personal and work) and wants to use both at once, wants to log in as another account without logging the first one out, wants to switch account per terminal, says cswap / claude-swap switches every terminal, mentions CLAUDE_CONFIG_DIR, hits a rate limit and wants to use their other account, asks which account am I on, wants to add or remove an account from claude-multi, asks about claude-multi login or logging an account in, asks whether an account is really logged in (status --verify), or wants to run claude-multi update.
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
- Shared things live in `~/.claude-shared/` (settings, MCP servers, CLAUDE.md, commands, agents, skills, output styles, and per-repo memory in `~/.claude-shared/memory/<repo>/`); plugins stay in `~/.claude/plugins`, linked into every account.
- Memory is the one thing the script MOVES out of `~/.claude`: `~/.claude/projects/<repo>/memory` goes to `~/.claude-shared/memory/<repo>` and a link stays behind, and every account links straight to the store. Memory that exists only inside one account (a repo first used through it) is adopted the same way and becomes visible to the other accounts. `.claude` is a protected directory in Claude Code, so while memory lived there every memory write from an account session asked for permission, whatever the allow rules said.
- The default account (`~/.claude`, plain `claude`) follows the shared folders: `~/.claude-shared/skills` and its siblings were copied from `~/.claude` once, so a skill, command, agent, output style or skills-folder plugin added from an account session reached every account and never the default one. The script gives `~/.claude/<dir>` a symlink to each shared entry it has no name for. It only adds links; a name that already exists there is never touched. `setup`, `relink`, every launcher and `cuse` do it, so nobody has to run anything.
- Logins cannot be copied between directories. Each account logs in ONCE, by the user, with `claude-multi login <slug>` (it runs `claude auth login` under that account's dir and opens a browser). You cannot do that step.

## Script location

Use the first path that exists, in this order:

1. `${CLAUDE_SKILL_DIR}/scripts/claude-multi-setup.sh`
2. `scripts/claude-multi-setup.sh` next to this SKILL.md (when the placeholder is not substituted)
3. `~/.claude-multi/claude-multi-setup.sh` — the self-installed copy, present after the first run; every message the script prints refers to it

Call it `$SETUP` below. Always pass `--no-input`; the script prompts otherwise (emails, the rc line, a login offer per account) and you cannot answer a prompt.

`claude-multi <verb>` is a shell function from `~/.claude-multi/aliases.sh` — the same script behind a short name (`claude-multi add …` = `$SETUP add …`), plus `use` / `who`, which change the caller's shell. It exists in the USER's terminal once the rc line is sourced. In your own Bash calls use `$SETUP` unless `type claude-multi` succeeds in that shell (a non-interactive shell rarely sources the rc file; from v1.6.1 the function works wherever it exists, on an older install it can exist and still fail, see Troubleshooting); when you tell the user what to type, use the `claude-multi` form.

## Guided flow

Run the steps in order. Report the script's output to the user at each step; do not paraphrase paths or commands.

### 1. Status

```
$SETUP status
```

Exit code is always 0; parse the `key: value` lines. Tell the user: whether `cswap` was found, whether the shared dir / aliases / rc line exist, the `default:` line (`pending` counts shared commands, agents, skills and output styles the default account has no link to yet; the next launcher, `cuse`, setup or relink adds them, and `off` means `CLAUDE_MULTI_DEFAULT_LINKS=0` is set), the `plugins:` line (`own` counts accounts that still keep their own `plugins/`, `missing` means the default account has never started Claude Code), the `memory:` line (`still in ~/.claude` and `in one account` count repos whose memory folder the next setup or relink will move into `~/.claude-shared/memory`; `conflicts` counts repos it will not touch, see Troubleshooting), which account this terminal is on (`terminal:`), the `account:` lines, and the `next:` hint. If everything is `ok` and `next: all accounts logged in`, skip to step 7.

### 2. Accounts

- `cswap: found at …` → accounts are discovered from cswap by the next setup or dry run; `status` does no discovery, so before the first setup there are no `account:` lines yet. Go to step 3 and read the accounts from the dry run's `Accounts (source: cswap …):` block.
- `cswap: not found` and no `account:` lines → ask the user for the email of EACH Claude account they want. Never guess or infer an email. `add` WRITES immediately (it is the setup pass: dir, symlinks, shared files, aliases), so preview each one first and ask for a go:

```
$SETUP add <email> --dry-run --no-input     # shows the `[dry-run] would …` lines for that account; writes nothing
$SETUP add <email> --no-input               # only after the user's go
```

(`claude-multi add <email> --dry-run --no-input` / `claude-multi add <email> --no-input` when the aliases are loaded in your shell.) An email that is already registered is a no-op. Use `--slot N` only if the user asks for a specific number. After the real `add`s, steps 3–4 print `No changes — everything was already in place.`; run them anyway, they are the confirmation that nothing is left to do.

### 3. Dry run

```
$SETUP --dry-run --no-input
```

Show the user the `[dry-run] would …` lines verbatim: which dirs, symlinks, shared files and aliases would be created. Nothing is written by this command, not even `~/.claude-multi`. Ask for a go before continuing.

If the output has `would move …/memory to …/.claude-shared/memory/…` lines, say so in plain words before asking: the real run moves those memory folders out of `~/.claude` (or out of the one account that holds them, which makes that account's notes for the repo visible to the other accounts) and leaves a link to each. Nothing is deleted or merged, and the undo is `rm` the link, then `mv` the folder back.

### 4. Setup

```
$SETUP setup --no-input
```

Show the summary: `Accounts (source: …)`, `Shared config`, `Shared memory` (it names `~/.claude-shared/memory/<repo>`), `Shared plugins`, `Default account`, `Aliases`, `rc file`, and the `One-time login` list. A `warning: memory conflict: …` line names two folders that both hold files for the same repo; relay both paths, the script changed neither (Troubleshooting). A `warning: … plugins exists and is not a symlink` line means that account keeps its own plugins dir (set up before v1.3); relay the `mv` the warning prints and see Troubleshooting. A re-run prints `No changes — everything was already in place.` and touches nothing. With `--no-input` the script asks nothing afterwards — the rc line is step 5 and the logins are step 6.

If Claude Code refuses this command (auto mode treats moving Claude's own memory folders, or editing its settings, as self-modification), do not work around it. Give the user the command with the real script path filled in, `<path of $SETUP> setup`, to run in their own terminal; there it also asks them about the rc line and the logins. Then continue from `$SETUP status`.

### 5. Shell rc line

The rc file is never touched without `--rc`. Ask the user first: "May I append one line to your shell rc file so the launchers load in every new terminal?" Only on a yes:

```
$SETUP --rc --no-input          # picks ~/.zshrc or ~/.bashrc from $SHELL
$SETUP --rc=/path/to/file --no-input
```

On a no, show the line the summary prints and let them add it themselves. Either way, tell them to open a new terminal or run `source ~/.claude-multi/aliases.sh` before step 6.

### 6. One-time logins (the user does these)

You cannot log an account in: `login` opens a browser and needs a real terminal. Never run `$SETUP login …` yourself — with `--no-input` it exits 2 and tells the user to run it, and without `--no-input` it would hang your session. For EACH account with `not-logged-in`, give the user this, with the real slug and email filled in:

> In a terminal where the aliases are loaded (a new one after step 5, or after `source ~/.claude-multi/aliases.sh`) run `claude-multi login <slug>`. It opens the browser; pick or sign in as `<email>`, come back, and the command prints `logged in as <email>`. Then come back here.

Several accounts: `claude-multi login --all` does them one after the other, in slot order, and stops at the first that fails.

After each one, confirm with `$SETUP status --verify` (it asks `claude auth status` under each account dir; the states read `logged-in (verified)` / `not-logged-in (verified)`) and read the `account:` line and the `next:` hint. Repeat until `next: all accounts logged in`. If an account still shows `not-logged-in`, see Troubleshooting.

### 7. Daily use

Explain, briefly:

| Command | Effect |
|---|---|
| `claude-<slug> [args]` | start Claude Code as that account (any `claude` arguments pass through) |
| `claude1`, `claude2`, … | the same, by slot number |
| `cuse <slug\|slot>` / `claude-multi use <slug\|slot>` | pin THIS terminal to an account (`CLAUDE_CONFIG_DIR` and `CLAUDE_MULTI_ACCOUNT` exported); plain `claude`, and scripts that run `claude`, then use it |
| `cuse default` / `claude-multi use default` | unpin; back to `~/.claude`; both variables unset |
| `cwho` / `claude-multi who` | which account this terminal is on, plus the login state of every account |
| `claude-multi status [--verify]` | script, cswap, shared dir, rc line, this terminal, every account, what to do next; `--verify` asks Claude Code instead of guessing |
| `claude-multi login <slug\|slot\|email>` / `login --all` | log an account in (browser); `--all` = every account not logged in yet |
| `claude-multi add <email>` / `remove <email>` | register / drop an account (step 8) |
| `claude-multi update [--dry-run]` | fetch the latest script from GitHub, install it, re-run setup |
| `claude-multi sync [--force [slug]] [--merge-local]` | copy the shared `settings.json` into every account's own file, so bare `claude` after `cuse` has the same permissions and auto mode; `--force` overwrites a copy edited via `/config`; `--merge-local` folds `~/.claude/settings.local.json` into the shared file |
| `claude-multi relink` | recreate the shared + memory + plugins symlinks, move a repo's new memory folder into `~/.claude-shared/memory`, add the default account's links to new shared entries, re-sync the settings (a repo that gained memory later; an account whose own `plugins/` was moved aside) |
| `claude-multi link-default [--dry-run]` | give `~/.claude` a link to every shared command, agent, skill and output style it has no name for; every launcher and `cuse` run it, so it is rarely typed |
| `claude-multi help` | the verb table |

`CLAUDE_MULTI_ACCOUNT` holds the slug of the pinned account, for a prompt: zsh `setopt prompt_subst; PROMPT='${CLAUDE_MULTI_ACCOUNT:+[$CLAUDE_MULTI_ACCOUNT] }'$PROMPT`, bash `PS1='${CLAUDE_MULTI_ACCOUNT:+[$CLAUDE_MULTI_ACCOUNT] }'"$PS1"` (single quotes, after the rc line; zsh expands the prompt only with `prompt_subst` on). The README shows a Claude Code `statusLine` that reads `${CLAUDE_CONFIG_DIR##*/}` too.

Shared across accounts: `~/.claude-shared/settings.json` and `mcp.json` (passed as `--settings` / `--mcp-config` flags), `CLAUDE.md`, `commands/`, `agents/`, `skills/`, `output-styles/` (symlinked), plugins (`~/.claude/plugins`, symlinked: one installed set, marketplace list and cache for every account, repo-enabled plugins included; which are on comes from the shared `settings.json`), and per-repo auto-memory (the real folder is `~/.claude-shared/memory/<p>`; `~/.claude/projects/<p>/memory` and each account's `projects/<p>/memory` are symlinks to it; a repo that gains memory later needs a re-run or `claude-multi relink` / `$SETUP --relink --no-input`).

The default account sees the shared `commands/`, `agents/`, `skills/` and `output-styles/` entries it has no name for through a link per entry in `~/.claude/<dir>` (one link for a whole folder it does not have). A name it already has stays its own, even when the shared copy differs; `CLAUDE.md` and the settings are not part of this.

Per account, never shared: the login, `.claude.json` (sessions, per-project trust, MCP servers added with `claude mcp add`), history, and — Claude Code's own design, the registry lives inside the config dir — the `claude agents` fleet view, background jobs, `/tasks`, `--resume` and the daemon: a view opened as one account lists only that account's sessions.

Settings changes go in `~/.claude-shared/settings.json`, then `claude-multi sync` (or `$SETUP sync --no-input`) copies them into every account's own file; the launchers pass the shared file as `--settings` regardless. A change made through `/config` inside one account lands in that account's own file, is not shared, and stops that account being synced until `sync --force <slug>`. Trust is per account per repository: the user accepts the trust dialog once per repo in each account, and until then that repo's `.claude/settings.json` allow rules are ignored.

### 8. Later: add or remove an account

The user types, in a terminal with the aliases loaded:

```
claude-multi add <email> [--slot N]     # then claude-multi login <slug> for it
claude-multi remove <email>             # launcher disappears; the dir and its login are KEPT
claude-multi status
```

When you do it for them, the same verbs on the script: `$SETUP add <email> --no-input` (preview with `--dry-run` first, as in step 2), `$SETUP remove <email> --no-input`, `$SETUP status`. After `add`, the user must open a new terminal (or re-source `aliases.sh`) to see the new launcher, then run `claude-multi login <slug>` for it (step 6). After `remove`, if cswap still lists the email the script says so — it returns on the next run until removed there too.

## Rules

- Never migrate, copy or read tokens or credentials; never touch `~/.claude`, `~/.claude.json`, the Keychain, or a `.credentials.json`. One exception, and it is the script's, not yours: `setup` and `relink` move each `~/.claude/projects/<repo>/memory` folder to `~/.claude-shared/memory/<repo>` and leave a link. Never do that move by hand, never merge two memory folders, and never run the real `setup` / `relink` (or `add` / `remove`, which run the same pass) before the user has seen the `would move` lines and said go. If Claude Code refuses the run, the user runs it; do not work around the refusal.
- The script also adds links inside `~/.claude/commands`, `agents`, `skills` and `output-styles` (and removes one of its own that leads nowhere). That too is the script's, not yours: never create, repoint or remove such a link by hand, and never copy a shared entry into `~/.claude`. `$SETUP link-default --no-input` moves nothing and is safe to run; show `$SETUP link-default --dry-run --no-input` first when the user asks what it will do.
- Never run `login` (`$SETUP login …`, `claude-multi login …`, `claude auth login`) yourself: it opens a browser and needs the user's terminal. Tell the user the command and confirm afterwards with `$SETUP status --verify`.
- Never run `update` (`$SETUP update`, `claude-multi update`) yourself: it replaces the script under the running skill. Tell the user the command; they run it in their terminal. `sync` is safe to run with `--no-input`; never pass `--force` without the user's explicit yes, since it overwrites settings they edited.
- Never edit an rc file yourself and never pass `--rc` without the user's explicit yes in this conversation.
- Never set or export `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or `CLAUDE_CODE_OAUTH_TOKEN` for these accounts: they outrank the subscription login (the API key bills the API). The launchers and `login` unset all three in their subshell on purpose.
- Never run `cswap switch` (or any rotator) as a substitute: that changes every terminal, which is the problem this tool removes.
- Never delete an account dir under `~/.claude-accounts/`; `remove` keeps it on purpose.
- Never run the script without `--no-input`; a prompt you cannot answer hangs the session.
- Never invent an email; ask.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `status` says `not-logged-in` but the user just logged in | Plain `status` guesses from the account's `.claude.json`. Run `$SETUP status --verify`; it asks `claude auth status` under that account's dir. If it still says `not-logged-in (verified)`, the login happened under a different `CLAUDE_CONFIG_DIR` (plain `claude` + `/login`, a terminal opened before the rc line, or another account's launcher). Repeat with `claude-multi login <slug>` — it sets the variable itself. |
| `status --verify` warns `claude not in PATH` | The states shown are the `.claude.json` heuristic. Put `claude` in `PATH` (or use the same shell the user runs Claude Code from) and re-run. |
| `error: login opens a browser and needs a terminal` | `login` was run with `--no-input` or without a tty — by you. That is by design: the user runs `claude-multi login <slug>`. |
| Usage is billed to the API, not the subscription | `ANTHROPIC_API_KEY` is set in the shell (unset it in the rc file; the launchers strip it, but `cuse` + plain `claude` does not), or `~/.claude-shared/settings.json` carries an `env.ANTHROPIC_API_KEY` / `apiKeyHelper` — the script warns about the file; remove the key from it. |
| Plugins missing, or `failed to load` in `/plugin`, in one account | That account keeps its own `plugins/` (set up before v1.3): `$SETUP status` shows `plugins: … own`, and setup / relink warn with the exact `mv` that moves the dir aside. The user closes that account's sessions, runs the `mv`, then `$SETUP --relink --no-input`; `status` then shows it as `shared`. If `status` says `plugins: … missing`, the default account has never started Claude Code: the user runs plain `claude` once, then relink. A plugin that is installed but off everywhere is turned on in `~/.claude-shared/settings.json` (`enabledPlugins`), then `$SETUP sync --no-input`. |
| Memory edits keep prompting ("allow Claude to edit …/memory/…?") | A memory write is pre-approved only when it does not resolve into `~/.claude` and both of its paths match an allow rule. Run `$SETUP status`. `memory: … still in ~/.claude` above 0: the folder has not been moved yet; the user runs `claude-multi setup` (preview with `--dry-run`). `conflicts` above 0: two places hold files for the same repo (`~/.claude/projects/<p>/memory` and `~/.claude-shared/memory/<p>`, or two accounts, or one account next to the shared folder), or a link points somewhere else; `setup` prints the paths. The user moves the files into one folder by hand so that the others are empty, then runs `claude-multi relink`. Never merge them yourself. Both counts 0 and it still prompts: check that `~/.claude-shared/settings.json` has `Edit(~/.claude-accounts/*/projects/*/memory/**)` and `Edit(~/.claude-shared/memory/**)` in `permissions.allow` (setup adds them; without `jq` or `python3` it prints a warning instead and they are added by hand), then `$SETUP sync --no-input`, and the user restarts that account's sessions. The two rules are about account sessions; plain `claude` on the default account asks for `~/.claude/projects/<p>/memory/…`, a path they do not match. On Claude Code 2.1.288 it was not prompted in auto mode; default mode is untested, so a prompt there is not a fault of the setup. |
| `cwho` shows `not managed by claude-multi` | Something else sets `CLAUDE_CONFIG_DIR` (rc file, direnv, an IDE). Remove that export or run `cuse <slug>` to override it for this terminal. |
| A settings change is not shared | It was made with `/config`, which writes the account's own file. Edit `~/.claude-shared/settings.json` instead, then run `$SETUP sync --no-input` (`--force <slug>` if that account's copy was edited). |
| Plain `claude` prompts for everything after `cuse`, but `claude-<slug>` does not | The account's own `settings.json` is out of sync with the shared file. Run `$SETUP sync --no-input`; `$SETUP status` shows `settings: … modified` when a copy was edited and needs `--force <slug>`. |
| Every `node -e` or sed command prompts, "under the read block (permissions.blockReadsOutsideWorkingDirectories)" | A "Block" answer to an outside-read prompt wrote that key into the account's `settings.json`; `$SETUP status` warns about it. Remove the key from the file it names (`sync --force <slug>` restores the shared copy), then the user restarts that account's sessions. Tell the user to answer Yes or "Ask again" to that prompt in future, never Block. |
| "this workspace has not been trusted" / repo allow rules ignored | Trust is per account per repository. The user opens that repo once with that account and accepts the trust dialog. |
| `claude-<slug>: command not found` / `claude-multi: command not found` | `aliases.sh` is not sourced in this terminal. Open a new terminal, or `source ~/.claude-multi/aliases.sh`. The long form `~/.claude-multi/claude-multi-setup.sh <verb>` works without it (except `use` / `who`). |
| `claude-multi:  is missing — re-run the setup script` with an empty path, or `command not found: _claude_multi_run` / `_claude_multi_find` / `_claude_multi_list` | An install older than v1.6.1 in a shell that has the functions of `aliases.sh` without its variables and helpers. Claude Code's own shell is one (it is built from a snapshot that keeps neither), so this is what you get from `claude-multi <verb>`, `cuse`, `cwho` or `claude-<slug>` in your own Bash calls and from a command the user types with `!`. Use `$SETUP <verb>`; `$SETUP status` prints the `version:`. The user runs `~/.claude-multi/claude-multi-setup.sh update` (the long form, since the short one is what fails); from v1.6.1 each of those functions loads `aliases.sh` itself. |
| `claude-multi update` says `downloaded file is not claude-multi-setup.sh` | The download was refused and the installed copy is untouched. Check `CLAUDE_MULTI_REF` (a branch or tag that exists) and the network, then retry. |
| `error: could not find any Claude account.` | No cswap, no registry. Ask for the emails and use `add <email>` (step 2). |
| A skill, command, agent or skills-folder plugin works in every account but not in plain `claude` | It was added to the shared folder after the one-time copy, and the default account has no link to it yet. `$SETUP status` shows `default: … pending`; `$SETUP link-default --no-input` adds the links (from v1.6 every launcher and `cuse` do, so this is only seen in a terminal where neither ran since). The session picks it up on its next start. `default: off` means `CLAUDE_MULTI_DEFAULT_LINKS=0` is set in that shell. If the default account already has an entry of that name (its own, possibly older copy), no link is made and nothing is replaced: the user renames or removes their copy in `~/.claude/<dir>`, then runs it again. |
