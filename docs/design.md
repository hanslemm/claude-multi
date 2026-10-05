# claude-multi — design and contract

One Claude Code login per terminal. This document is both the rationale and the **contract** every
file in this repository is built against: the script, the generated shell file, the tests, the skill
and the README all follow it. When they disagree, this file wins and the other file is the bug.

## 1. The problem

Account switchers such as `cswap` (claude-swap) rotate the ONE login Claude Code keeps in `~/.claude`
and the macOS Keychain. Switching in one terminal switches every terminal. Anyone with a personal and
a work subscription, or several accounts to spread rate limits over, hits this daily.

Claude Code's own isolation mechanism is `CLAUDE_CONFIG_DIR`: it relocates the whole `~/.claude`
tree and `~/.claude.json`, and on macOS it keys the Keychain credential entry to that directory, so a
session with a different `CLAUDE_CONFIG_DIR` reads a different credential. On Linux the credential
file lives inside the config dir, so the same isolation holds. One directory per account therefore
gives one login per directory, and a terminal that exports the variable is pinned to that account.

Three facts shape everything below (verified against Claude Code 2.1.x):

- `claude --settings <file>` loads settings at command-line precedence, above the user file.
  `claude --mcp-config <file>` MERGES with the config dir's own MCP servers (`--strict-mcp-config`
  would replace them; never used). Both are ROOT options: they must come before a subcommand
  (`claude mcp list --settings x` is rejected) and `--mcp-config` is VARIADIC, so `--settings` is
  placed right after it to terminate the list before the user's own arguments.
- `ANTHROPIC_API_KEY` outranks a subscription login in credential precedence. A launcher that does
  not remove it silently bills the API instead of using the account. `CLAUDE_CODE_OAUTH_TOKEN` (from
  `claude setup-token`) and `ANTHROPIC_AUTH_TOKEN` override the directory's login the same way, so
  the launcher unsets all three — inside its subshell only; the user's shell keeps its variables. A
  settings file passed with `--settings` re-injects an `env.ANTHROPIC_API_KEY` / `apiKeyHelper` on
  every launch, above that unset: the tool warns (naming the file, never a value) when the seeded
  `~/.claude-shared/settings.json` carries one.
- The Keychain key derivation is undocumented. Tokens are never migrated between directories; every
  account is logged in once, interactively, with `/login`. The tool must say so and never try to be
  clever here.

## 2. On-disk layout

| Path | Owner | Purpose |
|---|---|---|
| `~/.claude` , `~/.claude.json` | the user / cswap | the DEFAULT account, read as the seed. Untouched, with two exceptions: a `projects/<p>/memory` folder is moved to the store below and replaced by a link to it (v1.5, §16), and a link is added for each shared command, agent, skill and output style it has no name for (v1.6, §17) |
| `~/.claude-accounts/<slug>/` (mode 700) | the script creates; Claude Code fills | one `CLAUDE_CONFIG_DIR` per account; never deleted by the tool |
| `~/.claude-shared/` | the script seeds ONCE; the user edits | `settings.json`, `mcp.json`, `CLAUDE.md`, `commands/`, `agents/`, `skills/`, `output-styles/` |
| `~/.claude-shared/memory/<p>/` (v1.5, §16) | the script moves it there; Claude Code fills | the per-repo auto-memory folders: the real ones, one per project |
| `~/.claude-multi/claude-multi-setup.sh` | the script self-installs | stable path every message refers to |
| `~/.claude-multi/aliases.sh` | generated every run | launchers, `cuse`, `cwho`; sourced by zsh AND bash |
| `~/.claude-multi/accounts.tsv` | generated / `add` / `remove` | the account list and slug registry (§4) |
| `~/.claude-multi/rc-file` | written by `--rc` | the rc file the source line was appended to, so a custom `--rc=FILE` is found again |

Sharing model:

- **Symlinked** into every account dir (Claude only READS these): `CLAUDE.md`, `commands`, `agents`,
  `skills`, `output-styles` → `~/.claude-shared/<name>`.
- **Passed as flags, never symlinked**: `settings.json` (`--settings`) and `mcp.json`
  (`--mcp-config`). Claude Code rewrites `settings.json` when `/config` changes something; that would
  replace a symlink with a plain file and silently un-share it.
- **Per account, never shared**: `.claude.json` (session, per-project trust, user-scope MCP servers
  added with `claude mcp add`), history, sessions, credentials.
- **Per-repo auto-memory IS shared (v1.5, §16)**: the real folder is `~/.claude-shared/memory/<p>/`.
  `~/.claude/projects/<p>/memory` and each account's `projects/<p>/memory` are symlinks straight to
  it, one hop each. A folder found in `~/.claude` is moved into the store by `setup` and `--relink`:
  the one thing the tool moves out of `~/.claude`. Memory first created inside one account is adopted
  the same way (§16.7). A repo that gains memory later needs a re-run or `--relink`. (Up to v1.4 the folder stayed in `~/.claude` and only the accounts linked to it; §16
  says why that had to change.)
- **Plugins ARE shared (v1.3, §14)**: when `~/.claude/plugins` is a real directory (the default
  account has started Claude Code once), each account gets `plugins` as a symlink to it. One installed
  set, marketplace list and cache for every account; which plugins are enabled comes from
  `settings.json`, which is shared already. The canonical dir stays in `~/.claude`.
- **The default account follows the shared folders (v1.6, §17)**: the seeding below is a one-time
  copy, so an entry added to `~/.claude-shared/{commands,agents,skills,output-styles}` later reached
  every account and never `~/.claude`. `~/.claude/<dir>` gets a symlink to each shared entry it has no
  name for. Links are only added; nothing there is moved, overwritten or repointed.

Seeding (`~/.claude-shared`, first run only, each item independently, never overwritten afterwards):
`settings.json` = copy of `~/.claude/settings.json` (else `{}`); `mcp.json` = `{"mcpServers": …}`
extracted from `~/.claude.json` (jq, else python3; else `{"mcpServers": {}}` plus a warning), written
mode 600 because user-scope MCP servers carry `headers` / `env` tokens and `~/.claude.json` is 600;
`CLAUDE.md` = copy or empty file; each directory = `cp -R` of `~/.claude/<dir>` or an empty dir.

## 3. Command-line contract (`claude-multi-setup.sh`)

```
claude-multi-setup.sh [setup] [--dry-run] [--relink] [--rc[=FILE]] [--no-input]
claude-multi-setup.sh add <email> [--slot N] [setup flags]
claude-multi-setup.sh remove <email> [setup flags]
claude-multi-setup.sh status [--verify]
claude-multi-setup.sh login <slug|slot|email> | --all        (v1.1, §12)
claude-multi-setup.sh update [--dry-run]                     (v1.1, §12)
claude-multi-setup.sh sync [--force [<slug>]] [--merge-local] [--dry-run]   (v1.2, §13)
claude-multi-setup.sh link-default [--dry-run]               (v1.6, §17)
claude-multi-setup.sh --help | -h | --version
```

- `setup` (default): discover accounts (§4), seed shared config, move per-repo memory into the store
  (§16), create account dirs + symlinks + memory + plugins links, add the default account's links
  (§17), sync the settings (§13, §16.3), write
  `accounts.tsv`, generate `aliases.sh`, self-install, handle the rc line, print
  the summary. Idempotent: a re-run with nothing new prints `No changes — everything was already in
  place.` and leaves the filesystem byte-identical (mtimes included).
- `--dry-run`: every change is printed as `  [dry-run] would <action>`; nothing is created, not even
  `~/.claude-multi`.
- `--relink`: only the links and what they need: the shared + memory + plugins symlinks inside the
  account dirs that already exist, the memory move of §16.2 (a repo that gained memory since the last
  run), the default account's links (§17), and the settings step (§13.1), so the memory allow rules of
  §16.3 reach every account. No discovery, no aliases regeneration.
- `link-default`: the pass of §17 and nothing else. No discovery, no self-install, no `~/.claude-multi`
  created. Takes `--dry-run` only.
- `--rc` / `--rc=FILE`: append the source line (§7) to the rc file, once. Without the flag the rc
  file is NEVER touched; the summary prints the line to add instead.
- `--no-input`: never prompt (the interactive email prompt in §4 step 4 is skipped; exit 1 with the
  instructions instead). For AI-driven and scripted runs.
- `add <email> [--slot N]`: register an account in `accounts.tsv` (slot = N, or the lowest free
  slot ≥ 1), then run a normal setup pass so its dir, launcher and login command exist immediately.
  Adding an email that is already registered is a no-op followed by setup. `--slot` taken → error.
- `remove <email>`: delete its row from `accounts.tsv`, then run setup so the launchers disappear.
  The account dir and its login are KEPT and the summary says where they are. If cswap still lists
  the email, say so (it will come back on the next run until it is removed there too).
- `status`: no discovery, no writes, no network. Prints (exact shapes in §8): the script path and
  version, whether cswap is in PATH, whether the shared dir / aliases file / rc line exist, which
  account THIS terminal is on (from `CLAUDE_CONFIG_DIR`), then one `account` line per registered
  account with its login state, then a `next:` hint (what to run next). Exit 0 always, so callers
  parse the text — a registry row that repeats a slot is skipped with a warning here (setup treats it
  as the error §4 names).
- Exit codes: 0 ok · 1 error (message on stderr starting `error: `) · 2 usage.
- `ACCOUNT_ROWS` env var (`slot<TAB>email` lines; a space also separates) overrides discovery.
  Every discovery-failure message names it and `add`.

Portability: bash 3.2 (macOS `/bin/bash`), BSD and GNU userland. No `sed \+`, no `sed -i` without a
suffix, no `\t` in sed replacements, no associative arrays, no `mapfile`, no `${var,,}`. `jq` and
`python3` are optional accelerators, never requirements. Every path is absolute (`$HOME/…`); project
directory names start with `-`, so any command taking such a path must be safe (`ls -d -- …`).

## 4. Account discovery and the registry

Order, first non-empty wins for steps 1–2; step 3 is a union:

1. `$ACCOUNT_ROWS` if set.
2. `cswap` if in PATH: `cswap list --json` (numbers + emails, no tokens) → `cswap export <tmp>`
   (plaintext JSON that also carries OAuth tokens: written only inside a `mktemp -d` dir chmod 700,
   parsed, deleted before anything else runs; the dir is removed on exit by a trap) → the
   ANSI-stripped `cswap list` scraped for `N: email` lines (or every distinct email in order if no
   numbers are found). JSON is read by jq, else python3, else a grep/awk pairing of `"number"` and
   `"email"` keys in document order.
3. Union with `accounts.tsv` rows that carry a slot (accounts registered with `add`, or remembered
   from an earlier run). An email already present keeps the discovered slot. A registry slot that
   collides with a discovered one is moved to the lowest free slot. This is what makes the tool work
   without cswap and keeps an account that cswap forgot until `remove` is run.
4. Still empty and input allowed (no `--no-input`; stdin is a tty, or `/dev/tty` can be opened, so
   `curl … | sh` works): prompt `Enter the email of each Claude account, one per line; empty line to
   finish:` with `  1> ` style prompts, validate, assign slots 1..n.
5. Still empty: `error: could not find any Claude account.` followed by the three ways out
   (`ACCOUNT_ROWS`, `add <email>`, re-run without `--no-input`). Exit 1.

Rows are validated (`slot` digits, `email` matching `^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$`),
de-duplicated by email, sorted by slot; a slot listed twice is an error. A registry `slug` must match
`^[a-z0-9][a-z0-9-]*$` — it becomes a path component under `~/.claude-accounts` and a shell function
name in `aliases.sh` — so a row with any other slug is skipped with a warning.

`accounts.tsv` format (v2), rewritten in full whenever its content changes:

```
# claude-multi accounts: slot<TAB>email<TAB>slug. Edit with `claude-multi-setup.sh add|remove`.
1	alice@example.com	alice
2	hans@acme.test	hans-acme
```

A 2-column line (`email<TAB>slug`, the v1 format) is accepted on read as a row without a slot.
Rows for emails no longer discovered are kept (their dirs exist). A slug, once written, never
changes for that email.

Slugs: lower-cased local part, runs of non-`[a-z0-9]` → `-`, trimmed (`acct` when nothing is left,
e.g. `_@x.test`). Among NEW emails, a slug that
is already taken (registry, or another new email's base) gets `-<first domain label>` appended
(`hans@acme.test` → `hans-acme`); if still taken, `-<slot>`. Known emails keep their slug.

## 5. Account directories and links

For each account: `mkdir -p` + chmod 700; for each shared name, `<acct>/<name>` → absolute target.
Link handling: correct symlink → nothing; symlink to another target → repointed (`repoint`);
EMPTY real directory → replaced (`replace empty dir`); non-empty real file/dir → left alone with
`warning: <path> exists and is not a symlink; left alone (move it aside, e.g. mv '<path>' '<path>.unshared', then --relink, to share it)`.
Memory (§16): for each project whose folder is in the store, `mkdir -p <acct>/projects/<p>` (700) and
link `<acct>/projects/<p>/memory` → `~/.claude-shared/memory/<p>` with the same rules. A link that still
points at `~/.claude/projects/<p>/memory` (made by v1.4 or earlier) is therefore repointed.
Plugins (§14): when `~/.claude/plugins` is a real dir, link `<acct>/plugins` to it with the same rules;
when it is not, link nothing and warn once per run: `warning: ~/.claude/plugins does not exist yet, so
plugins are not shared; start plain claude once, then run --relink`.

## 6. `aliases.sh` — one file for zsh and bash

Generated in full every run into a temp file and installed only when it differs (so a no-op run
leaves it untouched). Must parse and work when sourced by zsh 5 and bash 3.2/5: no arrays in the
file, `printf` not `print`, `[ ]`/`[[ ]]` only in forms both shells share, functions with `-` in the
name (both allow it). Header comment says it is generated and lists the commands.

Contents:

- `CLAUDE_MULTI_ACCOUNTS_ROOT="$HOME/.claude-accounts"`, `CLAUDE_MULTI_SHARED_DIR="$HOME/.claude-shared"`,
  `CLAUDE_MULTI_SETUP="$HOME/.claude-multi/claude-multi-setup.sh"`.
- `_claude_multi_accounts` prints `slot slug email` lines (space separated, one per account, slot
  order). Lookups iterate this with `while read -r`.
- `_claude_multi_find <slug|slot>` prints the matching `slot slug email` line or nothing.
- `_claude_multi_logged_in <slug>`: true when `<acct>/.claude.json` contains `"oauthAccount"`.
- `_claude_multi_list`: header `Accounts (slot · launcher · email · login):` then one line per
  account: `  <mark> <slot>  claude-<slug padded>  <email padded>  <state>` where `<mark>` is `*`
  for the account this terminal is pinned to else a space, and `<state>` is `logged in` or
  `NOT logged in → run claude-multi login <slug>`.
- `_claude_multi_run <slug> [args…]`: resolves the real binary (`whence -p claude` in zsh,
  `type -P claude` in bash; error 127 if absent), errors 1 if the account dir is missing (naming
  `$CLAUDE_MULTI_SETUP`), then in a subshell: `unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN`,
  `export CLAUDE_CONFIG_DIR=<dir>`,
  `exec "$bin" --mcp-config "$SHARED/mcp.json" --settings "$SHARED/settings.json" "$@"`.
- `claude-<slug>() { _claude_multi_run <slug> "$@"; }` per account; `alias claude<slot>='claude-<slug>'`.
- `cuse <slug|slot>`: exports `CLAUDE_CONFIG_DIR` to the account dir and prints
  `This terminal: <slug> (<email>)  CLAUDE_CONFIG_DIR=<dir>`; adds `  not logged in yet: run  claude-multi login <slug>`
  when applicable and a note when `ANTHROPIC_API_KEY` (or one of the two other credential variables)
  is set. `cuse default|off|-` unsets the
  variable and prints `This terminal: default (~/.claude)`. No argument → usage on stderr, list on
  stderr, exit 2. Unknown → `cuse: no account '<x>'` on stderr, list on stderr, exit 1.
- `cwho`: first line `This terminal: default — ~/.claude (whatever the default login is)` when
  unpinned, `This terminal: <slug> (<email>)  CLAUDE_CONFIG_DIR=<dir>` when pinned to a known
  account, or `This terminal: CLAUDE_CONFIG_DIR=<dir> (not managed by claude-multi)`; a note when
  `ANTHROPIC_API_KEY` (or one of the two other credential variables) is set; then `_claude_multi_list`.
  Exit 0.
- Sourcing the file must not change the caller's `CLAUDE_CONFIG_DIR` or `ANTHROPIC_API_KEY`, and no
  command in it may leave a global behind (every `while read` loop declares its variables `local`:
  zsh runs the last pipeline stage in the calling shell).

## 7. rc line, self-install, legacy

- Line: `[ -f "$HOME/.claude-multi/aliases.sh" ] && . "$HOME/.claude-multi/aliases.sh"`
- Target: `--rc=FILE`, else by `$SHELL`: `*zsh` → `${ZDOTDIR:-$HOME}/.zshrc`, `*bash` → `$HOME/.bashrc`;
  any other shell → not appended, line printed with a note. Presence check: `grep -F 'claude-multi/aliases'`
  (matches the v1 `aliases.zsh` line too). Appended once, with a preceding blank line; the target path is
  then recorded in `~/.claude-multi/rc-file` (one path per line). With `--rc`, the check is the target
  alone (a user with two shells wants the line in both). Without it, and in `status`, "already sourced"
  looks, in order, at the remembered files, the `$SHELL` target, `~/.zshrc`, `~/.bashrc`,
  `~/.bash_profile`, `~/.profile`.
- Self-install: when the running script is not `~/.claude-multi/claude-multi-setup.sh` and that file
  is missing or differs, copy it there (mode 755). Reported as `install script to …`. A run fed on
  stdin (`curl … | bash`, `bash -c "$(…)"`) has no script file — `$0` resolves to the bash binary — so
  nothing is copied and a warning says to use `install.sh` instead.
- Legacy v1: an existing `~/.claude-multi/aliases.zsh` that carries the `GENERATED` marker is
  rewritten as a one-line shim sourcing `aliases.sh`, so an rc line from v1 keeps working.

## 8. Output shapes (asserted by the tests)

- Change lines: `  + <action>`; dry-run: `  [dry-run] would <action>`; warnings: `  warning: …` on
  stderr; the counter line `No changes — everything was already in place.` when nothing changed.
- Summary (setup): `Accounts (source: <source>):` + one `  <slot>  claude-<slug>  <email>  <dir>`
  line each; `Shared config: …`; `Shared memory: …`; `Shared plugins: …` (v1.3, §14); `Default account: …` (v1.6, §17.4); `Aliases: …`; `rc file: …`; then
  `One-time login, once per account …:` with `  claude-multi login <slug>  (<email>)` or
  `(already logged in)`.
- `status` lines, each `key: value` on its own line, in this order: `script:`, `version:`, `cswap:`
  (`found at <path>` | `not found (manual account list)`), `shared:` (`ok <dir>` | `missing`),
  `aliases:` (`ok <file>` | `missing`), `settings:` (`<n> in sync, <p> pending, <m> modified` — v1.2, §13),
  `plugins:` (`<n> shared, <o> own, <p> pending` | `<dir> missing (start plain claude once, then relink)` — v1.3, §14),
  `memory:` (`<n> shared, <m> still in ~/.claude, <a> in one account, <c> conflicts` — v1.5, §16.4),
  `default:` (`<n> linked, <p> pending` | `off (CLAUDE_MULTI_DEFAULT_LINKS=0)` | `<dir> missing` — v1.6, §17.4),
  `rc:` (`sourced from <file>` | `not sourced (run --rc)`),
  `terminal:` (`default` | `<slug> (<email>)` | `unmanaged <dir>`), then
  `account: <slot> <slug> <email> <logged-in|not-logged-in>` per registered account, then
  `next: <one sentence>` (e.g. `run claude-multi login <slug>` for the first not-logged-in account,
  `all accounts logged in` otherwise, or `run setup` when nothing is registered).

## 9. Safety invariants

Never delete an account dir · never overwrite a seeded shared file · never modify `~/.claude` or
`~/.claude.json` · never touch an rc file without `--rc` · never leave the cswap export on disk ·
never migrate or copy credentials · never print tokens · a re-run with nothing new changes nothing.

Two of these carry exceptions, each stated where it is made:

- **`~/.claude` (v1.5, §16).** `setup` and `--relink` move each `~/.claude/projects/<p>/memory` folder
  to `~/.claude-shared/memory/<p>` and leave a symlink to it in its place. It is the first and only
  thing the tool moves out of `~/.claude`, and `~/.claude.json` is still never touched. A memory folder first created inside an account dir is moved to the store the same
  way (§16.7); the account dir itself is still never deleted. Around both moves: never delete or
  overwrite memory · never merge two non-empty memory folders · roll the move back when the link cannot
  be made. The undo is one `mv` per project (§16.5).
- **`~/.claude` again (v1.6, §17).** `setup`, `--relink`, `link-default`, every launcher and `cuse`
  add a symlink in `~/.claude/{commands,agents,skills,output-styles}` for each shared entry that has no
  name there (or one link for a whole folder `~/.claude` does not have). Around it: never move, overwrite
  or repoint anything in `~/.claude` · never touch a name that exists there, whatever it holds · remove
  one thing only, a link this pass made that leads nowhere. The undo is `rm` of the link (§17.5), and
  `CLAUDE_MULTI_DEFAULT_LINKS=0` turns the pass off.
- **The shared `settings.json`.** The tool only ever adds to it, and only two things: the keys of
  `settings.local.json` (§13.2) and the two memory allow rules (§16.3). Nothing the user wrote there is
  changed or removed.

## 10. Test matrix (`tests/harness.sh`)

Bash harness, runs under bash 3.2 and 5, macOS and Linux. Each case builds a throwaway `HOME` under
`mktemp -d` with `bin/claude` (prints `stub claude CLAUDE_CONFIG_DIR=… KEY=… ARGS=…`, then a second line
`stub env AUTH_TOKEN=… OAUTH=…`) and a stub
`cswap` whose behaviour is chosen per case; `PATH` = `$HOME/bin:/usr/bin:/bin`. Asserts print
`ok:`/`FAIL:` lines; the harness exits non-zero on any failure and ends with `PASS <n>/<n>`.

| # | Case | Asserts |
|---|---|---|
| T1 | cswap `list --json` (4 accounts, two share local part `hans`) | 4 dirs 700, slugs `alice hans-acme info hans-mail`, 6 symlinks each to absolute targets (5 into `~/.claude-shared`, `plugins` into `~/.claude/plugins`), shared seeded (settings = the seed plus the two memory allow rules of §16.3, key order kept; skills copied, mcp.json from `~/.claude.json`, mode 600), `accounts.tsv` v2, `~/.claude` untouched, no rc change, `zsh -n` + `bash -n` on `aliases.sh` |
| T2 | export-only cswap (`list --json` fails) | same result, source `cswap export`, no `claude-multi.*` left under `$TMPDIR` |
| T3 | ANSI-only cswap | same result, source scraped |
| T4 | jq + python3 shadowed with failing stubs | same 4 accounts; warning about mcp.json |
| T5 | no cswap, `add a@x.test`, `add b@y.test --slot 5`, then `add a@x.test` again | slots 1 and 5, second add is a no-op, dirs + launchers exist |
| T6 | `ACCOUNT_ROWS` with a broken cswap in PATH | rows used, cswap never consulted |
| T7 | no cswap, no registry, `--no-input`, stdin not a tty | exit 1, message names `ACCOUNT_ROWS` and `add` |
| T8 | `--dry-run` on a fresh HOME | ≥1 `would` line, nothing created |
| T9 | second run | `No changes`, `find … -newer` finds nothing, aliases mtime unchanged; then edit the seeded `settings.json` + `CLAUDE.md`, run again → the edits survive (§9) |
| T10 | 5th account added in cswap (`alice@other.test`) | existing 4 dirs same inodes, new slug `alice-other`, `claude5` alias, registry gains one row |
| T11 | `--relink` after deleting one link | restored; no other change |
| T12 | memory (rewritten for v1.5, §16): repo-a (files), repo-b (empty), repo-c (no memory); alice has an empty real dir, bob a non-empty one | repo-a and repo-b moved into `~/.claude-shared/memory` (same inode, file intact, the store mode 700) with a link left in `~/.claude`; nothing else under `~/.claude` added or removed; alice replaced and linked to the store, bob warned + intact, repo-c skipped; summary names the store; a new repo is moved and linked by `--relink` |
| T13 | `--rc` twice with `SHELL=/bin/zsh`, then `SHELL=/bin/bash`, then `--rc=FILE`, then `SHELL=/bin/fish` | exactly one line in each target, second run `No changes`; `rc-file` holds the custom path and `status` reports `rc: sourced from` it; unknown shell → `not appended (unknown shell …)`, no rc file touched |
| T14 | source `aliases.sh` in zsh and in bash (`eval` after sourcing for aliases) | `cwho` unpinned/pinned lines, `cuse` by slug and by slot, `cuse nonexistent` → 1, `cuse default`, launcher passes `CLAUDE_CONFIG_DIR`, `KEY=<unset>` with `ANTHROPIC_API_KEY=x` exported (`AUTH_TOKEN`/`OAUTH` `<unset>` too), flag order `--mcp-config … --settings … <args>`, shell env unchanged after, no globals left by `cwho`/`cuse`/`_claude_multi_find` |
| T15 | `remove b@y.test`; `status` without cswap; then `remove` of an email a cswap stub still lists | row gone, launcher gone, dir still exists, message names the dir; `cswap: not found (manual account list)`; the `cswap still lists …` note |
| T16 | `status` before and after a fake login (write `{"oauthAccount":{}}` into one `.claude.json`) | line order per §8, `next:` changes |
| T17 | v1 2-column `accounts.tsv` + v1 `aliases.zsh` with GENERATED marker | slugs preserved, shim written, rc presence check accepts the old line |
| T18 | run from the repo path; then the script fed on stdin (`bash -s -- setup`) | self-installed copy at `~/.claude-multi/claude-multi-setup.sh`, identical, mode 755; the stdin run warns and leaves the copy identical |

CI (`.github/workflows/ci.yml`): matrix `macos-latest` + `ubuntu-latest`; install zsh + shellcheck
on ubuntu (`apt-get`) and shellcheck on macOS (`brew`); steps: `bash -n`, `shellcheck -S warning -s bash` on the
script and harness, `sh -n install.sh`, run the harness with `/bin/bash` and with `bash`.

## 11. Distribution

- `npx skills add hanslemm/claude-multi` (installs `skills/claude-multi/` incl. `scripts/`).
- `/plugin marketplace add hanslemm/claude-multi` then `/plugin install claude-multi@claude-multi`
  (plugin at the repo root: `.claude-plugin/plugin.json`; marketplace `source: "./"`).
- `curl -fsSL https://raw.githubusercontent.com/hanslemm/claude-multi/main/install.sh | sh`
  (POSIX `install.sh`: downloads the script into `~/.claude-multi`, chmod 755, `exec`s it with any
  arguments; `CLAUDE_MULTI_REF` selects a branch or tag). Interactive prompts read `/dev/tty`.
- The skill (`skills/claude-multi/SKILL.md`, Agent Skills spec frontmatter only) is the guided
  installer: `status` → gather accounts (cswap, or ask for emails → `add <email> --dry-run` shown →
  confirm → `add`, since `add` writes immediately) → `--dry-run` shown → confirm → setup → `--rc`
  only on approval → per-account `/login` walkthrough (the user must do it;
  Claude cannot) → `status` → daily usage explained. Script path: `${CLAUDE_SKILL_DIR}/scripts/…`,
  falling back to `scripts/claude-multi-setup.sh` next to `SKILL.md` when the placeholder is not
  substituted (other harnesses).

## 12. v1.1 additions — convenience layer

One version number everywhere: `VERSION` in the script, `version` in both `.claude-plugin/*.json`, and
the git tag (`v1.1.0`). The script's `--version` prints it bare.

### 12.1 `claude-multi` umbrella command (in `aliases.sh`, both shells)

`claude-multi <verb> [args…]` is a shell function, so it can change the caller's environment:

| Verb | Does |
|---|---|
| `use <slug\|slot>` / `use default` | exactly `cuse …` |
| `who` | exactly `cwho` |
| `add`, `remove`, `status`, `login`, `update`, `setup`, `relink`, `--dry-run`, … | `"$CLAUDE_MULTI_SETUP" "$@"` (every other argument list is passed through verbatim; `relink` maps to `setup --relink`) |
| `help`, `-h`, `--help`, no argument | prints the verb table above on stdout, exit 0 |

`cuse` additionally exports `CLAUDE_MULTI_ACCOUNT=<slug>`; `cuse default` unsets it together with
`CLAUDE_CONFIG_DIR`. Sourcing `aliases.sh` never sets either. The README shows a prompt snippet
(`${CLAUDE_MULTI_ACCOUNT:+[$CLAUDE_MULTI_ACCOUNT] }`) and a Claude Code `statusLine` hint that reads the
basename of `CLAUDE_CONFIG_DIR`.

### 12.2 `login <slug|slot|email>` and `login --all`

Resolves the account from `accounts.tsv` (unknown → `error: no account '<x>'` + the list, exit 1). `--dry-run` prints the plan (`[dry-run] would run claude auth login --email …`) and needs no terminal.
Needs `claude` in PATH (else exit 1 naming it) and a terminal: with `--no-input`, or when neither stdin
is a tty nor `/dev/tty` opens, it exits 2 with `error: login opens a browser and needs a terminal; run:
claude-multi login <slug>`. Otherwise it runs, in a subshell with `ANTHROPIC_API_KEY`,
`ANTHROPIC_AUTH_TOKEN` and `CLAUDE_CODE_OAUTH_TOKEN` unset and `CLAUDE_CONFIG_DIR=<account dir>`:

```
claude auth login --email <email>
```

(stdout/stderr inherited, and stdin too when it is a terminal; when stdin is not a terminal but `/dev/tty`
opens — the `curl … | sh` install path, where `install.sh` execs the script with the drained pipe on fd 0 —
the login reads `/dev/tty`, so the CLI's own URL and paste-code prompt reach the user). On exit 0 it then runs
`claude auth status` the same way and reports `logged in as <email>` when the JSON has `"loggedIn": true`
(and, when the JSON carries an email, warns if it is a different one: `warning: logged in as <other>,
expected <email>`); on a non-zero login exit it prints `login did not complete for <email>` and exits 1.
`--all` does this for every account whose **verified** state (`claude auth status`, §12.3) is `not-logged-in`,
in slot order, stopping at the first failure; the `.claude.json` heuristic is not consulted, so a stale
`oauthAccount` cannot hide a missing login. The account's login state line is printed after each (a skipped
account prints the `(verified)` line that skipped it).

### 12.3 `status --verify`

Same output as `status`, but each `account:` line's state comes from `claude auth status` run under
that account dir (`"loggedIn": true` → `logged-in (verified)`, anything else → `not-logged-in
(verified)`). An account whose dir is missing is `not-logged-in (verified)` without asking the CLI (which
would create the dir, mode 755, just to say so). When `claude` is not in PATH: heuristic states plus
`warning: claude not in PATH; login states are the .claude.json heuristic`. Exit 0 always. The script
itself writes nothing; Claude Code's own `auth status` may leave a first-start `.claude.json` (no
`oauthAccount`, so the heuristic still reads it as not logged in) in an account dir that was never started.

### 12.4 Interactive offers on the manual path

After the summary of `setup` and `add` — only when input is allowed (no `--no-input`, a tty or
`/dev/tty` available) and never under `--dry-run` or `--relink`:

1. If the rc line is not found anywhere (§7) and `rc_target` resolves: `Append the source line to
   <target>? [y/N] ` — `y`/`Y`/`yes` appends exactly as `--rc` would (and remembers it); anything else
   prints the line as today. When this offer will follow, the summary's `rc file:` line reads `not sourced
   yet (asked below)` instead of telling the user to add the line by hand.
2. For each account whose state is `not-logged-in`, in slot order: `Log in to <email> now? [Y/n] ` —
   empty, `y`, `Y`, `yes` runs the §12.2 login for it; `n`/`N`/`no` skips it; EOF stops asking. A login
   that does not complete ends nothing: the note `(later: <self> login <slug>)` follows and the next
   account is offered.

Prompts read from the same source as the email prompt (§4 step 4). **Test hook:** when
`CLAUDE_MULTI_INPUT=<file>` is set, every interactive prompt (emails, rc, logins) reads its answers
line by line from that file instead of the tty, and the tty check is considered satisfied. It is
documented only in the script header as internal.

### 12.5 `update`

Downloads `https://raw.githubusercontent.com/hanslemm/claude-multi/<REF>/skills/claude-multi/scripts/claude-multi-setup.sh`
(`REF` = `CLAUDE_MULTI_REF` or `main`, validated as in `install.sh`; `CLAUDE_MULTI_UPDATE_URL` overrides
the whole URL — the test hook) with `curl -fsSL`, else `wget -qO-`, else exit 1 naming both, into the
0700 temp dir. Refuses the download unless it contains the line `SCRIPT_NAME="claude-multi-setup.sh"`,
ends with the line `main "$@"` (a download cut at any earlier statement boundary still parses, and would
install a script that runs nothing) and passes `bash -n` (`error: downloaded file is not
claude-multi-setup.sh; installed copy untouched`, exit 1). Reads the new `VERSION=` line. If the file is byte-identical to `~/.claude-multi/claude-multi-setup.sh`:
`already up to date (<version>)`, exit 0. Else: `did "update <install path> <old> → <new>"`, installs
it (temp file then `mv`, mode 755), then runs `"$INSTALL_PATH" setup --no-input` so `aliases.sh`
gains any new functions, and — when that setup succeeded — ends with `reload the launchers in this
terminal: . ~/.claude-multi/aliases.sh  (new terminals pick them up from the rc line)`, since the shell
that ran `update` still has the old file loaded. `--dry-run` reports what would happen and installs nothing.

### 12.6 Tests added to §10

| # | Case | Asserts |
|---|---|---|
| T19 | umbrella + `CLAUDE_MULTI_ACCOUNT` in zsh and bash | `claude-multi who` ≡ `cwho`; `claude-multi use info` exports both variables; `claude-multi use default` unsets both; `claude-multi status` output ≡ script `status`; `claude-multi help` exit 0 with the verb table; `claude-multi relink` reaches `setup --relink` (stub-observable via `No changes`/`Done`) |
| T20 | `login` with a stub `claude` (records env + args; `auth status` prints `{"loggedIn": true}` once a marker file exists in `CLAUDE_CONFIG_DIR`, else `false`) | `login info` calls `auth login --email info@corp.test` under the info dir with all three credential vars unset; `login 4` and `login hans@mail.test` resolve; `login nonexistent` → 1; `login --no-input` → 2 with the message; `--all` visits only not-logged-in accounts in slot order; a stub that exits 1 → `login did not complete`, exit 1 |
| T21 | `status --verify` | states `(verified)` from the stub; without `claude` in PATH the heuristic + warning |
| T22 | interactive offers via `CLAUDE_MULTI_INPUT` | `y` appends the rc line once (and `rc-file` records it); `n` leaves it; login offers run the stub for accepted accounts only; `--no-input` asks nothing; `--dry-run` asks nothing and writes nothing |
| T23 | `update` with `CLAUDE_MULTI_UPDATE_URL=file://…` served through a stub `curl` in `$HOME/bin` | a newer file installs (`<old> → <new>`, mode 755, then setup runs), a second `update` says `already up to date`, a non-script download is refused and the installed copy is byte-identical afterwards, `--dry-run` installs nothing |

### 12.7 Docs

README: `claude-multi …` verbs replace the long script paths in the Daily-use table; a row in the
shared/per-account table for the `claude agents` fleet view, background jobs, `/tasks`, `--resume` and
the daemon (per account, Claude Code's own design); a "Why not `cswap run`?" FAQ written from cswap's
own README (state what `cswap run` does in its own terms, then the difference: one credential slot
rotated vs. one config dir + credential per account, all logged in at once, sessions and fleet view
per account); the prompt / statusLine snippet. SKILL.md: step 6 tells the user to run `claude-multi
login <slug>` (Claude never runs `login`: it opens a browser), confirms with `status --verify`; step
8 uses `claude-multi add|remove`; the daily-use table gains `claude-multi …`; the Rules gain "never run
`login` or `update` yourself" (update replaces the script under the running skill).

## 13. v1.2 — the permissions gap on the `cuse` path

Measured 2026-09-07: the launchers pass `--settings ~/.claude-shared/settings.json`, so
`claude-<slug>` runs with the shared `permissions` (allow rules, `defaultMode`), the auto-mode policy
and the skip-prompt flags. Bare `claude` after `cuse` does not: it reads `<account>/settings.json`,
which Claude Code creates on first start as `{"theme": "auto"}`, so a pinned terminal prompts like a
fresh install (auto-mode config showed 69 shipped rules there vs 73 with the shared file). The fix is
to keep each account's own `settings.json` equal to the shared file whenever it is safe to do so.

### 13.1 Account settings sync (a setup step, and the `sync` verb)

For each account, the tool writes `~/.claude-shared/settings.json` into `<account>/settings.json` when
any of these holds:

1. the account file is absent;
2. the file is **untouched**: never synced by the tool, and every top-level key is `theme` or `$schema`
   (what Claude Code writes on first start);
3. the file is **ours**: its `cksum` equals the one recorded at the last sync in
   `~/.claude-multi/settings-sync.tsv` (`slug<TAB>cksum`, one line per account, rewritten when it changes).

Otherwise the file was edited since the last sync (a `/config` change inside that account, or a hand
edit) and is **kept**, reported as `  settings: <slug> modified since the last sync — kept (run: … sync
--force <slug>)`; with `--force` (all accounts) or `--force <slug>` it is overwritten anyway.
Written content: the shared file, with the account's existing `theme` preserved when jq or python3 is
available (plain copy otherwise). Files the tool writes here are mode 600 (settings may carry `env`
secrets). Nothing is written when the account file already equals the content that would be written
(idempotence, T9). The recorded cksum is that of the written content. The launchers still pass
`--settings`, so on that path the shared file wins regardless; this step only serves bare `claude`,
scripts and IDEs under `cuse`.

`sync` runs only this step (no discovery, no links, no aliases) and prints one line per account:
`  settings: <slug> synced` / `already in sync` / `modified since the last sync — kept …` / `overwritten
(--force)`; then the same `settings:` summary line `status` prints. In `setup`, a kept file is a warning. Exit 0 unless a write fails.

### 13.2 `settings.local.json`

`~/.claude/settings.local.json` (user-level hooks and env) is folded into the shared file:

- at first seeding of `~/.claude-shared/settings.json`, when `settings.local.json` exists next to the
  seed: shared = deepmerge(settings.json, settings.local.json);
- on `sync --merge-local`, for an already-seeded shared file: shared = deepmerge(shared, settings.local.json),
  written only when the result differs (so re-running is a no-op).

deepmerge: objects merge recursively; arrays become an order-preserving union (left items, then right
items not already present, compared as whole JSON values); scalars: the right side wins. Implemented
with jq, else python3; with neither, the merge is skipped with a warning naming both. The shared file is
chmod 600 afterwards.

### 13.3 Trust is per account per project

`hasTrustDialogAccepted` lives in each account's `.claude.json`. The tool never writes that file, so a
user accepts the trust dialog once per repo per account; until then that repo's `.claude/settings.json`
allow rules are ignored (Claude Code prints "this workspace has not been trusted"). README and SKILL.md
say so; SKILL.md troubleshooting maps "prompts after cuse" to `claude-multi sync` and "allow rules
ignored" to the trust dialog.

### 13.4 Tests

| # | Case | Asserts |
|---|---|---|
| T24 | settings sync | after setup every account has `settings.json` equal to shared (theme preserved when the account file was `{"theme":"dark"}`), mode 600, `settings-sync.tsv` has a row per account; re-run writes nothing (T9-style `find -newer`); editing the shared file then `sync` propagates to untouched/ours accounts; an account file edited by hand (`{"permissions":{"allow":["Bash(x:*)"]}}` with a stale cksum) is kept and reported, `--force <slug>` overwrites only that one, `--force` all; `status` prints `settings: <n> in sync, <p> pending, <m> modified` between `aliases:` and `rc:` (pending = absent, untouched or ours-but-stale); `--dry-run` writes nothing |
| T25 | settings.local.json merge | seed with `settings.json` `{"permissions":{"allow":["A"]},"env":{"X":"1"}}` and `settings.local.json` `{"permissions":{"allow":["A","B"]},"env":{"Y":"2"},"hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"true"}]}]}}` → shared has allow `["A","B"]`, env `{X,Y}`, the hook, mode 600; `sync --merge-local` again → `No changes`; a shared file seeded before local existed gains the local keys on `sync --merge-local`; without jq and python3 → warning, shared unchanged |

Version: 1.2.0 everywhere.

### 13.5 The read-block trap (v1.2.2)

Answering **Block** to Claude Code's "read outside the working directory?" prompt persists
`permissions.blockReadsOutsideWorkingDirectories: true` in the account's own `settings.json`. Under it,
every Bash command the shell parser cannot analyse (`node -e …`, sed with braces) prompts, in every
permission mode, workflow subagents included, and a running session keeps the flag until it restarts.
`setup`, `sync` and `status` warn whenever an account file or the shared file carries the key
(`warning: account <slug> sets permissions.blockReadsOutsideWorkingDirectories: true …`, naming the
file and the two-step fix). T24 asserts the warning on all three paths and for the shared file.


## 14. v1.3 — plugins follow the account, not the machine

Measured 2026-09-09 (Claude Code 2.1.266): `/plugin` in a claude-multi account listed three plugins as
`failed to load · 1 error`. They were user-scope plugins the default account had installed and then
disabled: the seeded `settings.json` carries the whole `enabledPlugins` map, `false` entries included,
so every account inherits the *names*, but each account had its own empty `plugins/`. On first start
Claude Code materialised the plugins whose source lives inside the official marketplace repo and skipped
those fetched from separate git repositories, and a plugin that is listed but has no install behind it
is what `/plugin` shows as an error. Repo-scoped plugins had the same shape of problem: a plugin enabled
in a repo's `.claude/settings.json` is recorded in `installed_plugins.json` (with its `projectPath`),
which lived in one account only, so every other account had to install it again per repo and worktree.

### 14.1 The link

`<acct>/plugins` → `~/.claude/plugins`, with the §5 link rules, whenever `~/.claude/plugins` is a real
directory. The whole directory is shared: `installed_plugins.json` (user, project and local scope
records), `known_marketplaces.json`, `marketplaces/`, `cache/` and `data/`. Enable state is not in that
directory — `enabledPlugins` lives in `settings.json` — so the accounts agree on what is installed and
the shared settings file says what is on. A `/plugin install` inside an account records the install for
everyone and writes `enabledPlugins.<name>: true` into that account's own `settings.json`, so it is on
there only until the shared file says so too (§13, `sync --force <slug>` after editing the shared file).

Why the whole directory and why a symlink: Claude Code writes into `plugins/` (installs, marketplace
refreshes at startup, the in-use sweep). Sharing only `cache/` would leave the tool rewriting Claude
Code's own registry files; sharing the directory makes N accounts look exactly like N terminals of one
account, which Claude Code already supports. The canonical dir stays in `~/.claude` (as memory did
until v1.5, §16): nothing is moved, and the default account keeps working if claude-multi is removed. The tool never
writes into `~/.claude/plugins`; sessions of the other accounts do, as they do into shared memory.

Not covered: `~/.claude/plugins` absent (the default account has never started Claude Code) — nothing is
linked, one warning per run names the dir and the fix (start plain `claude` once, then `--relink`);
`status` prints `plugins: <dir> missing (…)`. An account that already has a real `plugins/` (set up before
v1.3) is left alone with the §5 warning, which now prints the `mv` that moves it aside; the user runs it
with no session of that account open, then `--relink`. Its own `data/` is kept in the moved-aside dir.

### 14.2 Output

Summary: `Shared plugins: ~/.claude/plugins, linked from each account's plugins/ (…)` or `Shared plugins:
not yet — ~/.claude/plugins does not exist (start plain claude once, then --relink)`. `status`: `plugins: <n>
shared, <o> own, <p> pending` (shared = symlink to `~/.claude/plugins`; own = anything else present;
pending = absent, linked on the next setup or relink) between `settings:` and `rc:`, or the `missing` form.

### 14.3 Tests

| # | Case | Asserts |
|---|---|---|
| T26 | shared plugins link | `~/.claude/plugins` absent: setup links nothing, exits 0, warns once for three accounts (names the dir, says `not shared`), summary `Shared plugins: not yet`, `status` prints the `missing` form; then with `~/.claude/plugins` present: alice's empty real dir replaced (`replace empty dir`), bob's non-empty dir left alone (`installed_plugins.json` and cache intact, warning names the path, `left alone`, and `mv '<path>' '<path>.unshared'`), carol linked, summary names `~/.claude/plugins`, `status` `2 shared, 1 own, 0 pending`; bob's dir moved aside then `--relink`: linked, exactly one `+ link` line, no warning, moved-aside copy intact, `status` `3 shared, 0 own, 0 pending`; another `--relink` → `No changes`; `~/.claude` untouched throughout |

T1 asserts the sixth link for every account, T16 and T21 the `plugins:` line and its place in the order.

Version: 1.3.0 everywhere.

## 15. v1.4 — the launchers become real files

`claude-<slug>` was a shell function, and a shell function only exists inside a shell that sourced
`aliases.sh`. `execvp` cannot see one. So everything that starts a program without going through an
interactive shell — cron, CI, an editor's "run this command" box, and any CLI that takes a command
out of its own configuration — could not run Claude Code as a chosen account at all. The failure is
`command not found` for a name that works perfectly when typed, which reads as a typo rather than as
a category error.

Measured 2026-09-18, with a tool whose config wanted a model command: `claude-<slug> -p`
was rejected as not found, while `type` reported it as *"a shell function from
~/.claude-accounts/<slug>/shell-snapshots/…"*. The workaround a user reaches for is to inline what
the function does:

```
/usr/bin/env -u ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR=~/.claude-accounts/<slug> claude -p
```

which works, and which is also where the real hazard lives: drop the `-u` and the run silently bills
the API instead of the subscription, because `ANTHROPIC_API_KEY` outranks the directory's login. That
detail belongs in one place that everyone calls, not in each consumer's config.

### 15.1 The files

`setup` writes `~/.claude-multi/bin/claude-<slug>`, mode 755, one per account, regenerated like every
other artefact (`install_file`, so an unchanged file is not rewritten and `--dry-run` only reports).
Each is a `#!/bin/sh` script that resolves `claude` on `PATH` at run time, refuses with the account
directory named if it is missing, unsets `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` /
`CLAUDE_CODE_OAUTH_TOKEN`, exports `CLAUDE_CONFIG_DIR`, and `exec`s `claude` with the shared
`--mcp-config` / `--settings` flags — the same contract §6 gives the function, and for the same
reasons.

`$HOME` is resolved at run time rather than baked in at generation time, which is what
`CLAUDE_MULTI_ACCOUNTS_ROOT` already does in `aliases.sh`.

Removing an account removes its launcher. A stale one would pin a directory that no longer exists and
fail later with a "missing" message, long after anyone connects it to the removal.

### 15.2 One implementation, not two

`_claude_multi_run` becomes a wrapper: it resolves `$CLAUDE_MULTI_BIN_DIR/claude-<slug>` and runs it.
Everything the account needs lives in the file. A second copy of that logic in the function would be
two things to keep in step, and the interesting parts — the credential unsets and the flag order —
are exactly the parts where drift would be silent.

`aliases.sh` appends the bin directory to `PATH`, guarded against a repeat entry, so the bare name
works for a process started from a shell that sourced it. Appended rather than prepended: these names
belong to claude-multi alone, so there is nothing to shadow and no reason to outrank the rest of
`PATH`. A shell function still wins over `PATH` in both zsh and bash, so an interactive
`claude-<slug>` keeps hitting the function — which now runs the same file anyway.

`cuse` stays a shell function and cannot become anything else: it exports `CLAUDE_CONFIG_DIR` into the
*calling* shell, and no child process can do that.

### 15.3 Tests

| Case | Setup | Asserts |
|---|---|---|
| T27 | two accounts, then `remove` of one | `bin/` is a real directory; a launcher per account, mode 755, first line `#!/bin/sh`; run under `env -i` with only `HOME` and `PATH` — exit 0, the account's `CLAUDE_CONFIG_DIR`, the argument passed through, `mcp.json` among the flags; with `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `CLAUDE_CODE_OAUTH_TOKEN` set, all three reach `claude` as `<unset>`; `aliases.sh` names `CLAUDE_MULTI_BIN_DIR` and delegates, and no longer `exec`s `claude` itself; after `remove`, that launcher is gone and the other survives |

`env -i` is the point of the case: an empty environment proves the launcher needs neither `aliases.sh`
nor an interactive shell, which is exactly what cron, CI and a config-driven tool hand it.

Version: 1.4.0 everywhere.

## 16. v1.5 — shared memory leaves `~/.claude`

Measured 2026-10-03: in an account session Claude asked for permission on every write to its
auto-memory, although the shared settings carried allow rules for the memory paths. In one session's
transcript every memory `Write`, `Edit` and shell append waited between 10 seconds and 4 minutes for
its result. The 4-minute one was certainly a prompt; the shorter ones may include classifier time.

The cause is documented by Claude Code. Up to v1.4 the real folder was `~/.claude/projects/<p>/memory`
and each account's `projects/<p>/memory` was a symlink to it, so:

- `.claude` is a protected directory, and "`permissions.allow` rules in settings files do not
  pre-approve protected-path writes. The safety check runs before Claude Code evaluates allow rules
  from settings."
  (<https://code.claude.com/docs/en/permission-modes#protected-paths>)
- "the permission check covers two paths: the one Claude requested and the file it resolves to." A
  write that "resolves to a protected path that the requested path doesn't name" gets the
  protected-path outcome of its mode, "except that where the table routes the write to the classifier,
  this write prompts you instead."
  (<https://code.claude.com/docs/en/permissions#symlinks>)
- Allow rules "apply only when both the requested path and the file it resolves to match." (same section)

An account session asked for `~/.claude-accounts/<slug>/projects/<p>/memory/x.md`, which is not
protected; it resolved into `~/.claude/…`, which is; so auto mode prompted, and no allow rule could
change that. `.claude-accounts` and `.claude-shared` are not the name `.claude`, so they are not
protected.

**Goal.** After `setup` or `--relink`, a memory write from any account session is not a protected-path
write, and matches an allow rule on both paths. Memory stays shared across the accounts and with the
default `~/.claude` account.

### 16.1 Layout

The real folder is `~/.claude-shared/memory/<p>/` ("the store"; `<p>` is Claude Code's project
directory name). `~/.claude/projects/<p>/memory` and every `~/.claude-accounts/<slug>/projects/<p>/memory`
are symlinks **directly** to it: one hop, never through `~/.claude`. Only the folder is linked, never a
file inside it: the Edit and Write tools refuse a path that is itself a symlink. The store directory is
created mode 700 when the first folder moves in (memory is private notes); a store that already exists
keeps its mode.

### 16.2 Migration (`setup` and `--relink`, idempotent)

Per project, where a project is anything with a `memory` entry under `~/.claude/projects/`, a folder
in the store, or files in a registered account's own memory folder (§16.7). A name that contains a
newline or any other control character is not a project and is left where it is: a name is one line in
the tool's lists and one path component everywhere else.

| `~/.claude/projects/<p>/memory` | Store `~/.claude-shared/memory/<p>` | Action |
|---|---|---|
| real dir | absent, or an empty dir | `move`: the folder is renamed into the store (an empty store dir is removed first), then a link is left behind. If the link cannot be made, the folder is moved back and the run stops with `error: cannot link … the folder was moved back to …` |
| empty real dir | present | `replace empty dir`: the empty dir becomes a link |
| non-empty real dir | present, non-empty | conflict: nothing changes for that project, account links included; `warning: memory conflict: <seed> and <store> both hold files; …` names both paths |
| link to the store | present | nothing. "To the store" means the link lands on the store folder (`-ef`), however it is spelled: a link made by hand with a trailing slash or a relative path counts |
| link to the store | absent | left alone, warned (the link dangles) |
| link elsewhere | any | left alone, warned; the accounts are linked to the store only if its folder exists |
| absent | present | when `~/.claude/projects/<p>` exists, the link is created there; that directory is never created by the tool, so the default account gets its link on the first run after it has used the repo |

Account links, per project that came out of the table without a conflict: absent → created; a link to
the old `~/.claude/projects/<p>/memory` → repointed to the store (`repoint … (was …)`); an empty real
dir → replaced; a non-empty real dir is that account's own memory for the repo. When nothing shared
holds files yet it is adopted (§16.7). Otherwise it is left alone with `warning: <path> holds this
account's own memory for that repo, and <store> holds the shared one; left alone, …`, which says to
move its files into the store by hand. It is deliberately not §5's `mv … .unshared` hint: moved aside,
those notes would be hidden from Claude rather than shared. A machine where a project was
already moved by hand, with `~/.claude` and the accounts linking to the store, therefore comes out as
`No changes`.

The move is a rename inside `$HOME`, so a session that is running keeps working: every path it holds
still resolves, through the link left behind. `update` ends in `setup --no-input` (§12.5), so the first
`update` to v1.5 performs the migration; `update --dry-run` installs nothing and moves nothing.

### 16.3 Allow rules

The shared `settings.json` must allow both paths of a memory write:

```
Edit(~/.claude-accounts/*/projects/*/memory/**)     the path the account session asks for
Edit(~/.claude-shared/memory/**)                    the file it resolves to
```

The settings step (run by `setup`, `--relink` and `sync`) adds whichever of the two is missing to the
end of `permissions.allow` in `~/.claude-shared/settings.json`, reported as `allow memory writes in
<file> (two Edit rules in permissions.allow)`. No other key or entry changes: it is the §13.2
deepmerge, whose array union keeps existing entries and their order (the file is re-serialised by jq
or python3, so its whitespace may change). Presence is a text test for the
two rule strings, so it needs no JSON tool, and a user who moved a rule to `deny` or `ask` is not
fought. Without jq and python3, or with a file that is not valid JSON, the rules cannot be merged: the
file is left untouched and a warning prints both rules to add by hand.

They have to reach every account's effective settings. The launcher path gets them through
`--settings`. On the `cuse` path each account's own `settings.json` is the §13.1 copy, so an untouched
copy and one the tool wrote pick the rules up from the normal sync. A copy that is **modified** is not
overwritten (§13.1), so for it the decision is: **the same two rules are merged into that copy,
additively**, rather than printing a `sync --force <slug>` hint. A hint would leave the prompts in
place until the user gave up their own `/config` edits; the merge loses nothing of theirs, and the copy
stays `modified` and keeps being reported as such.

### 16.4 Output

`--dry-run` prints `[dry-run] would move <seed> to <store>`, `[dry-run] would link <seed> -> <store>`
and the account link lines, and writes nothing. The summary reads `Shared memory:
~/.claude-shared/memory/<repo>, linked from ~/.claude/projects/<repo>/memory and from each account's
projects/<repo>/memory (…)`. `status` prints, between `plugins:` and `rc:`,

```
memory: <n> shared, <m> still in ~/.claude, <a> in one account, <c> conflicts
```

counting projects, each in exactly one bucket: *shared* = the folder is in the store and `~/.claude`
links to it or has no entry; *still in `~/.claude`* = a real folder the next `setup` or `--relink` will
move (or an empty one it will replace); *in one account* = memory that exists only inside one account
and will be adopted by the next run (§16.7); *conflicts* = what the tool leaves for a human: two places
hold files for the same repo (`~/.claude` and the store, two accounts, or an account next to the shared
folder), a link that points elsewhere, a dangling link. A second run prints `No changes — everything was already in place.`

### 16.5 Undo

Per project, with no session of any account open in that repo:

```
rm ~/.claude/projects/<p>/memory                          # the link, not a folder
mv ~/.claude-shared/memory/<p> ~/.claude/projects/<p>/memory
```

The account links then dangle until they are pointed back at `~/.claude/projects/<p>/memory` by hand; a
later `setup` or `--relink` moves the folder into the store again. Removing `~/.claude-shared` without
doing this first deletes the memory, which the README's Uninstall section says in so many words.

### 16.6 Checks on a real Claude Code

The Claude Code docs give no worked example of this layout, so the three statements below were
inferences from §16's quotes, and the harness cannot test them: it has no Claude Code. Moving a real
memory folder or editing a real settings file is also refused to an agent session in auto mode
("Self-Modification"), so the migration was run by the owner, in a terminal, and each check is recorded
here.

Run 2026-10-03 on Claude Code 2.1.288, on a machine with four accounts. The migration moved 9 folders
out of `~/.claude` and adopted 6 from one account (§16.7) with no conflict; every link then pointed
straight at the store, the adopted folders held the files they held before, and a second run printed
`No changes`. A repo that gained memory afterwards was moved by `--relink`, and the checks were run in
that repo, so every write below went through a link into the store. "No prompt" is what the owner saw;
the time is the wait between the tool call and its result in the session transcript.

| # | Check | Result |
|---|---|---|
| 1 | An account session writes and edits a memory file through its own path with no prompt, in auto mode and in default mode, with the two rules present | **Passed.** Auto mode: `Write` and `Edit`, no prompt, 0.2 s each. Default mode: the same, no prompt, 0.1 s each. Default mode is where an edit that no rule covers asks, so the two rules matched on both paths |
| 2 | Plain `claude` on the default account still writes memory without a prompt now that its memory path is a link out of `~/.claude` (the built-in exemption for the memory folder is undocumented) | **Passed in auto mode; not tested in default mode.** `Write` through `~/.claude/projects/<p>/memory`, a link to the store: no prompt, 2.3 s. The same write into the real folder, before it was moved, took 0.2 s. That fits the write no longer taking a built-in fast path and being decided by the auto-mode classifier instead, which is an inference from the timing: the transcript does not record it. Default mode has no classifier, so what plain `claude` does there is unknown |
| 3 | A shell append (`>>`) to a memory file from an account session does not prompt | **Passed.** Auto mode: `>>` through the account's own path, no prompt, 1.0 s |

Before the move, the same kind of write from an account session waited between 10 seconds and 4
minutes (§16, first paragraph).

The fallback for a failed check 1 was the `autoMemoryDirectory` setting
(<https://code.claude.com/docs/en/memory#storage-location>). It replaces the per-project folder, so set
in the shared file it would give every project one folder; it only works per project. Check 1 passed,
so it is not built. The open item is check 2 in default mode, and the README says so: the accounts are
the tool's purpose, and they are what was verified.

### 16.7 Adoption of memory first created inside an account

Up to v1.4 only folders in `~/.claude` were shared, so a repo first used through an account was never
shared: its memory stayed a real folder inside that account. Decided 2026-10-03, after the first dry
run on a real machine showed six such repos in one account: they are adopted, in v1.5.

Per project, when neither `~/.claude` nor the store holds files for it yet (the §16.2 state is not a
conflict, a link elsewhere or a dangling link, the store folder is absent or empty, and `~/.claude` has
no folder or an empty one), the accounts' own real, non-empty `projects/<p>/memory` folders decide.
"Accounts" means the registered ones (`setup`: the account list of this run; `--relink` and `status`:
`accounts.tsv`), whose slugs §4 validates. A directory that merely sits under `~/.claude-accounts` is
never a source: the first allow rule of §16.3 lets a session create one there, and a move must not be
steerable by a directory name.

| Accounts holding files | Action |
|---|---|
| none | nothing to adopt; the §16.2 table alone applies |
| exactly one | that folder is moved into the store (`move <account folder> to <store>`, an empty store dir removed first) and a link is left in the account, with the same rollback as §16.2. `~/.claude` is then judged against a store that holds it: an empty real dir there is replaced by a link, a missing entry is linked when `~/.claude/projects/<p>` exists. Every other account is linked |
| two or more | never merged: nothing changes for that project, and `warning: memory conflict: <n> accounts each hold their own memory for <p> and nothing is shared yet (<paths>); …` names every folder |

An **empty** folder in an account holds no memory and is not adopted, and creates nothing: on the
machine measured, accounts held empty memory folders for repos (and for a temporary job directory)
where nothing was ever written, and adopting those would give every account a project dir for each of
them. So a repo is shared from the first run
after one account has written memory in it; if a second account writes its own before that run, the
two-or-more row applies. `--dry-run` prints the same lines a real run does (the `~/.claude` side is
judged as if the adopted folder were already in the store).

Adoption crosses accounts on purpose: memory belongs to the repo, and whoever opens the repo with
another account now sees the notes the first account wrote there.

The function that moves a folder (the §16.2 move and this one) refuses any path that is not a real,
non-link directory ending in `projects/<p>/memory`, whatever built the path. It is the last line of
defence, not the first: the path it is given is an account slug from the registry plus a project name
that passed the check above, never a piece cut out of a joined string.

### 16.8 What the move gives up

Before v1.5 an account's memory write stopped at a permission prompt. That was the defect, and it was
also a review step. Now such a write is pre-approved. Two consequences, stated because they are the
price of the fix:

- Memory is read back into later sessions. Anything that can make a session write memory (a prompt
  injection in a file or a web page, for instance) can leave text for future sessions of every account,
  without a prompt in between.
- The two rules of §16.3 are not scoped to the repo a session runs in: a session in one repo may write
  the memory of another. A shared settings file has no way to name "this project", so the breadth comes
  with the approach.

A user who wants the prompt back moves the two rule strings from `permissions.allow` to
`permissions.ask` in the shared file (and in any account copy `status` counts as modified): the
presence test of §16.3 then finds them and adds nothing.

### 16.9 Tests

| # | Case | Asserts |
|---|---|---|
| T12 | rewritten, see §10 | the new layout end to end; bob's own folder next to the shared one gets the memory warning (names the store, no `.unshared` hint) and counts as a conflict in `status` |
| T28 | the §16.2 table, one project per row, one run, alice with a v1.4 link into the conflicting project | `status` before: `memory: 2 shared, 3 still in ~/.claude, 0 in one account, 3 conflicts`; each row's action and nothing more (moved file intact, empty dir replaced, both conflict sides intact and nothing merged, both paths in the warning, alice's link into the conflict not repointed, the link elsewhere and the dangling link untouched and warned with nothing created for them, an empty store dir not blocking the move, a store-only project linked from `~/.claude`); `status` after: `5 shared, 0 still in ~/.claude, 0 in one account, 3 conflicts`; a second run is `No changes` and still warns; with a failing `ln` in `PATH` the run exits 1, the folder is back in `~/.claude`, nothing is left in the store, the error says `moved back`; once `ln` works the move goes through |
| T29 | upgrade from the v1.4 layout: real folders in `~/.claude`, account links to them | `--dry-run` prints the `would move`, `would link` and `would repoint … (was …)` lines, no `+` line, same tree, nothing modified; then the move, every account link straight to the store, none through `~/.claude`, the files readable through each path; `status` `2 shared`; a second `setup` and a `--relink` are `No changes` and modify nothing |
| T30 | two projects moved by hand: `~/.claude` and both accounts already link to the store, one `~/.claude` link spelled with a trailing slash | `setup` and `--relink` are `No changes`, nothing modified, same store inode, no warning, the oddly spelled link left as it is; `status` counts both as shared |
| T31 | the allow rules | the shared file gains both rules after the seeded one, every other key as seeded and in order, mode 600, each rule once; the account copies carry them; `~/.claude/settings.json` is not edited; a second run is `No changes`; a shared file that has one rule gains only the other, at the end, and `--relink` delivers it to the accounts; a modified account copy keeps its own rule and key, gains the two rules, is still reported and counted as modified, and gains them once; a shared file that carries the two rules under `permissions.ask` is left byte-identical and the synced copy's allow list gains nothing; without jq and python3 the warning names both rules and the shared file is byte-identical |

| T32 | adoption (§16.7), one project per row: only alice has memory; alice plus an empty folder in `~/.claude`; alice and bob both; alice while the store holds files; alice with an empty folder only; alice plus an empty store folder `~/.claude` links to | `status` before: `0 shared, 0 still in ~/.claude, 3 in one account, 2 conflicts`; `--dry-run` prints the account folder's `would move` and `would link`, `would replace empty dir` for the empty `~/.claude` folder (and no `would move` for it), bob's `would link`, and modifies nothing; then alice's folder is the store folder (same inode), she and bob link to it, no project dir is made in `~/.claude`; the empty `~/.claude` folder became a link; with two holders both folders are intact, no store folder exists and the warning names both; with a full store alice's folder is intact, nothing is merged, bob is linked; an empty folder is not adopted and creates nothing; an empty store folder does not block adoption and the `~/.claude` link to it stays valid; `status` after: `3 shared, …, 0 in one account, 2 conflicts`; a second run is `No changes`; with a failing `ln` the run exits 1 and the folder is back in the account; a directory under `~/.claude-accounts` that is no registered account is not adopted from, one whose name is a real slug, a newline and more text does not get that account's directory moved (same inode, nothing in the store), a project name with a newline is left where it is, and `status` counts none of them |

T1–T3 assert the shared `settings.json` as "the seed plus the two rules", T16 and T21 the `memory:` line
and its place in the order.

Version: 1.5.0 everywhere.

## 17. v1.6 — the default account follows the shared folders

Measured 2026-10-05 (Claude Code 2.1.289): a plugin written into the skills folder from an account
session (an account's `skills/` is `~/.claude-shared/skills/`) was listed by `claude plugin list` as
loaded under each of four accounts, and `~/.claude/skills` had no entry of that name. The cause is the
seeding of §2: `~/.claude-shared/<dir>`
is a one-time copy of `~/.claude/<dir>`, every account dir links to the shared folder itself, and nothing
ever goes back. A month after the seeding, the shared skills folder on that machine held five entries
`~/.claude/skills` did not, so plain `claude` ran without them. Each one could be fixed with an `ln -s`
by hand; the point of this section is that nobody has to remember to.

### 17.1 The pass

For each of `commands`, `agents`, `skills`, `output-styles`, with `S` = `~/.claude-shared/<dir>` and
`D` = `~/.claude/<dir>`:

| `D` | `S` | The pass |
|---|---|---|
| a real directory | has entries | for each entry of `S` whose name `D` does not have: `D/<name>` → `S/<name>` (absolute target). A name that exists in `D` (file, directory or symlink, a dangling one included) is left alone, whatever it holds |
| absent | has entries | one link `D` → `S`, as in an account dir |
| absent | empty | nothing |
| a symlink, to anywhere | any | nothing: the folder link of the row above, or the user's own arrangement |
| a plain file | any | nothing |

Skipped entries of `S`: `.DS_Store`, and any entry that leads nowhere. The second rule is also what
prevents a loop: a shared entry can itself be a link back into `D` (a skill installed on the default
account and linked into the shared folder by hand); when that name is missing in `D` the entry is
dangling, and linking it would make the two point at each other.

Prune: an entry of `D` that is a symlink, leads nowhere, and whose target text is exactly
`S/<its own name>` is removed. That is a link this pass made whose shared entry has since been deleted.
The user's own dangling links, and a link into `S` under another name, are kept. Nothing else in
`~/.claude` is ever removed.

One direction only. An entry that exists only in `D` stays there and is not offered to the accounts;
adding links to the shared folder would change what every account loads, which is the user's call.
Through the folder link of the second row the two are one folder, so there the question does not arise.

Why a link per entry and not `D` → `S` for a real directory: the two folders have drifted since the
copy (on the measured machine: five names only in `S`, one only in `D`, three duplicated with equal
content, one name with different content on each side). One link for the folder needs a merge and a
move out of `~/.claude`, with a conflict state the user resolves by hand, as §16 has for memory. A
link per entry needs no merge, cannot conflict and is undone with `rm`.

`CLAUDE.md` is not part of it: it is one file, the default account has its own, and there is no
"missing name" to fill. `settings.json` and `mcp.json` are not symlinked anywhere (§2).

A re-seed (the user removed `~/.claude-shared/<dir>` and ran setup) copies `D` with these links in it.
A copied link whose target is its own path in the new `S` is dropped right after the copy; the pass
then prunes its counterpart in `D`.

### 17.2 When it runs

- `setup` and `--relink` (so `add`, `remove` and `update` too), after the account links.
- `link-default [--dry-run]`: the pass alone.
- Every launcher, before it execs `claude`: `~/.claude-multi/claude-multi-setup.sh link-default` with
  its output discarded and its exit status ignored. A launcher works when that file is missing.
- `cuse`, for any target (`default` included), the same way.

The last two are what make it need nobody: a shared entry added today is in the default account the
next time any account is started or any terminal is pinned. What is left: plain `claude` in a terminal
where neither happened since the entry was added runs without it once. Sourcing `aliases.sh` does not
run the pass; a file-system write at every shell start is not something an rc line should do.

Cost: one bash start and a few `test` calls per shared entry. Ten dry-run passes took 0.28 s on the
measured machine (27 shared skills, five of them to link), about 30 ms a launch.

### 17.3 The switch

`CLAUDE_MULTI_DEFAULT_LINKS=0` in the environment turns the pass off everywhere it is called: setup,
`--relink`, the verb (`Off: CLAUDE_MULTI_DEFAULT_LINKS=0.`), the launchers and `cuse`. Existing links
stay; nothing is undone.

### 17.4 Output

Change lines: `link <D>/<name> -> <S>/<name>`, `link <D> -> <S>`, `remove <D>/<name> (the shared entry it
pointed at is gone)`. A link that cannot be made is a warning naming both paths, never an error: setup
goes on. Summary: `Default account: ~/.claude gets a link to every shared command, agent, skill and
output style it has no name for (…)`, or `… is not given links to new shared entries
(CLAUDE_MULTI_DEFAULT_LINKS=0)`. `status`, between `memory:` and `rc:`: `default: <n> linked, <p>
pending` (linked = entries of the shared folders the default account reaches through a link of this
pass, the entries of a folder-linked directory included; pending = entries with no name there yet,
linked by the next pass), or `default: off (CLAUDE_MULTI_DEFAULT_LINKS=0)`, or `default: <dir> missing`.
A name the default account holds itself is counted in neither.

### 17.5 Undo, and what it gives up

Undo: `rm` the link. `find ~/.claude/commands ~/.claude/agents ~/.claude/skills ~/.claude/output-styles
-maxdepth 1 -type l -lname "$HOME/.claude-shared/*"` lists them, and with the switch of §17.3 set they
are not made again.

What it gives up:

- §9's "never modify `~/.claude`" has a second exception, and this one runs at every launch.
- The default account now depends on `~/.claude-shared` for the entries it only has through a link:
  remove that folder and they are gone. The README's uninstall moves them back first.
- A name on both sides with different content is not reconciled. The default account keeps its own
  version and the accounts keep the shared one, as before v1.6.

### 17.6 Tests

| # | Case | Asserts |
|---|---|---|
| T33 | shared entries added after the seeding: three skills (one a dot name, one with a space), a command, an agent while `~/.claude/agents` is absent; one name with different content on both sides; a shared entry that links back into `~/.claude` and leads nowhere; `.DS_Store` | `status` counts five pending; `link-default --dry-run` names the links and makes none; `link-default` makes exactly five (the agent as one folder link), leaves the same-name skill a real directory with its own content, links neither the dangling entry nor `.DS_Store` nor an empty shared folder, and `~/.claude` is the old tree plus the five links; `status` counts five linked; a second pass is a no-op; a file written through the folder link is in the shared folder and in an account. Prune: after the shared skill is deleted `--relink` removes that link and keeps the user's own dangling link and a dangling link under another name. The switch: setup, the verb and `status` do nothing and say so; `link-default --relink` is a usage error. A launcher run links a new skill, prints nothing of it and still launches; with the switch it links nothing; without the installed script it still launches. `cuse default` (bash) and `cuse <slug>` (zsh) link a new skill and print only their own lines. A re-seed drops the copied self-link and prunes its counterpart |

T16 and T21 assert the `default:` line's place in the order. Every earlier case still passes its
`~/.claude` untouched assertion: a fresh seeding leaves nothing for the pass to link.

Version: 1.6.0 everywhere.
