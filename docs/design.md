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
| `~/.claude` , `~/.claude.json` | the user / cswap | untouched: the DEFAULT account, read only as the seed |
| `~/.claude-accounts/<slug>/` (mode 700) | the script creates; Claude Code fills | one `CLAUDE_CONFIG_DIR` per account; never deleted by the tool |
| `~/.claude-shared/` | the script seeds ONCE; the user edits | `settings.json`, `mcp.json`, `CLAUDE.md`, `commands/`, `agents/`, `skills/`, `output-styles/` |
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
  added with `claude mcp add`), `plugins/`, history, sessions, credentials.
- **Per-repo auto-memory IS shared**: for every `~/.claude/projects/<p>/memory/` that exists as a
  real directory, each account gets `projects/<p>/memory` as a symlink to it. The canonical folder
  stays in `~/.claude` (nothing there is moved). A repo that gains memory later needs a re-run or
  `--relink`.

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
claude-multi-setup.sh status
claude-multi-setup.sh --help | -h | --version
```

- `setup` (default): discover accounts (§4), seed shared config, create account dirs + symlinks +
  memory links, write `accounts.tsv`, generate `aliases.sh`, self-install, handle the rc line, print
  the summary. Idempotent: a re-run with nothing new prints `No changes — everything was already in
  place.` and leaves the filesystem byte-identical (mtimes included).
- `--dry-run`: every change is printed as `  [dry-run] would <action>`; nothing is created, not even
  `~/.claude-multi`.
- `--relink`: only (re)create the shared + memory symlinks inside the account dirs that already
  exist. No discovery, no aliases regeneration.
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
2	hans@betterdoc.test	hans-betterdoc
```

A 2-column line (`email<TAB>slug`, the v1 format) is accepted on read as a row without a slot.
Rows for emails no longer discovered are kept (their dirs exist). A slug, once written, never
changes for that email.

Slugs: lower-cased local part, runs of non-`[a-z0-9]` → `-`, trimmed (`acct` when nothing is left,
e.g. `_@x.test`). Among NEW emails, a slug that
is already taken (registry, or another new email's base) gets `-<first domain label>` appended
(`hans@betterdoc.de` → `hans-betterdoc`); if still taken, `-<slot>`. Known emails keep their slug.

## 5. Account directories and links

For each account: `mkdir -p` + chmod 700; for each shared name, `<acct>/<name>` → absolute target.
Link handling: correct symlink → nothing; symlink to another target → repointed (`repoint`);
EMPTY real directory → replaced (`replace empty dir`); non-empty real file/dir → left alone with
`warning: <path> exists and is not a symlink; left alone (move it aside, then --relink, to share it)`.
Memory: for each `~/.claude/projects/*/memory` real dir, `mkdir -p <acct>/projects/<p>` (700) and
link `<acct>/projects/<p>/memory` with the same rules.

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
  `NOT logged in → run claude-<slug> and /login once`.
- `_claude_multi_run <slug> [args…]`: resolves the real binary (`whence -p claude` in zsh,
  `type -P claude` in bash; error 127 if absent), errors 1 if the account dir is missing (naming
  `$CLAUDE_MULTI_SETUP`), then in a subshell: `unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN`,
  `export CLAUDE_CONFIG_DIR=<dir>`,
  `exec "$bin" --mcp-config "$SHARED/mcp.json" --settings "$SHARED/settings.json" "$@"`.
- `claude-<slug>() { _claude_multi_run <slug> "$@"; }` per account; `alias claude<slot>='claude-<slug>'`.
- `cuse <slug|slot>`: exports `CLAUDE_CONFIG_DIR` to the account dir and prints
  `This terminal: <slug> (<email>)  CLAUDE_CONFIG_DIR=<dir>`; adds `  not logged in yet: run  claude-<slug>  and complete /login once`
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
  line each; `Shared config: …`; `Shared memory: …`; `Aliases: …`; `rc file: …`; then
  `One-time login, once per account …:` with `  claude-<slug>  then /login as <email>` or
  `(already logged in)`.
- `status` lines, each `key: value` on its own line, in this order: `script:`, `version:`, `cswap:`
  (`found at <path>` | `not found (manual account list)`), `shared:` (`ok <dir>` | `missing`),
  `aliases:` (`ok <file>` | `missing`), `rc:` (`sourced from <file>` | `not sourced (run --rc)`),
  `terminal:` (`default` | `<slug> (<email>)` | `unmanaged <dir>`), then
  `account: <slot> <slug> <email> <logged-in|not-logged-in>` per registered account, then
  `next: <one sentence>` (e.g. `run claude-<slug> and /login` for the first not-logged-in account,
  `all accounts logged in` otherwise, or `run setup` when nothing is registered).

## 9. Safety invariants

Never delete an account dir · never overwrite a seeded shared file · never modify `~/.claude` or
`~/.claude.json` · never touch an rc file without `--rc` · never leave the cswap export on disk ·
never migrate or copy credentials · never print tokens · a re-run with nothing new changes nothing.

## 10. Test matrix (`tests/harness.sh`)

Bash harness, runs under bash 3.2 and 5, macOS and Linux. Each case builds a throwaway `HOME` under
`mktemp -d` with `bin/claude` (prints `stub claude CLAUDE_CONFIG_DIR=… KEY=… ARGS=…`, then a second line
`stub env AUTH_TOKEN=… OAUTH=…`) and a stub
`cswap` whose behaviour is chosen per case; `PATH` = `$HOME/bin:/usr/bin:/bin`. Asserts print
`ok:`/`FAIL:` lines; the harness exits non-zero on any failure and ends with `PASS <n>/<n>`.

| # | Case | Asserts |
|---|---|---|
| T1 | cswap `list --json` (4 accounts, two share local part `hans`) | 4 dirs 700, slugs `alice hans-betterdoc info hans-proton`, 5 symlinks each to absolute targets, shared seeded (settings byte-identical, skills copied, mcp.json from `~/.claude.json`, mode 600), `accounts.tsv` v2, `~/.claude` untouched, no rc change, `zsh -n` + `bash -n` on `aliases.sh` |
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
| T12 | memory: repo-a (files), repo-b (empty), repo-c (no memory); alice has an empty real dir, bob a non-empty one | alice replaced, bob warned + intact, repo-c skipped, new repo picked up by `--relink` |
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
