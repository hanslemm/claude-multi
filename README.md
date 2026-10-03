# claude-multi

[![CI](https://github.com/hanslemm/claude-multi/actions/workflows/ci.yml/badge.svg)](https://github.com/hanslemm/claude-multi/actions/workflows/ci.yml)

One Claude Code login per terminal.

Claude Code keeps a single login in `~/.claude` (and, on macOS, a Keychain entry keyed to that
directory). Account rotators such as `cswap` (claude-swap) swap that one login, so switching in one
terminal switches every terminal — a personal and a work subscription, or several accounts used to
spread rate limits, cannot run side by side. Claude Code's own isolation mechanism is
`CLAUDE_CONFIG_DIR`: it relocates the whole config tree and keys the credential to it. claude-multi
gives every account its own `CLAUDE_CONFIG_DIR`, a launcher, and a way to pin a terminal to it, while
settings, MCP servers, CLAUDE.md, commands, agents, skills, plugins and per-repo memory stay shared.

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
| `claude-<slug> [args]` | start Claude Code as that account; extra arguments pass through to `claude`. Also a real executable at `~/.claude-multi/bin/claude-<slug>`, so cron, CI, editors and tools that take a command from configuration can use it too |
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
| `claude-multi sync [--force [slug]] [--merge-local]` | copy the shared `settings.json` into every account's own file (permissions, auto mode, hooks); `--force` overwrites a copy edited through `/config`; `--merge-local` folds `~/.claude/settings.local.json` into the shared file first |
| `claude-multi update [--dry-run]` | download the latest script from GitHub (`CLAUDE_MULTI_REF` picks a branch or tag), install it and re-run setup so `aliases.sh` gains any new commands |
| `claude-multi setup [--dry-run] [--rc[=FILE]] [--no-input]` | (re)run setup; `claude-multi help` lists the verbs, `~/.claude-multi/claude-multi-setup.sh --help` the flags |
| `claude-multi relink` | recreate the shared + memory + plugins symlinks inside the existing account dirs, move a repo's new memory folder into `~/.claude-shared/memory`, and re-sync the settings (a repo that gained memory later; an account that moved its own `plugins/` aside) |
| `claude-multi help` | the verb table |

`claude-multi` is a shell function defined in `aliases.sh`, so it needs a sourced terminal; the
long form `~/.claude-multi/claude-multi-setup.sh <verb>` works everywhere except for `use` and `who`,
which have to run in your shell to change it.

`cswap` is optional: if it is in `PATH` its account list is discovered; otherwise the script asks for
emails, or takes them from `add <email>` or the `ACCOUNT_ROWS` environment variable.

## Running an account from another program

`claude-<slug>` is both a shell function and a real file at `~/.claude-multi/bin/claude-<slug>`.

The distinction matters the moment something other than your shell starts the process. `execvp` cannot
see shell functions, so cron jobs, CI steps, editor integrations and any CLI that reads a command out
of its own configuration would otherwise fail with `command not found` on a name that works when you
type it. Point them at the file:

```bash
~/.claude-multi/bin/claude-<slug> -p < prompt.txt
```

The bin directory is appended to `PATH` when `aliases.sh` is sourced, so a bare `claude-<slug>` also
works for anything launched from such a shell. Use the full path where no rc file is read — cron and
launchd are the usual cases.

Do not hand-roll the equivalent. The launcher unsets `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` and
`CLAUDE_CODE_OAUTH_TOKEN` before exec, because any of them outranks the account's subscription login
in credential precedence — an inlined `env CLAUDE_CONFIG_DIR=… claude` that forgets them keeps working
and quietly bills the API instead.

`cuse` remains shell-only by necessity: it exports `CLAUDE_CONFIG_DIR` into the *calling* shell, which
no separate process can do.

## What is shared, what is not

| Item | Where | How |
|---|---|---|
| `settings.json` | `~/.claude-shared/settings.json` | passed as `--settings` by the launchers; also copied into each account's own `settings.json` by setup / `claude-multi sync`, so bare `claude` after `cuse` has the same permissions and auto mode |
| MCP servers (`mcp.json`) | `~/.claude-shared/mcp.json` | passed as `--mcp-config` (merged with the account's own) |
| `CLAUDE.md`, `commands/`, `agents/`, `skills/`, `output-styles/` | `~/.claude-shared/<name>` | symlinked into every account dir |
| Per-repo auto-memory | `~/.claude-shared/memory/<p>/` | the real folder; `~/.claude/projects/<p>/memory` and every account's `projects/<p>/memory` are symlinks to it |
| Login / credentials | `~/.claude-accounts/<slug>/` (+ Keychain on macOS) | per account, never copied |
| `.claude.json` (sessions, per-project trust, `claude mcp add` servers) | per account dir | per account |
| Plugins (`plugins/`: installed set, marketplaces, cache) | `~/.claude/plugins` | symlinked into every account, once the default account has started Claude Code; which plugins are enabled comes from the shared `settings.json` |
| history, sessions | per account dir | per account |
| Trust dialog per repository | each account's `.claude.json` | per account; accept once per repo per account |
| `claude agents` fleet view, background jobs, `/tasks`, `--resume`, the daemon | per account dir | per account — Claude Code keeps that registry inside the config dir, so a view opened as one account lists only that account's sessions and jobs; `cswap list` still shows every running instance, because it scans processes rather than a registry |
| `~/.claude`, `~/.claude.json` | the default account | read once as the seed for `~/.claude-shared`; never modified, with one exception: per-repo memory folders move out and a link stays behind (see "Memory is shared") |

## Permissions, auto mode and prompts

Two things decide whether a session prompts you:

- **The launchers** (`claude-<slug>`, `claude1…N`) pass `--settings ~/.claude-shared/settings.json`, so
  they always run with the shared `permissions` (allow rules, `defaultMode`), the auto-mode policy and
  the skip-prompt flags — whatever your default account has.
- **Bare `claude` after `cuse`** reads the account's own `~/.claude-accounts/<slug>/settings.json`.
  Claude Code writes only `{"theme": …}` there on first start, so setup copies the shared file into it
  (keeping the account's theme), and `claude-multi sync` does it again whenever you change the shared
  file. A copy you edited inside that account (`/config`) is never overwritten unless you say
  `claude-multi sync --force <slug>`; `claude-multi status` counts `settings: <in sync>, <pending>, <modified>`.
- **`~/.claude/settings.local.json`** (user-level hooks and env) is folded into the shared file at
  first setup, or later with `claude-multi sync --merge-local`. Files the tool writes here are mode 600.
- **Never answer "Block" to the outside-read prompt.** It writes `permissions.blockReadsOutsideWorkingDirectories: true`
  into that account's own `settings.json`, after which every Bash command the shell parser cannot
  analyse (`node -e`, sed with braces) prompts, in every permission mode, workflow subagents included,
  until the key is removed and the session restarted. `setup`, `sync` and `status` warn when they see it.
- **Memory writes need two allow rules, and setup adds them.** `Edit(~/.claude-accounts/*/projects/*/memory/**)`
  covers the path an account session asks for and `Edit(~/.claude-shared/memory/**)` the file it
  resolves to; Claude Code applies an allow rule to a symlinked path only when both match. Setup,
  `relink` and `sync` append whichever is missing to `permissions.allow` in the shared file and change
  no other key or entry there. A copy you edited inside an account is still not overwritten, but it gains these
  two rules too. This needs `jq` or `python3`; without them a warning prints the two rules to add by hand.
- **Trust is per account per repository.** The trust dialog answer lives in each account's
  `.claude.json`, which the tool never touches, so accept it once per repo in each account; until then
  that repo's `.claude/settings.json` allow rules are ignored ("this workspace has not been trusted").

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
- **Memory is shared, and lives outside `~/.claude`.** The real folder for a repo is
  `~/.claude-shared/memory/<p>/`; `~/.claude/projects/<p>/memory` and every account's
  `projects/<p>/memory` are symlinks straight to it. Setup **moves** each memory folder it finds in
  `~/.claude` into that store and leaves a link behind — the one thing claude-multi moves out of
  `~/.claude`. The reason is Claude Code's own rule: `.claude` is a protected directory, a write that
  resolves into it asks for permission, and no allow rule can pre-approve it. While the folder stayed
  in `~/.claude`, every memory write from an account session prompted. The move never deletes or
  overwrites memory and never merges two folders: if both `~/.claude` and the store hold files for
  the same repo, nothing changes and a warning names both paths. `claude-multi setup --dry-run` shows
  the `would move …` lines first; `claude-multi status` prints `memory: <shared>, <still in ~/.claude>,
  <conflicts>`; `claude-multi relink` picks up a repo that gained memory later. To undo it for one
  repo, with no session open in it: `rm ~/.claude/projects/<p>/memory` (that is the link), then
  `mv ~/.claude-shared/memory/<p> ~/.claude/projects/<p>/memory`.
- **Plugins are shared.** Each account's `plugins/` is a symlink to `~/.claude/plugins`, so every account
  has the same installed plugins, marketplaces and cache, including plugins a repository enables in its
  `.claude/settings.json`; the shared `settings.json` says which are on. Claude Code writes into that
  directory from every account, which is the same situation as several terminals of one account. If
  `~/.claude/plugins` does not exist yet, start plain `claude` once, then `claude-multi relink`.
- **Idempotent and safe.** A re-run with nothing new prints `No changes — everything was already in
  place.` and leaves the filesystem byte-identical. The tool never deletes an account dir, never
  overwrites a seeded shared file (it only appends the two memory allow rules to the shared
  `settings.json`), never modifies `~/.claude` or `~/.claude.json` apart from moving the memory folders
  out as described above, never deletes or overwrites memory, never touches an
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
  CLAUDE.md, commands, agents, skills, plugins and per-repo memory are shared by design; sessions, `--resume`,
  the `claude agents` fleet view and background jobs are per account, which is Claude Code's own
  design for a config dir. None of it needs cswap installed.

cswap remains a fine way to *discover* the accounts: when it is in `PATH`, setup reads its list and
you never type an email. Keep using it for what it does well; just do not `cswap switch` in one
terminal expecting the others to stay put.

### Does `cuse` affect other terminals?

No. It exports two variables in the shell where you ran it. A new terminal starts unpinned (the
default account) unless your rc file runs `cuse` itself.

### Where do plugins go?

Into `~/.claude/plugins`, the default account's directory; every account's `plugins/` is a symlink to it,
so a plugin installed once is installed everywhere, and a plugin a repository enables in its
`.claude/settings.json` loads under every account without a second install. Whether a plugin is *on* is
another matter: that flag lives in `enabledPlugins` in `settings.json`, so to turn one on for every
account add it to `~/.claude-shared/settings.json` and run `claude-multi sync`. `/plugin install` inside
one account installs it for all but turns it on in that account's own settings file only.

Accounts set up before v1.3 keep their own `plugins/`; setup and `claude-multi status` say so
(`plugins: … own`) and the warning prints the `mv` that moves it aside. Close that account's sessions
first, run the `mv`, then `claude-multi relink`. The moved-aside directory keeps that account's plugin
data; delete it when you no longer want it. Until the default account has started Claude Code once,
`~/.claude/plugins` does not exist and nothing is linked; `status` says `plugins: … missing`.

## Requirements

- macOS or Linux; bash 3.2 or newer to run the script (`/bin/bash` on macOS is fine)
- zsh or bash as the interactive shell (`aliases.sh` is sourced by both)
- Claude Code installed (`claude` in `PATH`); `claude-multi login` and `status --verify` use its
  `claude auth login` / `claude auth status` subcommands
- `curl` or `wget` for `claude-multi update`
- Optional: `cswap` for automatic account discovery; `jq` or `python3` to extract MCP servers from
  `~/.claude.json` (without them `mcp.json` is seeded empty with a warning) and to add the two memory
  allow rules to the shared `settings.json` (without them a warning prints the rules to add by hand)

## Uninstall

1. Remove the rc line from `~/.zshrc` / `~/.bashrc` (or the `--rc=FILE` you chose):
   `[ -f "$HOME/.claude-multi/aliases.sh" ] && . "$HOME/.claude-multi/aliases.sh"`
2. `rm -rf ~/.claude-multi` (script, aliases, account registry).
3. **Move the memory back first.** `~/.claude-shared/memory/` holds the only copy of every repo's
   auto-memory; `~/.claude/projects/<p>/memory` is a link to it. With no Claude Code session open:

   ```sh
   for d in "$HOME"/.claude-shared/memory/*/; do
     d=${d%/}; l="$HOME/.claude/projects/${d##*/}/memory"
     [ -L "$l" ] && rm "$l"                    # the link the tool left behind
     [ -e "$l" ] || { mkdir -p "${l%/memory}" && mv "$d" "$l"; }
   done
   ```

   Anything still in `~/.claude-shared/memory/` afterwards was not moved (a real folder was already in
   the way); look at it before the next step. The accounts' own `projects/<p>/memory` links now point
   at nothing; they go away with the account dirs in step 5.
4. `rm -rf ~/.claude-shared` — only after step 3, and only if you do not want the shared settings, MCP
   config and CLAUDE.md any more; those are copies, the originals in `~/.claude` are untouched.
5. `~/.claude-accounts/<slug>/` holds each account's login and sessions (`plugins` is a symlink into
   `~/.claude`, so removing the account dir removes no plugin). Delete a directory
   only when you are done with that account (on macOS, also remove its `Claude Code-credentials`
   Keychain entry). The tool itself never deletes these.

Apart from the memory folders, `~/.claude` and `~/.claude.json` were never modified, so the default
account keeps working.

## Development

- `tests/harness.sh` — the test matrix (T1–T31 in the contract); builds a throwaway `HOME` per case
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
