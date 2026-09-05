#!/usr/bin/env bash
# tests/harness.sh — the test matrix of docs/design.md §10 (T1–T18) + §12.6 (T19–T23) for claude-multi-setup.sh.
#
# Usage:  [SCRIPT=<path>] [TEST_BASH=<bash>] [KEEP=1] tests/harness.sh [T1 T2 …]
#   SCRIPT     script under test (default: skills/claude-multi/scripts/claude-multi-setup.sh next to this repo)
#   TEST_BASH  bash binary that runs the script under test (default: the bash running this harness, so
#              `/bin/bash tests/harness.sh` tests under bash 3.2 on macOS and `bash tests/harness.sh` under
#              whatever `bash` resolves to). Note: a `BASH=…` environment variable cannot be honoured — bash
#              overwrites $BASH with its own path at startup, before any script line runs.
#   KEEP=1     keep every throwaway HOME (paths are printed) instead of removing them at the end.
#
# Every case builds its own throwaway HOME under `mktemp -d`; the real HOME is never read or written.
# The script under test always gets stdin from /dev/null; when the harness itself runs in a terminal (so the
# script could open /dev/tty and block on the §12.4 offers or the email prompt), `run_script` also hands every
# invocation that sets no CLAUDE_MULTI_INPUT of its own an EMPTY answers file — the §12.4 test hook at EOF asks
# nothing — so `tests/harness.sh` is deterministic from a terminal, from CI and from an agent's tool shell alike.
# Note: macOS script(1) exports SCRIPT=<typescript file>, which this harness would honour; pin SCRIPT under it.
# Runs under bash 3.2 (macOS /bin/bash) and bash 5 (Linux); BSD and GNU userland. No stat -f / stat -c:
# inodes via `ls -di`, mtimes via `find -newer` and `touch -r`, content via `cmp`.
# Assertions print `  ok: …` / `  FAIL: …`. The run ends with an `asserts: <ok> ok, <failed> failed` line and then
# `PASS <n>/<n>` (n = cases run) or `FAIL <f>/<n>` (f = cases with at least one failed assert or a crash); it exits
# non-zero on any failure. A case that crashes counts as a failed case and never stops the harness.

# shellcheck disable=SC2012,SC2016,SC2088,SC2329  # ls -ld/-di are the portable mode+inode readers; literal `$` and `~` in
#                                                   # description strings are intended; case_* run via "case_$name"
HARNESS_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(dirname "$HARNESS_DIR")
SCRIPT=${SCRIPT:-$REPO_ROOT/skills/claude-multi/scripts/claude-multi-setup.sh}
RUN_BASH=${TEST_BASH:-$BASH}
KEEP=${KEEP:-0}
TMP_BASE=${TMPDIR:-/tmp}; TMP_BASE=${TMP_BASE%/}
ZSH_BIN=$(command -v zsh 2>/dev/null)
TAB=$(printf '\t')
NL=$(printf '\nx'); NL=${NL%x}
RC_LINE='[ -f "$HOME/.claude-multi/aliases.sh" ] && . "$HOME/.claude-multi/aliases.sh"'
V1_RC_LINE='[ -f "$HOME/.claude-multi/aliases.zsh" ] && source "$HOME/.claude-multi/aliases.zsh"'
SHARED_NAMES="CLAUDE.md commands agents skills output-styles"
ALL_CASES="T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11 T12 T13 T14 T15 T16 T17 T18 T19 T20 T21 T22 T23"

TOTAL_OK=0
TOTAL_FAIL=0
CASES_RUN=0
CASES_FAIL=0
FIX=""        # fixture dir (stub payloads), created once
T=""          # per-case scratch dir; HOME is $T/home
H=""          # per-case HOME
KEPT_DIRS=""

# ---------- assertion primitives (only ever print one `  ok:` / `  FAIL:` line) ----------
ok()   { printf '  ok: %s\n' "$*"; }
fail() { printf '  FAIL: %s\n' "$*"; }

assert_true() { # desc cmd args…   (cmd's exit status decides)
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}
assert_false() { # desc cmd args…
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then fail "$desc"; else ok "$desc"; fi
}
assert_eq() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
assert_ne() { # desc unexpected actual
  if [ "$2" != "$3" ]; then ok "$1"; else fail "$1 (still '$3')"; fi
}
assert_rc() { assert_eq "$1: exit $2" "$2" "$RC"; }
assert_file_has() { # desc file fixed-string
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then ok "$1"; else fail "$1 (no '$3' in ${2##*/})"; fi
}
assert_file_lacks() { # desc file fixed-string
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then fail "$1 (found '$3' in ${2##*/})"; else ok "$1"; fi
}
assert_file_line() { # desc file exact-line
  if [ -f "$2" ] && grep -qFx -- "$3" "$2"; then ok "$1"; else fail "$1 (no line '$3' in ${2##*/})"; fi
}
assert_file_matches() { # desc file ERE
  if [ -f "$2" ] && grep -qE -- "$3" "$2"; then ok "$1"; else fail "$1 (no match /$3/ in ${2##*/})"; fi
}
assert_file_empty() { # desc file
  if [ ! -s "$2" ]; then ok "$1"; else fail "$1 (${2##*/} has content: $(head -c 200 "$2" | tr '\n' '|'))"; fi
}
assert_first_line() { # desc file exact-first-line
  local got; got=$(head -n 1 "$2" 2>/dev/null)
  assert_eq "$1" "$3" "$got"
}
assert_exists()  { if [ -e "$2" ] || [ -L "$2" ]; then ok "$1"; else fail "$1 ($2 missing)"; fi; }
assert_absent()  { if [ -e "$2" ] || [ -L "$2" ]; then fail "$1 ($2 exists)"; else ok "$1"; fi; }
assert_dir()     { if [ -d "$2" ] && [ ! -L "$2" ]; then ok "$1"; else fail "$1 ($2 is not a real dir)"; fi; }
assert_link_to() { # desc link target
  local cur
  if [ -L "$2" ]; then
    cur=$(readlink "$2")
    if [ "$cur" = "$3" ]; then ok "$1"; else fail "$1 ($2 -> '$cur', expected '$3')"; fi
  else
    fail "$1 ($2 is not a symlink)"
  fi
}
mode_of() { ls -ld -- "$1" 2>/dev/null | cut -c1-10; }
assert_mode() { # desc path ls-mode-string
  local got; got=$(mode_of "$2")
  assert_eq "$1" "$3" "$got"
}
inode_of() { ls -di -- "$1" 2>/dev/null | awk '{print $1}'; }
assert_same_file() { # desc a b  (byte-identical)
  if cmp -s -- "$2" "$3"; then ok "$1"; else fail "$1 (${2##*/} differs from ${3##*/})"; fi
}
out_has()     { assert_file_has "$1" "$T/out" "$2"; }
out_lacks()   { assert_file_lacks "$1" "$T/out" "$2"; }
out_line()    { assert_file_line "$1" "$T/out" "$2"; }
out_matches() { assert_file_matches "$1" "$T/out" "$2"; }
err_has()     { assert_file_has "$1" "$T/err" "$2"; }
err_matches() { assert_file_matches "$1" "$T/err" "$2"; }
count_matches() { grep -cE -- "$2" "$1" 2>/dev/null || true; }

# ---------- fixtures (payload files, written once, copied into every stub HOME) ----------
make_fixtures() {
  FIX=$(mktemp -d "$TMP_BASE/cmh-fix.XXXXXX") || { printf 'harness: mktemp failed\n' >&2; exit 1; }

  # stub claude: `auth login --email <x>` and `auth status` (§12.2/12.3) are recorded in $HOME/stub-claude.log and
  # answered from a marker file $CLAUDE_CONFIG_DIR/.stub-logged-in (login creates it; $HOME/stub-login-fails makes
  # login exit 1 instead; STUB_LOGIN_AS=<email> makes the marker — and so `auth status` — name that email instead of
  # the --email one). Every other invocation prints the two §10 lines, byte-identical to v1.0 (T14 asserts them).
  cat > "$FIX/claude" <<'EOF'
#!/bin/sh
# stub claude: prints what a launcher handed it, exactly as docs/design.md §10 says; `auth login` / `auth status`
# (§12) are logged to $HOME/stub-claude.log and answered from the marker file $CLAUDE_CONFIG_DIR/.stub-logged-in
log=${HOME:-/tmp}/stub-claude.log
cfg=${CLAUDE_CONFIG_DIR-}
if [ "${1-}" = auth ]; then
  case "${2-}" in
    login)
      email=""; prev=""
      for a in "$@"; do [ "$prev" = --email ] && email=$a; prev=$a; done
      printf 'auth-login CLAUDE_CONFIG_DIR=%s KEY=%s TOKEN1=%s TOKEN2=%s ARGS=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" \
        "${ANTHROPIC_API_KEY-<unset>}" "${ANTHROPIC_AUTH_TOKEN-<unset>}" "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}" "$*" >> "$log"
      if [ -f "${HOME:-/tmp}/stub-login-fails" ]; then printf 'stub claude: login failed (stub-login-fails present)\n' >&2; exit 1; fi
      if [ -n "$cfg" ]; then mkdir -p "$cfg" && printf '%s\n' "${STUB_LOGIN_AS:-$email}" > "$cfg/.stub-logged-in"; fi
      printf 'stub claude: logged in as %s\n' "$email"
      exit 0 ;;
    status)
      printf 'auth-status CLAUDE_CONFIG_DIR=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" >> "$log"
      if [ -n "$cfg" ] && [ -f "$cfg/.stub-logged-in" ]; then
        printf '{"loggedIn": true, "authMethod": "claude.ai", "email": "%s"}\n' "$(cat "$cfg/.stub-logged-in")"
      else
        printf '{"loggedIn": false, "authMethod": "none"}\n'
      fi
      exit 0 ;;
  esac
fi
printf 'stub claude CLAUDE_CONFIG_DIR=%s KEY=%s ARGS=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" "${ANTHROPIC_API_KEY-<unset>}" "$*"
printf 'stub env AUTH_TOKEN=%s OAUTH=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}" "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
EOF

  # stub curl (T23): serves CLAUDE_MULTI_UPDATE_URL=file://… — copies the file to the -o target (stdout without -o),
  # exit 22 (curl's HTTP-error code under -f) when it is missing; every call is logged to $HOME/stub-curl.log
  cat > "$FIX/curl" <<'EOF'
#!/bin/sh
printf 'curl %s\n' "$*" >> "${HOME:-/tmp}/stub-curl.log"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o | --output) shift; out=${1-} ;;
    -o?*) out=${1#-o} ;;
    -*) ;;
    *) url=$1 ;;
  esac
  shift
done
src=${url#file://}
if [ ! -f "$src" ]; then printf 'stub curl: (22) not found: %s\n' "$url" >&2; exit 22; fi
if [ -n "$out" ]; then cp -- "$src" "$out"; else cat -- "$src"; fi
EOF

  # stub cswap: behaviour from bin/cswap.mode (json | export-only | ansi-only | broken); every call is logged
  cat > "$FIX/cswap" <<'EOF'
#!/bin/sh
d=$(cd "$(dirname "$0")" && pwd)
mode=$(cat "$d/cswap.mode" 2>/dev/null || printf broken)
printf '%s\n' "cswap $*" >> "$d/../../cswap.log"
sub=${1-}; arg=${2-}
case "$mode:$sub:$arg" in
  json:list:--json)                          cat "$d/cswap-list.json" ;;
  json:export:?*|export-only:export:?*)      cp "$d/cswap-export.json" "$arg" ;;
  json:list:|export-only:list:|ansi-only:list:) cat "$d/cswap-list.ansi" ;;
  *) printf 'cswap: unsupported in mode %s: %s\n' "$mode" "$*" >&2; exit 1 ;;
esac
EOF

  cat > "$FIX/cswap-list.json" <<'EOF'
{
  "active": 1,
  "accounts": [
    {"number": 1, "email": "alice@example.com", "organization": "Alice's Coffee Co.", "active": true},
    {"number": 2, "email": "hans@betterdoc.test", "organization": "BetterDoc GmbH", "active": false},
    {"number": 3, "email": "info@corp.test", "organization": "Corp Inc.", "active": false},
    {"number": 4, "email": "hans@proton.test", "organization": "personal", "active": false}
  ]
}
EOF

  cat > "$FIX/cswap-list5.json" <<'EOF'
{
  "active": 1,
  "accounts": [
    {"number": 1, "email": "alice@example.com", "organization": "Alice's Coffee Co.", "active": true},
    {"number": 2, "email": "hans@betterdoc.test", "organization": "BetterDoc GmbH", "active": false},
    {"number": 3, "email": "info@corp.test", "organization": "Corp Inc.", "active": false},
    {"number": 4, "email": "hans@proton.test", "organization": "personal", "active": false},
    {"number": 5, "email": "alice@other.test", "organization": "Other Org", "active": false}
  ]
}
EOF

  cat > "$FIX/cswap-export.json" <<'EOF'
{
  "version": 1,
  "accounts": [
    {"number": 1, "email": "alice@example.com", "organization": "Alice's Coffee Co.",
     "accessToken": "sk-ant-oat01-FAKETOKEN-alice", "refreshToken": "sk-ant-ort01-FAKETOKEN-alice"},
    {"number": 2, "email": "hans@betterdoc.test", "organization": "BetterDoc GmbH",
     "accessToken": "sk-ant-oat01-FAKETOKEN-hans1", "refreshToken": "sk-ant-ort01-FAKETOKEN-hans1"},
    {"number": 3, "email": "info@corp.test", "organization": "Corp Inc.",
     "accessToken": "sk-ant-oat01-FAKETOKEN-info", "refreshToken": "sk-ant-ort01-FAKETOKEN-info"},
    {"number": 4, "email": "hans@proton.test", "organization": "personal",
     "accessToken": "sk-ant-oat01-FAKETOKEN-hans2", "refreshToken": "sk-ant-ort01-FAKETOKEN-hans2"}
  ]
}
EOF

  # ANSI listing: <ESC> placeholders become real ESC bytes (awk -v processes the \033 escape)
  cat > "$FIX/cswap-list.ansi.tpl" <<'EOF'
<ESC>[1;36mClaude Code accounts<ESC>[0m
<ESC>[32m  1: alice@example.com<ESC>[0m  <ESC>[2m[Alice's Coffee Co.]<ESC>[0m  <ESC>[33m(active)<ESC>[0m
  2: hans@betterdoc.test  <ESC>[2m[BetterDoc GmbH]<ESC>[0m
  3: info@corp.test  <ESC>[2m[Corp Inc.]<ESC>[0m
  4: hans@proton.test  <ESC>[2m[personal]<ESC>[0m
<ESC>[2mUse 'cswap use <n>' to switch the default account.<ESC>[0m
EOF
  awk -v esc='\033' '{ gsub(/<ESC>/, esc); print }' "$FIX/cswap-list.ansi.tpl" > "$FIX/cswap-list.ansi"

  cat > "$FIX/failing-tool" <<'EOF'
#!/bin/sh
printf 'stub %s: not available in this test\n' "$0" >&2
exit 1
EOF

  cat > "$FIX/seed-settings.json" <<'EOF'
{
  "theme": "dark",
  "permissions": { "allow": ["Bash(ls:*)"] },
  "note": "Alice's settings — seeded from ~/.claude/settings.json"
}
EOF

  cat > "$FIX/seed-claude.json" <<'EOF'
{
  "mcpServers": {
    "demo": { "command": "echo", "args": ["hi"] }
  },
  "oauthAccount": { "emailAddress": "alice@example.com", "organizationName": "Alice's Coffee Co." },
  "projects": {},
  "numStartups": 3
}
EOF

  # T14 driver: run inside `zsh -f -c` / `bash --norc --noprofile -c`; writes one file per probe into $P
  cat > "$FIX/t14-driver.sh" <<'EOF'
[ -n "${BASH_VERSION:-}" ] && shopt -s expand_aliases
cfg() { printf '%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" > "$P/$1.cfg"; }
key() { printf '%s\n' "${ANTHROPIC_API_KEY-<unset>}" > "$P/$1.key"; }
export ANTHROPIC_API_KEY=sk-ant-LEAK
export ANTHROPIC_AUTH_TOKEN=tok-LEAK
export CLAUDE_CODE_OAUTH_TOKEN=oauth-LEAK
unset CLAUDE_CONFIG_DIR
state=mine; mark=mine; slot=mine; slug=mine; email=mine
. "$HOME/.claude-multi/aliases.sh" > "$P/source.out" 2> "$P/source.err"; echo $? > "$P/source.rc"
cfg after-source; key after-source
cwho > "$P/cwho-unpinned.out" 2> "$P/cwho-unpinned.err"; echo $? > "$P/cwho-unpinned.rc"
cuse > "$P/cuse-noarg.out" 2> "$P/cuse-noarg.err"; echo $? > "$P/cuse-noarg.rc"
cuse nonexistent > "$P/cuse-missing.out" 2> "$P/cuse-missing.err"; echo $? > "$P/cuse-missing.rc"
cfg cuse-missing
cuse hans-proton > "$P/cuse-slug.out" 2> "$P/cuse-slug.err"; echo $? > "$P/cuse-slug.rc"
cfg cuse-slug
cwho > "$P/cwho-pinned.out" 2> "$P/cwho-pinned.err"; echo $? > "$P/cwho-pinned.rc"
cuse 1 > "$P/cuse-slot.out" 2> "$P/cuse-slot.err"; echo $? > "$P/cuse-slot.rc"
cfg cuse-slot
claude-hans-betterdoc --print hello > "$P/launcher-fn.out" 2> "$P/launcher-fn.err"; echo $? > "$P/launcher-fn.rc"
cfg launcher-fn; key launcher-fn
eval 'claude3 mcp list' > "$P/launcher-alias.out" 2> "$P/launcher-alias.err"; echo $? > "$P/launcher-alias.rc"
( PATH=/usr/bin:/bin; claude-alice ) > "$P/launcher-nobin.out" 2>&1; echo $? > "$P/launcher-nobin.rc"
_claude_multi_run nosuchslug > "$P/launcher-nodir.out" 2>&1; echo $? > "$P/launcher-nodir.rc"
_claude_multi_find 4 > "$P/find-slot.out" 2>&1
_claude_multi_find alice > "$P/find-slug.out" 2>&1
_claude_multi_find nope > "$P/find-none.out" 2>&1
_claude_multi_accounts > "$P/accounts.out" 2>&1
cuse default > "$P/cuse-default.out" 2> "$P/cuse-default.err"; echo $? > "$P/cuse-default.rc"
cfg cuse-default
cwho > "$P/cwho-after-default.out" 2>&1
key final
printf '%s\n' "$state|$mark|$slot|$slug|$email" > "$P/globals.out"
exit 0
EOF

  # T19 driver (§12.1): the `claude-multi` umbrella + CLAUDE_MULTI_ACCOUNT, run inside `zsh -f -c` / `bash --norc -c`
  cat > "$FIX/t19-driver.sh" <<'EOF'
[ -n "${BASH_VERSION:-}" ] && shopt -s expand_aliases
cfg() { printf '%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" > "$P/$1.cfg"; }
acct() { printf '%s\n' "${CLAUDE_MULTI_ACCOUNT-<unset>}" > "$P/$1.acct"; }
exported() { sh -c 'printf "%s|%s\n" "${CLAUDE_CONFIG_DIR-<unset>}" "${CLAUDE_MULTI_ACCOUNT-<unset>}"' > "$P/$1.exported"; }
unset CLAUDE_CONFIG_DIR CLAUDE_MULTI_ACCOUNT
. "$HOME/.claude-multi/aliases.sh" > "$P/source.out" 2> "$P/source.err"; echo $? > "$P/source.rc"
cfg after-source; acct after-source
type claude-multi > "$P/type.out" 2>&1
claude-multi who > "$P/who.out" 2> "$P/who.err"; echo $? > "$P/who.rc"
cwho > "$P/cwho.out" 2> "$P/cwho.err"
claude-multi use info > "$P/use.out" 2> "$P/use.err"; echo $? > "$P/use.rc"
cfg use; acct use; exported use
claude-multi who > "$P/who-pinned.out" 2>&1
cwho > "$P/cwho-pinned.out" 2>&1
claude-multi status > "$P/status.out" 2> "$P/status.err"; echo $? > "$P/status.rc"
"$HOME/.claude-multi/claude-multi-setup.sh" status > "$P/status-direct.out" 2> "$P/status-direct.err"
claude-multi use default > "$P/default.out" 2> "$P/default.err"; echo $? > "$P/default.rc"
cfg default; acct default; exported default
cuse hans-proton > "$P/cuse.out" 2>&1; echo $? > "$P/cuse.rc"
acct cuse; exported cuse
cuse default > /dev/null 2>&1
acct cuse-default; cfg cuse-default
claude-multi use nonexistent > "$P/use-missing.out" 2> "$P/use-missing.err"; echo $? > "$P/use-missing.rc"
acct use-missing
claude-multi help > "$P/help.out" 2> "$P/help.err"; echo $? > "$P/help.rc"
claude-multi > "$P/noarg.out" 2> "$P/noarg.err"; echo $? > "$P/noarg.rc"
claude-multi --help > "$P/dashhelp.out" 2>&1; echo $? > "$P/dashhelp.rc"
rm -f "$HOME/.claude-accounts/info/skills"
claude-multi relink > "$P/relink.out" 2> "$P/relink.err"; echo $? > "$P/relink.rc"
claude-multi --dry-run > "$P/dryrun.out" 2>&1; echo $? > "$P/dryrun.rc"
claude-multi --version > "$P/version.out" 2>&1; echo $? > "$P/version.rc"
cfg final; acct final
exit 0
EOF
}

# ---------- per-case HOME ----------
new_home() { # a fresh HOME with bin/claude, a seeded ~/.claude, ~/.claude.json and ~/.zshrc; no cswap yet
  T=$(mktemp -d "$TMP_BASE/cmh.XXXXXX") || { printf '  FAIL: mktemp failed\n'; exit 1; }
  H="$T/home"
  mkdir -p "$H/bin" "$T/tmp" "$H/.claude/skills/demo" "$H/.claude/commands"
  cp "$FIX/claude" "$H/bin/claude"; chmod 755 "$H/bin/claude"
  cp "$FIX/seed-settings.json" "$H/.claude/settings.json"
  cp "$FIX/seed-claude.json" "$H/.claude.json"
  printf '# seed CLAUDE.md\n' > "$H/.claude/CLAUDE.md"
  printf '%s\n' '---' 'name: demo' '---' "A demo skill (Alice's)." > "$H/.claude/skills/demo/SKILL.md"
  printf 'echo hi\n' > "$H/.claude/commands/hi.md"
  printf '# seeded zshrc\n' > "$H/.zshrc"
  # snapshots for "untouched" assertions
  cp "$H/.zshrc" "$T/zshrc.seed"
  cp "$H/.claude.json" "$T/claude.json.seed"
  snapshot_seed
  touch "$T/stamp-seed"
}
snapshot_seed() { ( cd "$H" && find .claude .claude.json | sort ) > "$T/claude-tree.seed"; }
teardown_home() {
  [ -n "$T" ] || return 0
  if [ "$KEEP" = 1 ]; then KEPT_DIRS="$KEPT_DIRS $T"; else rm -rf "$T"; fi
  T=""; H=""
}
set_cswap() { # json | json5 | export-only | ansi-only | broken | absent
  rm -f "$H/bin/cswap" "$H/bin/cswap.mode" "$H/bin/cswap-list.json" "$H/bin/cswap-export.json" "$H/bin/cswap-list.ansi"
  [ "$1" = absent ] && return 0
  cp "$FIX/cswap" "$H/bin/cswap"; chmod 755 "$H/bin/cswap"
  case "$1" in
    json5) printf 'json\n' > "$H/bin/cswap.mode"; cp "$FIX/cswap-list5.json" "$H/bin/cswap-list.json" ;;
    *)     printf '%s\n' "$1" > "$H/bin/cswap.mode"; cp "$FIX/cswap-list.json" "$H/bin/cswap-list.json" ;;
  esac
  cp "$FIX/cswap-export.json" "$H/bin/cswap-export.json"
  cp "$FIX/cswap-list.ansi" "$H/bin/cswap-list.ansi"
}
shadow_tools() { # make jq and python3 fail inside this HOME's PATH
  local t
  for t in "$@"; do cp "$FIX/failing-tool" "$H/bin/$t"; chmod 755 "$H/bin/$t"; done
}
stamp() { touch "$T/stamp"; sleep 1; }
newer_than() { # stamp-file → paths under $H (except bin/) modified after it
  find "$H" -newer "$1" ! -path "$H/bin" ! -path "$H/bin/*" 2>/dev/null | sort
}

# ---------- running the script under test ----------
RC=0
HAVE_TTY=0; ( : < /dev/tty ) 2>/dev/null && HAVE_TTY=1   # the script would read /dev/tty for its prompts (§4 step 4, §12.4)
run_script() { # [VAR=value …] -- args…   → $T/out, $T/err, $RC; a 60 s watchdog kills a hung script
  local pid wd n own_input=0
  local -a extra
  extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do
    case "$1" in CLAUDE_MULTI_INPUT=*) own_input=1 ;; esac
    extra[${#extra[@]}]=$1; shift
  done
  [ "${1-}" = "--" ] && shift
  # in a terminal the script would block on /dev/tty (offers, email prompt) until the watchdog: hand it an EMPTY
  # answers file instead — the §12.4 hook at EOF asks nothing, which is what a tty-less run gets anyway
  if [ "$HAVE_TTY" = 1 ] && [ "$own_input" = 0 ]; then
    : > "$T/no-answers"
    extra[${#extra[@]}]="CLAUDE_MULTI_INPUT=$T/no-answers"
  fi
  env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" TMPDIR="$T/tmp" SHELL=/bin/zsh TERM=dumb \
    ${extra[@]+"${extra[@]}"} "$RUN_BASH" "$SCRIPT" "$@" > "$T/out" 2> "$T/err" < /dev/null &
  pid=$!
  ( n=0; while [ "$n" -lt 60 ]; do sleep 1; n=$((n + 1)); kill -0 "$pid" 2>/dev/null || exit 0; done
    kill "$pid" 2>/dev/null ) &
  wd=$!
  wait "$pid"; RC=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  return 0
}

# ---------- shared assertion bundles ----------
assert_seed_untouched() { # ~/.claude, ~/.claude.json and the rc files are exactly as seeded
  local tree
  tree=$( cd "$H" && find .claude .claude.json | sort )
  assert_eq "~/.claude tree unchanged" "$(cat "$T/claude-tree.seed")" "$tree"
  assert_eq "nothing under ~/.claude modified" "" "$(find "$H/.claude" "$H/.claude.json" -newer "$T/stamp-seed" | sort)"
  assert_same_file "~/.claude.json byte-identical" "$T/claude.json.seed" "$H/.claude.json"
}
assert_rc_untouched() {
  assert_same_file "~/.zshrc untouched" "$T/zshrc.seed" "$H/.zshrc"
  assert_absent "no ~/.bashrc created" "$H/.bashrc"
}
assert_account_dir() { # slug → dir 700 + 5 absolute symlinks
  local slug=$1 n
  assert_dir "dir $slug exists" "$H/.claude-accounts/$slug"
  assert_mode "dir $slug is mode 700" "$H/.claude-accounts/$slug" "drwx------"
  for n in $SHARED_NAMES; do
    assert_link_to "$slug/$n -> shared (absolute)" "$H/.claude-accounts/$slug/$n" "$H/.claude-shared/$n"
  done
}
assert_registry_row() { # slot email slug
  assert_file_line "accounts.tsv row $1 $2 $3" "$H/.claude-multi/accounts.tsv" "$1${TAB}$2${TAB}$3"
}
registry_rows() { grep -v '^#' "$H/.claude-multi/accounts.tsv" 2>/dev/null | grep -c . || true; }
assert_aliases_parse() {
  local f="$H/.claude-multi/aliases.sh"
  assert_exists "aliases.sh exists" "$f"
  if [ -n "$ZSH_BIN" ]; then assert_true "zsh -n aliases.sh" "$ZSH_BIN" -n "$f"; else fail "zsh not installed (needed for zsh -n)"; fi
  assert_true "bash -n aliases.sh ($RUN_BASH)" "$RUN_BASH" -n "$f"
  [ -x /bin/bash ] && assert_true "bash -n aliases.sh (/bin/bash)" /bin/bash -n "$f"
}
assert_four_accounts() { # the T1–T4 result
  assert_rc "setup" 0
  assert_account_dir alice
  assert_account_dir hans-betterdoc
  assert_account_dir info
  assert_account_dir hans-proton
  assert_eq "exactly 4 account dirs" "4" "$(find "$H/.claude-accounts" -mindepth 1 -maxdepth 1 2>/dev/null | grep -c .)"
  assert_first_line "accounts.tsv v2 header" "$H/.claude-multi/accounts.tsv" \
    '# claude-multi accounts: slot<TAB>email<TAB>slug. Edit with `claude-multi-setup.sh add|remove`.'
  assert_registry_row 1 alice@example.com alice
  assert_registry_row 2 hans@betterdoc.test hans-betterdoc
  assert_registry_row 3 info@corp.test info
  assert_registry_row 4 hans@proton.test hans-proton
  assert_eq "accounts.tsv has 4 rows" "4" "$(registry_rows)"
  assert_aliases_parse
  assert_seed_untouched
  assert_rc_untouched
  out_matches "summary: alice line" '^  1 +claude-alice +alice@example.com +'"$H"'/\.claude-accounts/alice$'
  out_matches "summary: login hint for hans-proton" '^  claude-multi login hans-proton +\(hans@proton\.test\)'
  out_has "summary: Shared config line" "Shared config: "
  out_has "summary: Aliases line" "Aliases: "
  out_has "summary: rc file line" "rc file: "
}
assert_shared_seeded() {
  assert_same_file "shared settings.json byte-identical to seed" "$H/.claude/settings.json" "$H/.claude-shared/settings.json"
  assert_dir "shared skills is a real copied dir" "$H/.claude-shared/skills"
  assert_same_file "shared skills/demo/SKILL.md copied" "$H/.claude/skills/demo/SKILL.md" "$H/.claude-shared/skills/demo/SKILL.md"
  assert_same_file "shared commands/hi.md copied" "$H/.claude/commands/hi.md" "$H/.claude-shared/commands/hi.md"
  assert_dir "shared agents dir created" "$H/.claude-shared/agents"
  assert_same_file "shared CLAUDE.md copied" "$H/.claude/CLAUDE.md" "$H/.claude-shared/CLAUDE.md"
  assert_file_has "shared mcp.json carries the demo server from ~/.claude.json" "$H/.claude-shared/mcp.json" '"demo"'
  assert_file_lacks "shared mcp.json carries nothing but mcpServers" "$H/.claude-shared/mcp.json" 'oauthAccount'
  assert_mode "shared mcp.json is mode 600 (it may carry MCP server tokens)" "$H/.claude-shared/mcp.json" "-rw-------"
  if command -v jq >/dev/null 2>&1; then
    assert_eq "shared mcp.json .mcpServers.demo.command" "echo" "$(jq -r '.mcpServers.demo.command' "$H/.claude-shared/mcp.json" 2>/dev/null)"
  fi
}

# ---------- cases ----------
case_T1() { # cswap list --json, 4 accounts
  set_cswap json
  run_script -- setup
  assert_four_accounts
  assert_shared_seeded
  out_matches "source is cswap list --json" '^Accounts \(source: .*list --json'
}

case_T2() { # export-only cswap: list --json fails
  set_cswap export-only
  run_script -- setup
  assert_four_accounts
  assert_shared_seeded
  out_matches "source is cswap export" '^Accounts \(source: .*cswap export'
  assert_eq "no claude-multi.* left under TMPDIR" "" "$(find "$T/tmp" -name 'claude-multi*' 2>/dev/null)"
  assert_eq "no export.json left anywhere under TMPDIR" "" "$(find "$T/tmp" -name '*.json' 2>/dev/null)"
  assert_file_lacks "no token printed on stdout" "$T/out" FAKETOKEN
  assert_file_lacks "no token printed on stderr" "$T/err" FAKETOKEN
}

case_T3() { # ANSI-only cswap
  set_cswap ansi-only
  run_script -- setup
  assert_four_accounts
  assert_shared_seeded
  out_matches "source is the scraped listing" '^Accounts \(source: .*[Ss]crap'
}

case_T4() { # jq + python3 shadowed with failing stubs
  set_cswap json
  shadow_tools jq python3
  run_script -- setup
  assert_four_accounts
  err_has "warning about mcp.json without jq/python3" "warning:"
  err_has "warning names mcp.json" "mcp.json"
  assert_file_has "mcp.json still seeded (empty mcpServers)" "$H/.claude-shared/mcp.json" '"mcpServers"'
}

case_T5() { # no cswap: add, add --slot 5, add again
  set_cswap absent
  run_script -- add a@x.test
  assert_rc "add a@x.test" 0
  assert_registry_row 1 a@x.test a
  assert_dir "dir a exists" "$H/.claude-accounts/a"
  run_script -- add b@y.test --slot 5
  assert_rc "add b@y.test --slot 5" 0
  assert_registry_row 1 a@x.test a
  assert_registry_row 5 b@y.test b
  assert_eq "accounts.tsv has 2 rows" "2" "$(registry_rows)"
  assert_dir "dir b exists" "$H/.claude-accounts/b"
  assert_file_matches "launcher claude-a defined" "$H/.claude-multi/aliases.sh" '^claude-a\(\)'
  assert_file_matches "launcher claude-b defined" "$H/.claude-multi/aliases.sh" '^claude-b\(\)'
  assert_file_line "alias claude1 -> claude-a" "$H/.claude-multi/aliases.sh" "alias claude1='claude-a'"
  assert_file_line "alias claude5 -> claude-b" "$H/.claude-multi/aliases.sh" "alias claude5='claude-b'"
  out_matches "summary lists slot 5 launcher" '^  5 +claude-b +b@y\.test +'
  cp "$H/.claude-multi/accounts.tsv" "$T/registry.before" 2>/dev/null
  run_script -- add a@x.test
  assert_rc "add a@x.test again" 0
  out_has "second add is a no-op" "No changes"
  assert_same_file "registry unchanged by the repeated add" "$T/registry.before" "$H/.claude-multi/accounts.tsv"
  run_script -- add c@z.test --slot 5
  assert_rc "add with a taken slot" 1
  err_matches "taken slot reported as error:" '^error: '
  assert_eq "taken slot registered nothing" "2" "$(registry_rows)"
  assert_rc_untouched
}

case_T6() { # ACCOUNT_ROWS with a broken cswap in PATH
  set_cswap broken
  run_script "ACCOUNT_ROWS=1${TAB}alice@example.com${NL}2${TAB}bob@example.com" -- setup
  assert_rc "setup" 0
  assert_account_dir alice
  assert_account_dir bob
  assert_registry_row 1 alice@example.com alice
  assert_registry_row 2 bob@example.com bob
  assert_absent "cswap was never consulted" "$T/cswap.log"
  out_matches "source is ACCOUNT_ROWS" '^Accounts \(source: .*ACCOUNT_ROWS'
  assert_seed_untouched
}

case_T7() { # no cswap, no registry, --no-input, stdin not a tty
  set_cswap absent
  run_script -- --no-input
  assert_rc "setup --no-input with nothing to discover" 1
  err_matches "stderr starts with 'error: '" '^error: '
  err_has "message names ACCOUNT_ROWS" "ACCOUNT_ROWS"
  err_has "message names add" "add"
  assert_absent "no account dirs created" "$H/.claude-accounts"
  assert_seed_untouched
}

case_T8() { # --dry-run on a fresh HOME
  set_cswap json
  run_script -- --dry-run
  assert_rc "dry-run" 0
  out_matches "at least one 'would' line" '^  \[dry-run\] would '
  assert_absent "nothing created: ~/.claude-multi" "$H/.claude-multi"
  assert_absent "nothing created: ~/.claude-accounts" "$H/.claude-accounts"
  assert_absent "nothing created: ~/.claude-shared" "$H/.claude-shared"
  assert_eq "no '  + ' change lines in dry-run" "0" "$(count_matches "$T/out" '^  \+ ')"
  assert_seed_untouched
  assert_rc_untouched
}

case_T9() { # second run is a no-op
  set_cswap json
  run_script -- setup
  assert_rc "first run" 0
  ( cd "$H" && find . ! -path './bin*' | sort ) > "$T/tree.1"
  touch -r "$H/.claude-multi/aliases.sh" "$T/aliases.ref" 2>/dev/null
  stamp
  run_script -- setup
  assert_rc "second run" 0
  out_line "second run says No changes" "No changes — everything was already in place."
  assert_eq "no '  + ' change lines" "0" "$(count_matches "$T/out" '^  \+ ')"
  assert_eq "nothing under HOME modified" "" "$(newer_than "$T/stamp")"
  assert_eq "same file tree" "$(cat "$T/tree.1")" "$( cd "$H" && find . ! -path './bin*' | sort )"
  assert_eq "aliases.sh mtime unchanged (not newer than ref)" "" "$(find "$H/.claude-multi/aliases.sh" -newer "$T/aliases.ref" 2>/dev/null)"
  assert_eq "aliases.sh mtime unchanged (ref not newer)" "" "$(find "$T/aliases.ref" -newer "$H/.claude-multi/aliases.sh" 2>/dev/null)"
  # §9: a seeded shared file is never overwritten — edit two of them, re-run, the edits survive
  printf '{"user":"edited"}\n' > "$H/.claude-shared/settings.json"
  printf '# mine\n' >> "$H/.claude-shared/CLAUDE.md"
  run_script -- setup
  assert_rc "third run after editing shared files" 0
  assert_file_has "seeded settings.json not overwritten" "$H/.claude-shared/settings.json" '"edited"'
  assert_file_has "seeded CLAUDE.md not overwritten" "$H/.claude-shared/CLAUDE.md" '# mine'
}

case_T10() { # a 5th account appears in cswap
  local i1 i2 i3 i4 rows
  set_cswap json
  run_script -- setup
  assert_rc "first run" 0
  i1=$(inode_of "$H/.claude-accounts/alice"); i2=$(inode_of "$H/.claude-accounts/hans-betterdoc")
  i3=$(inode_of "$H/.claude-accounts/info");  i4=$(inode_of "$H/.claude-accounts/hans-proton")
  rows=$(registry_rows)
  set_cswap json5
  run_script -- setup
  assert_rc "second run with 5 accounts" 0
  assert_eq "alice dir same inode" "$i1" "$(inode_of "$H/.claude-accounts/alice")"
  assert_eq "hans-betterdoc dir same inode" "$i2" "$(inode_of "$H/.claude-accounts/hans-betterdoc")"
  assert_eq "info dir same inode" "$i3" "$(inode_of "$H/.claude-accounts/info")"
  assert_eq "hans-proton dir same inode" "$i4" "$(inode_of "$H/.claude-accounts/hans-proton")"
  assert_account_dir alice-other
  assert_registry_row 5 alice@other.test alice-other
  assert_eq "registry gained exactly one row" "$((rows + 1))" "$(registry_rows)"
  assert_file_line "alias claude5 -> claude-alice-other" "$H/.claude-multi/aliases.sh" "alias claude5='claude-alice-other'"
  assert_file_matches "launcher claude-alice-other defined" "$H/.claude-multi/aliases.sh" '^claude-alice-other\(\)'
  assert_registry_row 1 alice@example.com alice
}

case_T11() { # --relink after deleting one link
  set_cswap json
  run_script -- setup
  assert_rc "first run" 0
  stamp
  rm -f "$H/.claude-accounts/info/skills"
  run_script -- --relink
  assert_rc "--relink" 0
  assert_link_to "info/skills restored" "$H/.claude-accounts/info/skills" "$H/.claude-shared/skills"
  assert_eq "exactly one change line" "1" "$(count_matches "$T/out" '^  \+ ')"
  out_matches "the change line is the relink" '^  \+ .*info/skills'
  assert_eq "nothing else modified" "" "$(newer_than "$T/stamp" | grep -v -x -e "$H/.claude-accounts/info" -e "$H/.claude-accounts/info/skills")"
  assert_eq "aliases.sh not regenerated" "" "$(find "$H/.claude-multi/aliases.sh" -newer "$T/stamp" 2>/dev/null)"
}

case_T12() { # per-repo memory links
  local pa="-Users-x-repo-a" pb="-Users-x-repo-b" pc="-Users-x-repo-c" pd="-Users-x-repo-d"
  set_cswap absent
  mkdir -p "$H/.claude/projects/$pa/memory" "$H/.claude/projects/$pb/memory" "$H/.claude/projects/$pc"
  printf '# memory a\n' > "$H/.claude/projects/$pa/memory/MEMORY.md"
  printf '{}\n' > "$H/.claude/projects/$pc/session.jsonl"
  snapshot_seed; touch "$T/stamp-seed"
  mkdir -p "$H/.claude-accounts/alice/projects/$pa/memory"          # alice: EMPTY real dir → replaced
  mkdir -p "$H/.claude-accounts/bob/projects/$pa/memory"            # bob: non-empty real dir → warned, kept
  printf 'bob notes\n' > "$H/.claude-accounts/bob/projects/$pa/memory/NOTES.md"
  cp "$H/.claude-accounts/bob/projects/$pa/memory/NOTES.md" "$T/bob-notes.before"
  run_script "ACCOUNT_ROWS=1${TAB}alice@example.com${NL}2${TAB}bob@example.com" -- setup
  assert_rc "setup (warnings are not errors)" 0
  assert_link_to "alice repo-a: empty dir replaced by link" "$H/.claude-accounts/alice/projects/$pa/memory" "$H/.claude/projects/$pa/memory"
  out_has "change line says 'replace empty dir'" "replace empty dir"
  assert_dir "bob repo-a: non-empty dir left alone" "$H/.claude-accounts/bob/projects/$pa/memory"
  assert_same_file "bob's NOTES.md intact" "$T/bob-notes.before" "$H/.claude-accounts/bob/projects/$pa/memory/NOTES.md"
  err_has "warning names bob's path" "$H/.claude-accounts/bob/projects/$pa/memory"
  err_has "warning says left alone" "left alone"
  assert_link_to "alice repo-b (empty memory dir in ~/.claude) linked" "$H/.claude-accounts/alice/projects/$pb/memory" "$H/.claude/projects/$pb/memory"
  assert_absent "repo-c (no memory dir) skipped for alice" "$H/.claude-accounts/alice/projects/$pc"
  assert_absent "repo-c skipped for bob" "$H/.claude-accounts/bob/projects/$pc"
  assert_mode "alice/projects/repo-b is mode 700" "$H/.claude-accounts/alice/projects/$pb" "drwx------"
  assert_seed_untouched
  # a repo that gains memory later is picked up by --relink
  mkdir -p "$H/.claude/projects/$pd/memory"; printf '# memory d\n' > "$H/.claude/projects/$pd/memory/MEMORY.md"
  run_script -- --relink
  assert_rc "--relink" 0
  assert_link_to "alice repo-d linked by --relink" "$H/.claude-accounts/alice/projects/$pd/memory" "$H/.claude/projects/$pd/memory"
  assert_link_to "bob repo-d linked by --relink" "$H/.claude-accounts/bob/projects/$pd/memory" "$H/.claude/projects/$pd/memory"
  assert_mode "alice/projects/repo-d is mode 700" "$H/.claude-accounts/alice/projects/$pd" "drwx------"
  assert_dir "bob repo-a still a real dir after --relink" "$H/.claude-accounts/bob/projects/$pa/memory"
}

case_T13() { # --rc twice with zsh, then bash, then --rc=FILE
  set_cswap json
  run_script SHELL=/bin/zsh -- --rc
  assert_rc "--rc (zsh)" 0
  assert_file_line "~/.zshrc has the source line" "$H/.zshrc" "$RC_LINE"
  assert_eq "~/.zshrc has exactly one aliases line" "1" "$(count_matches "$H/.zshrc" 'claude-multi/aliases')"
  assert_eq "~/.zshrc line 1 is the seed" "# seeded zshrc" "$(sed -n '1p' "$H/.zshrc")"
  assert_eq "~/.zshrc line 2 is the blank separator" "" "$(sed -n '2p' "$H/.zshrc")"
  assert_eq "~/.zshrc is 3 lines" "3" "$(grep -c '' "$H/.zshrc")"
  cp "$H/.zshrc" "$T/zshrc.1"
  run_script SHELL=/bin/zsh -- --rc
  assert_rc "--rc (zsh) again" 0
  out_line "second --rc says No changes" "No changes — everything was already in place."
  assert_same_file "~/.zshrc unchanged by the second --rc" "$T/zshrc.1" "$H/.zshrc"
  run_script SHELL=/bin/bash -- --rc
  assert_rc "--rc (bash)" 0
  assert_file_line "~/.bashrc has the source line" "$H/.bashrc" "$RC_LINE"
  assert_eq "~/.bashrc has exactly one aliases line" "1" "$(count_matches "$H/.bashrc" 'claude-multi/aliases')"
  assert_same_file "~/.zshrc untouched by the bash run" "$T/zshrc.1" "$H/.zshrc"
  run_script SHELL=/bin/bash -- --rc
  assert_eq "~/.bashrc still exactly one aliases line" "1" "$(count_matches "$H/.bashrc" 'claude-multi/aliases')"
  run_script -- "--rc=$H/custom.rc"
  assert_rc "--rc=FILE" 0
  assert_file_has "rc-file remembers the custom rc" "$H/.claude-multi/rc-file" "$H/custom.rc"
  # ux-4: with the standard rc files gone, status must still find the custom one through rc-file
  mv "$H/.zshrc" "$H/zshrc.aside"; mv "$H/.bashrc" "$H/bashrc.aside"
  run_script -- status
  out_line "status finds the custom rc via rc-file" "rc: sourced from $H/custom.rc"
  mv "$H/zshrc.aside" "$H/.zshrc"; mv "$H/bashrc.aside" "$H/.bashrc"
  assert_file_line "custom rc has the source line" "$H/custom.rc" "$RC_LINE"
  assert_eq "custom rc has exactly one aliases line" "1" "$(count_matches "$H/custom.rc" 'claude-multi/aliases')"
  run_script -- "--rc=$H/custom.rc"
  assert_eq "custom rc still exactly one aliases line" "1" "$(count_matches "$H/custom.rc" 'claude-multi/aliases')"
  # without --rc the rc file is never touched
  rm -f "$H/.bashrc"
  run_script SHELL=/bin/bash -- setup
  assert_absent "setup without --rc does not recreate ~/.bashrc" "$H/.bashrc"
  out_has "summary prints the line to add instead" 'claude-multi/aliases.sh'
  # an unknown $SHELL: the line is printed, nothing appended
  cp "$H/.zshrc" "$T/zshrc.2"
  run_script SHELL=/bin/fish -- --rc
  assert_rc "--rc with SHELL=/bin/fish" 0
  out_has "unknown shell: line printed, not appended" "not appended (unknown shell"
  out_has "unknown shell: the line itself is shown" 'claude-multi/aliases.sh'
  assert_same_file "unknown shell: ~/.zshrc untouched" "$T/zshrc.2" "$H/.zshrc"
  assert_absent "unknown shell: no ~/.bashrc created" "$H/.bashrc"
}

t14_run_shell() { # label shell args… → probe dir $T/p-<label>
  local label=$1; shift
  local P="$T/p-$label"
  mkdir -p "$P"
  env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" P="$P" TERM=dumb "$@" "$(cat "$FIX/t14-driver.sh")" \
    > "$P/shell.out" 2> "$P/shell.err" < /dev/null
  printf '%s\n' "$?" > "$P/shell.rc"
}
t14_assert_shell() { # label
  local L=$1 P="$T/p-$1" shared="$H/.claude-shared" acc="$H/.claude-accounts" unpinned
  unpinned='This terminal: default — ~/.claude (whatever the default login is)'
  assert_eq "[$L] shell ran the driver to the end" "0" "$(cat "$P/shell.rc" 2>/dev/null)"
  assert_eq "[$L] sourcing aliases.sh succeeds" "0" "$(cat "$P/source.rc" 2>/dev/null)"
  assert_file_empty "[$L] sourcing prints nothing on stdout" "$P/source.out"
  assert_file_empty "[$L] sourcing prints nothing on stderr" "$P/source.err"
  assert_eq "[$L] CLAUDE_CONFIG_DIR still unset after sourcing" "<unset>" "$(cat "$P/after-source.cfg" 2>/dev/null)"
  assert_eq "[$L] ANTHROPIC_API_KEY still set after sourcing" "sk-ant-LEAK" "$(cat "$P/after-source.key" 2>/dev/null)"
  # cwho unpinned
  assert_eq "[$L] cwho exits 0" "0" "$(cat "$P/cwho-unpinned.rc" 2>/dev/null)"
  assert_first_line "[$L] cwho unpinned first line" "$P/cwho-unpinned.out" "$unpinned"
  assert_file_has "[$L] cwho notes ANTHROPIC_API_KEY" "$P/cwho-unpinned.out" "ANTHROPIC_API_KEY"
  assert_file_line "[$L] cwho list header" "$P/cwho-unpinned.out" "Accounts (slot · launcher · email · login):"
  assert_eq "[$L] cwho unpinned: no * mark" "0" "$(count_matches "$P/cwho-unpinned.out" '^  \* ')"
  assert_file_matches "[$L] cwho lists alice as logged in" "$P/cwho-unpinned.out" '^  [ *] 1 +claude-alice +alice@example\.com +logged in$'
  assert_file_matches "[$L] cwho lists hans-proton as NOT logged in" "$P/cwho-unpinned.out" '^  [ *] 4 +claude-hans-proton +hans@proton\.test +NOT logged in '
  assert_file_has "[$L] NOT logged in wording" "$P/cwho-unpinned.out" "NOT logged in → run claude-multi login hans-proton"
  # cuse: no argument, unknown
  assert_eq "[$L] cuse without argument exits 2" "2" "$(cat "$P/cuse-noarg.rc" 2>/dev/null)"
  assert_file_empty "[$L] cuse without argument: stdout empty" "$P/cuse-noarg.out"
  assert_file_has "[$L] cuse without argument: usage on stderr" "$P/cuse-noarg.err" "usage: cuse"
  assert_file_has "[$L] cuse without argument: list on stderr" "$P/cuse-noarg.err" "Accounts (slot"
  assert_eq "[$L] cuse nonexistent exits 1" "1" "$(cat "$P/cuse-missing.rc" 2>/dev/null)"
  assert_file_line "[$L] cuse nonexistent message" "$P/cuse-missing.err" "cuse: no account 'nonexistent'"
  assert_file_has "[$L] cuse nonexistent: list on stderr" "$P/cuse-missing.err" "Accounts (slot"
  assert_eq "[$L] cuse nonexistent leaves CLAUDE_CONFIG_DIR unset" "<unset>" "$(cat "$P/cuse-missing.cfg" 2>/dev/null)"
  # cuse by slug
  assert_eq "[$L] cuse hans-proton exits 0" "0" "$(cat "$P/cuse-slug.rc" 2>/dev/null)"
  assert_first_line "[$L] cuse hans-proton line" "$P/cuse-slug.out" "This terminal: hans-proton (hans@proton.test)  CLAUDE_CONFIG_DIR=$acc/hans-proton"
  assert_file_line "[$L] cuse hans-proton: not-logged-in hint" "$P/cuse-slug.out" "  not logged in yet: run  claude-multi login hans-proton"
  assert_file_has "[$L] cuse notes ANTHROPIC_API_KEY" "$P/cuse-slug.out" "ANTHROPIC_API_KEY"
  assert_eq "[$L] cuse exported CLAUDE_CONFIG_DIR" "$acc/hans-proton" "$(cat "$P/cuse-slug.cfg" 2>/dev/null)"
  assert_first_line "[$L] cwho pinned first line" "$P/cwho-pinned.out" "This terminal: hans-proton (hans@proton.test)  CLAUDE_CONFIG_DIR=$acc/hans-proton"
  assert_file_matches "[$L] cwho pinned marks slot 4" "$P/cwho-pinned.out" '^  \* 4 +claude-hans-proton +hans@proton\.test'
  assert_eq "[$L] cwho pinned: exactly one * mark" "1" "$(count_matches "$P/cwho-pinned.out" '^  \* ')"
  # cuse by slot (alice is logged in)
  assert_eq "[$L] cuse 1 exits 0" "0" "$(cat "$P/cuse-slot.rc" 2>/dev/null)"
  assert_first_line "[$L] cuse 1 line" "$P/cuse-slot.out" "This terminal: alice (alice@example.com)  CLAUDE_CONFIG_DIR=$acc/alice"
  assert_file_lacks "[$L] cuse 1: no not-logged-in hint for a logged-in account" "$P/cuse-slot.out" "not logged in"
  assert_eq "[$L] cuse 1 exported CLAUDE_CONFIG_DIR" "$acc/alice" "$(cat "$P/cuse-slot.cfg" 2>/dev/null)"
  # launcher by function
  assert_eq "[$L] claude-hans-betterdoc exits 0" "0" "$(cat "$P/launcher-fn.rc" 2>/dev/null)"
  assert_first_line "[$L] launcher: config dir, KEY=<unset>, flag order, args" "$P/launcher-fn.out" \
    "stub claude CLAUDE_CONFIG_DIR=$acc/hans-betterdoc KEY=<unset> ARGS=--mcp-config $shared/mcp.json --settings $shared/settings.json --print hello"
  assert_eq "[$L] shell CLAUDE_CONFIG_DIR unchanged by the launcher" "$acc/alice" "$(cat "$P/launcher-fn.cfg" 2>/dev/null)"
  assert_eq "[$L] shell ANTHROPIC_API_KEY unchanged by the launcher" "sk-ant-LEAK" "$(cat "$P/launcher-fn.key" 2>/dev/null)"
  assert_file_line "[$L] launcher: AUTH_TOKEN and OAUTH_TOKEN unset too" "$P/launcher-fn.out" "stub env AUTH_TOKEN=<unset> OAUTH=<unset>"
  # launcher by slot alias (eval'd)
  assert_eq "[$L] claude3 alias exits 0" "0" "$(cat "$P/launcher-alias.rc" 2>/dev/null)"
  assert_first_line "[$L] claude3 alias runs the info account" "$P/launcher-alias.out" \
    "stub claude CLAUDE_CONFIG_DIR=$acc/info KEY=<unset> ARGS=--mcp-config $shared/mcp.json --settings $shared/settings.json mcp list"
  # error paths
  assert_eq "[$L] launcher without claude in PATH exits 127" "127" "$(cat "$P/launcher-nobin.rc" 2>/dev/null)"
  assert_eq "[$L] launcher with a missing account dir exits 1" "1" "$(cat "$P/launcher-nodir.rc" 2>/dev/null)"
  assert_file_has "[$L] missing-dir error names the setup script" "$P/launcher-nodir.out" "claude-multi-setup.sh"
  # lookups
  assert_first_line "[$L] _claude_multi_find by slot" "$P/find-slot.out" "4 hans-proton hans@proton.test"
  assert_first_line "[$L] _claude_multi_find by slug" "$P/find-slug.out" "1 alice alice@example.com"
  assert_file_empty "[$L] _claude_multi_find unknown prints nothing" "$P/find-none.out"
  assert_eq "[$L] _claude_multi_accounts prints 4 lines in slot order" "1 alice alice@example.com|2 hans-betterdoc hans@betterdoc.test|3 info info@corp.test|4 hans-proton hans@proton.test|" \
    "$(tr '\n' '|' < "$P/accounts.out" 2>/dev/null)"
  # cuse default
  assert_eq "[$L] cuse default exits 0" "0" "$(cat "$P/cuse-default.rc" 2>/dev/null)"
  assert_first_line "[$L] cuse default line" "$P/cuse-default.out" "This terminal: default (~/.claude)"
  assert_eq "[$L] cuse default unsets CLAUDE_CONFIG_DIR" "<unset>" "$(cat "$P/cuse-default.cfg" 2>/dev/null)"
  assert_first_line "[$L] cwho after cuse default" "$P/cwho-after-default.out" "$unpinned"
  assert_eq "[$L] ANTHROPIC_API_KEY still set at the end" "sk-ant-LEAK" "$(cat "$P/final.key" 2>/dev/null)"
  assert_eq "[$L] cwho/cuse/_claude_multi_find leave no globals (state mark slot slug email)" "mine|mine|mine|mine|mine" "$(cat "$P/globals.out" 2>/dev/null)"
}
case_T14() { # aliases.sh sourced in zsh and in bash
  set_cswap json
  run_script -- setup
  assert_rc "setup" 0
  if [ ! -f "$H/.claude-multi/aliases.sh" ]; then
    fail "aliases.sh missing; the shell probes cannot run"
    return 0
  fi
  printf '{"oauthAccount":{"emailAddress":"alice@example.com"}}\n' 2>/dev/null > "$H/.claude-accounts/alice/.claude.json"
  if [ -n "$ZSH_BIN" ]; then
    t14_run_shell zsh "$ZSH_BIN" -f -c
    t14_assert_shell zsh
  else
    fail "zsh not installed; zsh probes skipped"
  fi
  if [ -x /bin/bash ]; then
    t14_run_shell bash /bin/bash --norc --noprofile -c
    t14_assert_shell bash
  else
    fail "/bin/bash not found; bash probes skipped"
  fi
  if [ "$RUN_BASH" != /bin/bash ] && [ -x "$RUN_BASH" ]; then
    t14_run_shell bash2 "$RUN_BASH" --norc --noprofile -c
    t14_assert_shell bash2
  fi
}

case_T15() { # remove b@y.test
  set_cswap absent
  run_script -- add a@x.test
  run_script -- add b@y.test --slot 5
  assert_rc "add b@y.test --slot 5" 0
  assert_dir "dir b exists before remove" "$H/.claude-accounts/b"
  run_script -- remove b@y.test
  assert_rc "remove b@y.test" 0
  assert_file_lacks "registry row for b@y.test gone" "$H/.claude-multi/accounts.tsv" "b@y.test"
  assert_registry_row 1 a@x.test a
  assert_file_lacks "launcher claude-b gone" "$H/.claude-multi/aliases.sh" "claude-b"
  assert_file_lacks "alias claude5 gone" "$H/.claude-multi/aliases.sh" "claude5"
  assert_file_matches "launcher claude-a still there" "$H/.claude-multi/aliases.sh" '^claude-a\(\)'
  assert_dir "dir b still exists" "$H/.claude-accounts/b"
  out_has "message names the kept dir" "$H/.claude-accounts/b"
  cp "$H/.claude-multi/accounts.tsv" "$T/registry.after" 2>/dev/null
  run_script -- remove b@y.test
  assert_true "remove of an unregistered email exits cleanly (0 or 1; contract is silent)" test "$RC" = 0 -o "$RC" = 1
  assert_same_file "remove of an unregistered email leaves the registry alone" "$T/registry.after" "$H/.claude-multi/accounts.tsv"
  run_script -- status
  assert_rc "status without cswap" 0
  out_line "cswap not found" "cswap: not found (manual account list)"
  # remove an email that cswap still lists: the row goes, the summary says it will come back
  set_cswap json
  run_script -- setup
  assert_rc "setup with cswap" 0
  assert_registry_row 4 hans@proton.test hans-proton
  run_script -- remove hans@proton.test
  assert_rc "remove hans@proton.test" 0
  assert_file_lacks "registry row for hans@proton.test gone" "$H/.claude-multi/accounts.tsv" "hans@proton.test"
  out_has "remove notes cswap still lists it" "cswap still lists hans@proton.test"
  assert_dir "dir hans-proton still exists" "$H/.claude-accounts/hans-proton"
}

case_T16() { # status before setup, after setup, after a fake login, pinned, unmanaged
  local order_fresh order_setup next1 next2
  set_cswap json
  run_script -- status
  assert_rc "status on a fresh HOME" 0
  assert_file_empty "status prints nothing on stderr" "$T/err"
  order_fresh=$(sed -n 's/^\([a-z]*\):.*/\1/p' "$T/out" | tr '\n' ' ')
  assert_eq "status key order (fresh HOME)" "script version cswap shared aliases rc terminal next " "$order_fresh"
  out_line "cswap found" "cswap: found at $H/bin/cswap"
  out_line "shared missing" "shared: missing"
  out_line "aliases missing" "aliases: missing"
  out_line "rc not sourced" "rc: not sourced (run --rc)"
  out_line "terminal default" "terminal: default"
  out_matches "next says setup" '^next: .*setup'
  assert_absent "status created nothing (~/.claude-multi)" "$H/.claude-multi"
  assert_absent "status created nothing (~/.claude-accounts)" "$H/.claude-accounts"
  assert_absent "status created nothing (~/.claude-shared)" "$H/.claude-shared"
  run_script -- setup
  assert_rc "setup" 0
  run_script -- status
  assert_rc "status after setup" 0
  order_setup=$(sed -n 's/^\([a-z]*\):.*/\1/p' "$T/out" | tr '\n' ' ')
  assert_eq "status key order (4 accounts)" "script version cswap shared aliases rc terminal account account account account next " "$order_setup"
  assert_true "script: names an existing file" test -f "$(sed -n 's/^script: //p' "$T/out")"
  out_matches "version: has a value" '^version: [^ ]'
  out_line "shared ok" "shared: ok $H/.claude-shared"
  out_line "aliases ok" "aliases: ok $H/.claude-multi/aliases.sh"
  out_line "rc not sourced" "rc: not sourced (run --rc)"
  out_line "terminal default" "terminal: default"
  out_line "account 1" "account: 1 alice alice@example.com not-logged-in"
  out_line "account 2" "account: 2 hans-betterdoc hans@betterdoc.test not-logged-in"
  out_line "account 3" "account: 3 info info@corp.test not-logged-in"
  out_line "account 4" "account: 4 hans-proton hans@proton.test not-logged-in"
  out_has "next: first not-logged-in account" "next: run claude-multi login alice"
  next1=$(sed -n 's/^next: //p' "$T/out")
  printf '{"oauthAccount":{}}\n' 2>/dev/null > "$H/.claude-accounts/alice/.claude.json"
  stamp
  run_script -- status
  assert_rc "status after fake login" 0
  out_line "account 1 now logged-in" "account: 1 alice alice@example.com logged-in"
  next2=$(sed -n 's/^next: //p' "$T/out")
  assert_ne "next: changed after the login" "$next1" "$next2"
  out_has "next: now names hans-betterdoc" "claude-multi login hans-betterdoc"
  run_script "CLAUDE_CONFIG_DIR=$H/.claude-accounts/info" -- status
  out_line "terminal pinned" "terminal: info (info@corp.test)"
  run_script "CLAUDE_CONFIG_DIR=/tmp/elsewhere" -- status
  out_line "terminal unmanaged" "terminal: unmanaged /tmp/elsewhere"
  assert_eq "status wrote nothing" "" "$(newer_than "$T/stamp")"
  run_script -- --version
  assert_rc "--version" 0
  assert_false "--version prints something" test ! -s "$T/out"
}

case_T17() { # v1 registry + v1 aliases.zsh
  set_cswap json
  mkdir -p "$H/.claude-multi"
  printf '# claude-multi: email<TAB>slug. A slug never changes once assigned.\nalice@example.com\tally\nhans@betterdoc.test\thansb\n' > "$H/.claude-multi/accounts.tsv"
  printf '# ~/.claude-multi/aliases.zsh — GENERATED by ~/.claude-multi/claude-multi-setup.sh. Do not edit.\nalias claude1=nothing\n' > "$H/.claude-multi/aliases.zsh"
  printf '# seeded zshrc\n\n%s\n' "$V1_RC_LINE" > "$H/.zshrc"
  cp "$H/.zshrc" "$T/zshrc.v1"
  run_script SHELL=/bin/zsh -- --rc
  assert_rc "setup --rc over a v1 install" 0
  assert_account_dir ally
  assert_account_dir hansb
  assert_account_dir info
  assert_account_dir hans          # `hans` is free: the v1 registry maps hans@betterdoc.test to `hansb`
  assert_absent "no dir 'alice' (v1 slug kept)" "$H/.claude-accounts/alice"
  assert_absent "no dir 'hans-betterdoc' (v1 slug kept)" "$H/.claude-accounts/hans-betterdoc"
  assert_registry_row 1 alice@example.com ally
  assert_registry_row 2 hans@betterdoc.test hansb
  assert_registry_row 3 info@corp.test info
  assert_registry_row 4 hans@proton.test hans
  assert_first_line "accounts.tsv rewritten as v2" "$H/.claude-multi/accounts.tsv" \
    '# claude-multi accounts: slot<TAB>email<TAB>slug. Edit with `claude-multi-setup.sh add|remove`.'
  assert_exists "aliases.sh written" "$H/.claude-multi/aliases.sh"
  assert_file_has "aliases.zsh is a shim sourcing aliases.sh" "$H/.claude-multi/aliases.zsh" "aliases.sh"
  assert_file_lacks "aliases.zsh shim no longer carries the v1 body" "$H/.claude-multi/aliases.zsh" "alias claude1=nothing"
  assert_eq "aliases.zsh shim is one line" "1" "$(grep -c . "$H/.claude-multi/aliases.zsh")"
  if [ -n "$ZSH_BIN" ]; then
    assert_true "zsh -n aliases.zsh shim" "$ZSH_BIN" -n "$H/.claude-multi/aliases.zsh"
    assert_true "sourcing the shim in zsh defines cwho" env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" "$ZSH_BIN" -f -c '. "$HOME/.claude-multi/aliases.zsh" && cwho'
  fi
  assert_same_file "~/.zshrc untouched: the v1 line satisfies the presence check" "$T/zshrc.v1" "$H/.zshrc"
  assert_eq "~/.zshrc has exactly one aliases line" "1" "$(count_matches "$H/.zshrc" 'claude-multi/aliases')"
  run_script -- status
  out_line "status: rc sourced via the v1 line" "rc: sourced from $H/.zshrc"
  out_line "status: account 1 keeps slug ally" "account: 1 ally alice@example.com not-logged-in"
}

case_T18() { # self-install from a path outside ~/.claude-multi
  local inst="$H/.claude-multi/claude-multi-setup.sh"
  set_cswap json
  run_script -- setup
  assert_rc "setup from $SCRIPT" 0
  assert_exists "self-installed copy exists" "$inst"
  assert_same_file "installed copy identical to the script" "$SCRIPT" "$inst"
  assert_mode "installed copy is mode 755" "$inst" "-rwxr-xr-x"
  out_has "change line reports the install" "install script to $inst"
  stamp
  run_script -- setup
  out_line "re-run from the repo path: No changes" "No changes — everything was already in place."
  assert_eq "installed copy not rewritten" "" "$(find "$inst" -newer "$T/stamp" 2>/dev/null)"
  # the installed copy runs, and does not try to install over itself
  env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" TMPDIR="$T/tmp" SHELL=/bin/zsh "$RUN_BASH" "$inst" setup > "$T/out" 2> "$T/err" < /dev/null
  RC=$?
  assert_rc "running the installed copy" 0
  out_lacks "installed copy prints no install line" "install script to"
  out_line "installed copy: No changes" "No changes — everything was already in place."
  # fed on stdin ($0 = bash): must warn, never copy the bash binary over the installed script
  stamp
  env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" TMPDIR="$T/tmp" SHELL=/bin/zsh "$RUN_BASH" -s -- setup --no-input < "$SCRIPT" > "$T/out" 2> "$T/err"
  RC=$?
  assert_rc "stdin-fed run" 0
  out_lacks "stdin-fed run prints no install line" "install script to"
  err_has "stdin-fed run warns instead of installing" "not installed to $inst"
  assert_same_file "stdin-fed run left the installed copy identical to the script" "$SCRIPT" "$inst"
  assert_eq "stdin-fed run rewrote nothing" "" "$(newer_than "$T/stamp")"
  run_script -- --help
  assert_rc "--help" 0
}

# ---------- v1.1 (§12) helpers ----------
STUB_LOG=""   # $H/stub-claude.log — one `auth-login …` / `auth-status …` line per stub call
login_lines()  { grep -c '^auth-login ' "$STUB_LOG" 2>/dev/null || true; }
status_lines() { grep -c '^auth-status ' "$STUB_LOG" 2>/dev/null || true; }
login_line_n() { grep '^auth-login ' "$STUB_LOG" 2>/dev/null | sed -n "${1}p"; }
expected_login_line() { # slug email → the exact stub line a correct `login` produces
  printf 'auth-login CLAUDE_CONFIG_DIR=%s KEY=<unset> TOKEN1=<unset> TOKEN2=<unset> ARGS=auth login --email %s\n' "$H/.claude-accounts/$1" "$2"
}
mark_logged_in() { # slug email → heuristic (.claude.json) AND verified (stub marker) both say logged in
  printf '{"oauthAccount":{"emailAddress":"%s"}}\n' "$2" > "$H/.claude-accounts/$1/.claude.json"
  printf '%s\n' "$2" > "$H/.claude-accounts/$1/.stub-logged-in"
}
write_answers() { # line… → $T/answers (one line each; the CLAUDE_MULTI_INPUT file)
  : > "$T/answers"
  while [ $# -gt 0 ]; do printf '%s\n' "$1" >> "$T/answers"; shift; done
}
outerr_has()   { if grep -qF -- "$2" "$T/out" "$T/err" 2>/dev/null; then ok "$1"; else fail "$1 (no '$2' on stdout or stderr)"; fi; }
outerr_lacks() { if grep -qF -- "$2" "$T/out" "$T/err" 2>/dev/null; then fail "$1 (found '$2' on stdout/stderr)"; else ok "$1"; fi; }
hide_claude()    { mv "$H/bin/claude" "$H/bin/claude.hidden"; }
restore_claude() { mv "$H/bin/claude.hidden" "$H/bin/claude"; }

t19_run_shell() { # label shell args… → probe dir $T/q-<label>
  local label=$1; shift
  local P="$T/q-$label"
  mkdir -p "$P"
  env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" P="$P" TERM=dumb TMPDIR="$T/tmp" "$@" "$(cat "$FIX/t19-driver.sh")" \
    > "$P/shell.out" 2> "$P/shell.err" < /dev/null
  printf '%s\n' "$?" > "$P/shell.rc"
}
t19_assert_shell() { # label
  local L=$1 P="$T/q-$1" acc="$H/.claude-accounts"
  assert_eq "[$L] shell ran the driver to the end" "0" "$(cat "$P/shell.rc" 2>/dev/null)"
  assert_eq "[$L] sourcing aliases.sh succeeds" "0" "$(cat "$P/source.rc" 2>/dev/null)"
  assert_eq "[$L] sourcing sets no CLAUDE_CONFIG_DIR" "<unset>" "$(cat "$P/after-source.cfg" 2>/dev/null)"
  assert_eq "[$L] sourcing sets no CLAUDE_MULTI_ACCOUNT" "<unset>" "$(cat "$P/after-source.acct" 2>/dev/null)"
  assert_file_has "[$L] claude-multi is a shell function" "$P/type.out" "function"
  # who ≡ cwho
  assert_eq "[$L] claude-multi who exits 0" "0" "$(cat "$P/who.rc" 2>/dev/null)"
  assert_same_file "[$L] claude-multi who ≡ cwho (unpinned)" "$P/cwho.out" "$P/who.out"
  assert_file_line "[$L] claude-multi who lists the accounts" "$P/who.out" "Accounts (slot · launcher · email · login):"
  # use <slug> exports both variables
  assert_eq "[$L] claude-multi use info exits 0" "0" "$(cat "$P/use.rc" 2>/dev/null)"
  assert_first_line "[$L] claude-multi use info line (≡ cuse)" "$P/use.out" "This terminal: info (info@corp.test)  CLAUDE_CONFIG_DIR=$acc/info"
  assert_eq "[$L] use info: CLAUDE_CONFIG_DIR set" "$acc/info" "$(cat "$P/use.cfg" 2>/dev/null)"
  assert_eq "[$L] use info: CLAUDE_MULTI_ACCOUNT=info" "info" "$(cat "$P/use.acct" 2>/dev/null)"
  assert_eq "[$L] use info: both variables EXPORTED (seen by a child sh)" "$acc/info|info" "$(cat "$P/use.exported" 2>/dev/null)"
  assert_same_file "[$L] claude-multi who ≡ cwho (pinned)" "$P/cwho-pinned.out" "$P/who-pinned.out"
  assert_first_line "[$L] who pinned first line" "$P/who-pinned.out" "This terminal: info (info@corp.test)  CLAUDE_CONFIG_DIR=$acc/info"
  # status passthrough ≡ the script's own status (same pinned terminal, same install path)
  assert_eq "[$L] claude-multi status exits 0" "0" "$(cat "$P/status.rc" 2>/dev/null)"
  assert_same_file "[$L] claude-multi status ≡ script status" "$P/status-direct.out" "$P/status.out"
  assert_file_line "[$L] status via umbrella sees the pinned terminal" "$P/status.out" "terminal: info (info@corp.test)"
  # use default unsets both
  assert_eq "[$L] claude-multi use default exits 0" "0" "$(cat "$P/default.rc" 2>/dev/null)"
  assert_first_line "[$L] use default line" "$P/default.out" "This terminal: default (~/.claude)"
  assert_eq "[$L] use default: CLAUDE_CONFIG_DIR unset" "<unset>" "$(cat "$P/default.cfg" 2>/dev/null)"
  assert_eq "[$L] use default: CLAUDE_MULTI_ACCOUNT unset" "<unset>" "$(cat "$P/default.acct" 2>/dev/null)"
  assert_eq "[$L] use default: neither variable reaches a child sh" "<unset>|<unset>" "$(cat "$P/default.exported" 2>/dev/null)"
  # cuse itself carries CLAUDE_MULTI_ACCOUNT (§12.1)
  assert_eq "[$L] cuse hans-proton exits 0" "0" "$(cat "$P/cuse.rc" 2>/dev/null)"
  assert_eq "[$L] cuse hans-proton exports CLAUDE_MULTI_ACCOUNT" "$acc/hans-proton|hans-proton" "$(cat "$P/cuse.exported" 2>/dev/null)"
  assert_eq "[$L] cuse default unsets CLAUDE_MULTI_ACCOUNT" "<unset>" "$(cat "$P/cuse-default.acct" 2>/dev/null)"
  assert_eq "[$L] cuse default unsets CLAUDE_CONFIG_DIR" "<unset>" "$(cat "$P/cuse-default.cfg" 2>/dev/null)"
  assert_eq "[$L] claude-multi use nonexistent exits 1" "1" "$(cat "$P/use-missing.rc" 2>/dev/null)"
  assert_file_line "[$L] use nonexistent: cuse's message" "$P/use-missing.err" "cuse: no account 'nonexistent'"
  assert_eq "[$L] use nonexistent leaves CLAUDE_MULTI_ACCOUNT unset" "<unset>" "$(cat "$P/use-missing.acct" 2>/dev/null)"
  # help
  assert_eq "[$L] claude-multi help exits 0" "0" "$(cat "$P/help.rc" 2>/dev/null)"
  assert_file_empty "[$L] help prints nothing on stderr" "$P/help.err"
  assert_file_matches "[$L] help: verb table has use" "$P/help.out" '(^|[^a-z-])use([^a-z-]|$)'
  assert_file_matches "[$L] help: verb table has who" "$P/help.out" '(^|[^a-z-])who([^a-z-]|$)'
  assert_file_matches "[$L] help: verb table has login" "$P/help.out" '(^|[^a-z-])login([^a-z-]|$)'
  assert_file_matches "[$L] help: verb table has update" "$P/help.out" '(^|[^a-z-])update([^a-z-]|$)'
  assert_file_matches "[$L] help: verb table has status" "$P/help.out" '(^|[^a-z-])status([^a-z-]|$)'
  assert_file_matches "[$L] help: verb table has relink" "$P/help.out" '(^|[^a-z-])relink([^a-z-]|$)'
  assert_eq "[$L] claude-multi without argument exits 0" "0" "$(cat "$P/noarg.rc" 2>/dev/null)"
  assert_same_file "[$L] no argument prints the same table as help" "$P/help.out" "$P/noarg.out"
  assert_eq "[$L] claude-multi --help exits 0" "0" "$(cat "$P/dashhelp.rc" 2>/dev/null)"
  assert_same_file "[$L] --help prints the same table as help" "$P/help.out" "$P/dashhelp.out"
  # relink → setup --relink; --dry-run passes through
  assert_eq "[$L] claude-multi relink exits 0" "0" "$(cat "$P/relink.rc" 2>/dev/null)"
  assert_file_matches "[$L] relink reached the script (No changes / Done)" "$P/relink.out" '^(No changes|Done)'
  assert_file_lacks "[$L] relink ran no full setup (no summary)" "$P/relink.out" "Accounts (source:"
  assert_link_to "[$L] relink restored info/skills" "$acc/info/skills" "$H/.claude-shared/skills"
  assert_eq "[$L] claude-multi --dry-run exits 0" "0" "$(cat "$P/dryrun.rc" 2>/dev/null)"
  assert_file_has "[$L] --dry-run passed through verbatim" "$P/dryrun.out" "dry-run"
  assert_eq "[$L] claude-multi --version exits 0" "0" "$(cat "$P/version.rc" 2>/dev/null)"
  assert_eq "[$L] --version via the umbrella prints the script's version" "$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT" | head -n 1)" "$(cat "$P/version.out" 2>/dev/null)"
  assert_eq "[$L] CLAUDE_CONFIG_DIR unset at the end" "<unset>" "$(cat "$P/final.cfg" 2>/dev/null)"
  assert_eq "[$L] CLAUDE_MULTI_ACCOUNT unset at the end" "<unset>" "$(cat "$P/final.acct" 2>/dev/null)"
}
case_T19() { # `claude-multi` umbrella + CLAUDE_MULTI_ACCOUNT in zsh and bash
  set_cswap json
  run_script -- setup
  assert_rc "setup" 0
  if [ ! -f "$H/.claude-multi/aliases.sh" ]; then
    fail "aliases.sh missing; the shell probes cannot run"
    return 0
  fi
  assert_file_matches "aliases.sh defines claude-multi()" "$H/.claude-multi/aliases.sh" '^claude-multi\(\)'
  printf '{"oauthAccount":{"emailAddress":"alice@example.com"}}\n' > "$H/.claude-accounts/alice/.claude.json"
  if [ -n "$ZSH_BIN" ]; then
    t19_run_shell zsh "$ZSH_BIN" -f -c
    t19_assert_shell zsh
  else
    fail "zsh not installed; zsh probes skipped"
  fi
  if [ -x /bin/bash ]; then
    t19_run_shell bash /bin/bash --norc --noprofile -c
    t19_assert_shell bash
  else
    fail "/bin/bash not found; bash probes skipped"
  fi
  if [ "$RUN_BASH" != /bin/bash ] && [ -x "$RUN_BASH" ]; then
    t19_run_shell bash2 "$RUN_BASH" --norc --noprofile -c
    t19_assert_shell bash2
  fi
}

case_T20() { # `login` against the stub claude
  local acc="$H/.claude-accounts"
  STUB_LOG="$H/stub-claude.log"
  set_cswap json
  run_script -- setup
  assert_rc "setup" 0
  write_answers   # an empty CLAUDE_MULTI_INPUT file: satisfies the terminal check (§12.4) without a tty
  # login <slug>: the three credential variables are set in the caller and must not reach the stub
  run_script "CLAUDE_MULTI_INPUT=$T/answers" ANTHROPIC_API_KEY=sk-ant-LEAK ANTHROPIC_AUTH_TOKEN=tok-LEAK CLAUDE_CODE_OAUTH_TOKEN=oauth-LEAK -- login info
  assert_rc "login info" 0
  assert_eq "login info: exactly one auth login call" "1" "$(login_lines)"
  assert_eq "login info: auth login --email under the info dir, credentials unset" "$(expected_login_line info info@corp.test)" "$(login_line_n 1)"
  assert_exists "login info: the stub recorded the login in the info dir" "$acc/info/.stub-logged-in"
  assert_true "login info: auth status consulted afterwards" test "$(status_lines)" -ge 1
  out_has "login info reports 'logged in as info@corp.test'" "logged in as info@corp.test"
  assert_file_lacks "no token printed on stdout" "$T/out" LEAK
  assert_file_lacks "no token printed on stderr" "$T/err" LEAK
  assert_file_lacks "matching email: no 'logged in as … expected' warning" "$T/err" "warning: logged in as"
  # login <slot> and login <email> resolve too
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login 4
  assert_rc "login 4" 0
  assert_eq "login 4 resolved to hans-proton" "$(expected_login_line hans-proton hans@proton.test)" "$(login_line_n 2)"
  out_has "login 4 reports 'logged in as hans@proton.test'" "logged in as hans@proton.test"
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login hans@proton.test
  assert_rc "login hans@proton.test" 0
  assert_eq "login <email> resolved to hans-proton" "$(expected_login_line hans-proton hans@proton.test)" "$(login_line_n 3)"
  assert_eq "three logins so far" "3" "$(login_lines)"
  # unknown account
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login nonexistent
  assert_rc "login nonexistent" 1
  err_has "login nonexistent: error line" "error: no account 'nonexistent'"
  outerr_has "login nonexistent: the account list follows" "alice"
  assert_eq "login nonexistent: no auth login call" "3" "$(login_lines)"
  # no terminal
  run_script -- login info --no-input
  assert_rc "login --no-input" 2
  err_has "login --no-input: the message" "login opens a browser and needs a terminal"
  err_has "login --no-input: names claude-multi login" "claude-multi login"
  assert_eq "login --no-input: no auth login call" "3" "$(login_lines)"
  # claude not in PATH
  hide_claude
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login info
  assert_rc "login without claude in PATH" 1
  err_matches "login without claude: 'error: ' names claude" '^error: .*claude'
  restore_claude
  # --all: only the not-logged-in accounts, in slot order
  rm -f "$STUB_LOG" "$acc"/*/.stub-logged-in
  mark_logged_in alice alice@example.com
  mark_logged_in info info@corp.test
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login --all
  assert_rc "login --all" 0
  assert_eq "login --all: exactly two logins" "2" "$(login_lines)"
  assert_eq "login --all: first hans-betterdoc (slot 2)" "$(expected_login_line hans-betterdoc hans@betterdoc.test)" "$(login_line_n 1)"
  assert_eq "login --all: then hans-proton (slot 4)" "$(expected_login_line hans-proton hans@proton.test)" "$(login_line_n 2)"
  assert_file_lacks "login --all skipped alice (logged in)" "$STUB_LOG" "alice@example.com"
  assert_file_lacks "login --all skipped info (logged in)" "$STUB_LOG" "info@corp.test"
  out_has "login --all reports hans@betterdoc.test" "logged in as hans@betterdoc.test"
  out_has "login --all reports hans@proton.test" "logged in as hans@proton.test"
  # --all takes the VERIFIED state: alice keeps her oauthAccount (heuristic: logged in) but loses the stub marker
  # (verified: not) → attempted; hans-betterdoc has the marker only (heuristic: not, verified: logged in) → skipped
  rm -f "$STUB_LOG" "$acc/alice/.stub-logged-in"
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login --all
  assert_rc "login --all (stale oauthAccount)" 0
  assert_eq "login --all: exactly one login (alice)" "1" "$(login_lines)"
  assert_eq "login --all: alice attempted despite her oauthAccount" "$(expected_login_line alice alice@example.com)" "$(login_line_n 1)"
  out_line "login --all: hans-betterdoc skipped on its verified state" "account: 2 hans-betterdoc hans@betterdoc.test logged-in (verified)"
  assert_file_lacks "login --all: hans-betterdoc not attempted" "$STUB_LOG" "auth login --email hans@betterdoc.test"
  # a failing login
  rm -f "$STUB_LOG" "$acc"/*/.stub-logged-in
  : > "$H/stub-login-fails"
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login info
  assert_rc "login info with a failing stub" 1
  outerr_has "failing login: 'login did not complete for info@corp.test'" "login did not complete for info@corp.test"
  assert_absent "failing login: no marker left" "$acc/info/.stub-logged-in"
  # --all stops at the first failure
  rm -f "$STUB_LOG"
  run_script "CLAUDE_MULTI_INPUT=$T/answers" -- login --all
  assert_rc "login --all with a failing stub" 1
  assert_eq "login --all stopped at the first failure (one attempt)" "1" "$(login_lines)"
  assert_eq "login --all: the attempt was alice (slot 1; her stale oauthAccount does not skip her)" "$(expected_login_line alice alice@example.com)" "$(login_line_n 1)"
  outerr_has "login --all: 'login did not complete for alice@example.com'" "login did not complete for alice@example.com"
  outerr_lacks "login --all: hans-betterdoc never reached" "Logging in to hans@betterdoc.test"
  rm -f "$H/stub-login-fails"
  # the CLI reports a different email than the one asked for: logged in, with the §12.2 warning
  rm -f "$STUB_LOG"
  run_script "CLAUDE_MULTI_INPUT=$T/answers" STUB_LOGIN_AS=other@x.test -- login info
  assert_rc "login info (stub logs in as another email)" 0
  out_has "mismatch: still 'logged in as info@corp.test'" "logged in as info@corp.test"
  err_has "mismatch: the warning names both emails" "warning: logged in as other@x.test, expected info@corp.test"
  assert_seed_untouched
}

case_T21() { # status --verify
  local acc="$H/.claude-accounts" order slug
  STUB_LOG="$H/stub-claude.log"
  set_cswap json
  run_script -- setup
  assert_rc "setup" 0
  # alice: heuristic says logged in (oauthAccount), the stub says not; info: the stub says logged in, no .claude.json
  printf '{"oauthAccount":{"emailAddress":"alice@example.com"}}\n' > "$acc/alice/.claude.json"
  printf 'info@corp.test\n' > "$acc/info/.stub-logged-in"
  stamp
  run_script -- status --verify
  assert_rc "status --verify" 0
  order=$(sed -n 's/^\([a-z]*\):.*/\1/p' "$T/out" | tr '\n' ' ')
  assert_eq "status --verify key order" "script version cswap shared aliases rc terminal account account account account next " "$order"
  out_line "verified: alice NOT logged in (heuristic overruled)" "account: 1 alice alice@example.com not-logged-in (verified)"
  out_line "verified: hans-betterdoc not logged in" "account: 2 hans-betterdoc hans@betterdoc.test not-logged-in (verified)"
  out_line "verified: info logged in (marker only)" "account: 3 info info@corp.test logged-in (verified)"
  out_line "verified: hans-proton not logged in" "account: 4 hans-proton hans@proton.test not-logged-in (verified)"
  out_has "next: names the first verified-missing account (alice)" "claude-multi login alice"
  assert_eq "auth status ran once per account" "4" "$(status_lines)"
  assert_file_has "auth status ran under the alice dir" "$STUB_LOG" "auth-status CLAUDE_CONFIG_DIR=$acc/alice"
  assert_file_has "auth status ran under the hans-proton dir" "$STUB_LOG" "auth-status CLAUDE_CONFIG_DIR=$acc/hans-proton"
  assert_eq "status --verify never calls auth login" "0" "$(login_lines)"
  assert_eq "status --verify wrote nothing (but the stub's own log)" "" "$(newer_than "$T/stamp" | grep -v -x -e "$H" -e "$STUB_LOG")"
  assert_file_empty "status --verify: nothing on stderr" "$T/err"
  # plain status keeps the heuristic
  run_script -- status
  assert_rc "status (plain)" 0
  out_line "plain status: alice logged-in (heuristic)" "account: 1 alice alice@example.com logged-in"
  out_line "plain status: info not-logged-in (heuristic)" "account: 3 info info@corp.test not-logged-in"
  out_lacks "plain status: no '(verified)'" "(verified)"
  assert_eq "plain status never runs auth status" "4" "$(status_lines)"
  # --verify without claude in PATH: heuristic states + warning
  hide_claude
  run_script -- status --verify
  assert_rc "status --verify without claude" 0
  out_line "no claude: alice heuristic logged-in" "account: 1 alice alice@example.com logged-in"
  out_line "no claude: info heuristic not-logged-in" "account: 3 info info@corp.test not-logged-in"
  out_lacks "no claude: no '(verified)'" "(verified)"
  err_has "no claude: the warning" "warning: claude not in PATH"
  err_has "no claude: warning names the heuristic" ".claude.json heuristic"
  restore_claude
  # a registered account whose dir is gone: `claude auth status` would create it (mode 755) just to say "no login"
  rm -f "$STUB_LOG"
  rm -rf "$acc/hans-proton"
  run_script -- status --verify
  assert_rc "status --verify with a missing account dir" 0
  out_line "missing dir: hans-proton not-logged-in (verified)" "account: 4 hans-proton hans@proton.test not-logged-in (verified)"
  assert_absent "missing dir: status --verify did not create it" "$acc/hans-proton"
  assert_eq "missing dir: auth status ran for the three existing dirs only" "3" "$(status_lines)"
  assert_file_lacks "missing dir: auth status never ran under hans-proton" "$STUB_LOG" "CLAUDE_CONFIG_DIR=$acc/hans-proton"
  # the next: hint reads the STATE field: an account whose slug/email is 'not-logged-in' is not "the first missing one"
  run_script -- add not-logged-in@x.test
  assert_rc "add not-logged-in@x.test" 0
  assert_dir "add: dir not-logged-in exists" "$acc/not-logged-in"
  for slug in alice hans-betterdoc info hans-proton not-logged-in; do
    mkdir -p "$acc/$slug" && printf '{"oauthAccount":{"emailAddress":"x"}}\n' > "$acc/$slug/.claude.json"
  done
  run_script -- status
  assert_rc "status with every account logged in (heuristic)" 0
  out_line "slug not-logged-in: its line ends in logged-in" "account: 5 not-logged-in not-logged-in@x.test logged-in"
  out_line "slug not-logged-in: next says all accounts logged in" "next: all accounts logged in"
  assert_seed_untouched
}

case_T22() { # interactive offers (rc line, logins) driven by CLAUDE_MULTI_INPUT
  local acc="$H/.claude-accounts"
  STUB_LOG="$H/stub-claude.log"
  set_cswap json
  # --dry-run asks nothing and writes nothing, even with every answer a yes
  write_answers y y y y y
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- --dry-run
  assert_rc "--dry-run" 0
  outerr_lacks "--dry-run: no rc offer" "Append the source line"
  outerr_lacks "--dry-run: no login offer" "now? [Y/n]"
  assert_same_file "--dry-run: ~/.zshrc untouched" "$T/zshrc.seed" "$H/.zshrc"
  assert_absent "--dry-run: nothing created" "$H/.claude-multi"
  assert_absent "--dry-run: no login ran" "$STUB_LOG"
  # --no-input asks nothing (setup still runs)
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- setup --no-input
  assert_rc "setup --no-input" 0
  assert_dir "--no-input: setup ran (dir alice)" "$acc/alice"
  outerr_lacks "--no-input: no rc offer" "Append the source line"
  outerr_lacks "--no-input: no login offer" "now? [Y/n]"
  assert_same_file "--no-input: ~/.zshrc untouched" "$T/zshrc.seed" "$H/.zshrc"
  assert_absent "--no-input: no rc-file" "$H/.claude-multi/rc-file"
  assert_absent "--no-input: no login ran" "$STUB_LOG"
  out_has "--no-input: the source line is printed instead" 'claude-multi/aliases.sh'
  out_has "--no-input: the summary says the rc file was NOT touched" "rc file: NOT touched"
  # every answer 'n': asked, nothing done
  write_answers n n n n n
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- setup
  assert_rc "setup, all answers n" 0
  out_has "all-n: the summary defers to the offer instead of 'add it by hand'" "rc file: not sourced yet (asked below)"
  outerr_lacks "all-n: the summary does not also say NOT touched" "rc file: NOT touched"
  outerr_has "all-n: the rc offer names ~/.zshrc" "Append the source line to $H/.zshrc? [y/N]"
  outerr_has "all-n: the login offer for alice" "Log in to alice@example.com now? [Y/n]"
  outerr_has "all-n: the login offer for hans-proton (every account asked)" "Log in to hans@proton.test now? [Y/n]"
  assert_same_file "all-n: ~/.zshrc untouched" "$T/zshrc.seed" "$H/.zshrc"
  assert_absent "all-n: no rc-file" "$H/.claude-multi/rc-file"
  assert_absent "all-n: no login ran" "$STUB_LOG"
  assert_absent "all-n: no ~/.bashrc" "$H/.bashrc"
  # y (rc), n alice, y hans-betterdoc, n info, EOF → hans-proton never asked
  write_answers y n y n
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- setup
  assert_rc "setup, y n y n" 0
  assert_file_line "y: ~/.zshrc has the source line" "$H/.zshrc" "$RC_LINE"
  assert_eq "y: ~/.zshrc has exactly one aliases line" "1" "$(count_matches "$H/.zshrc" 'claude-multi/aliases')"
  assert_eq "y: ~/.zshrc is seed + blank + line" "3" "$(grep -c '' "$H/.zshrc")"
  assert_file_has "y: rc-file remembers ~/.zshrc" "$H/.claude-multi/rc-file" "$H/.zshrc"
  assert_eq "logins: exactly one ran" "1" "$(login_lines)"
  assert_eq "logins: it was hans-betterdoc" "$(expected_login_line hans-betterdoc hans@betterdoc.test)" "$(login_line_n 1)"
  out_has "logins: reported 'logged in as hans@betterdoc.test'" "logged in as hans@betterdoc.test"
  assert_absent "logins: hans-proton never reached (EOF)" "$acc/hans-proton/.stub-logged-in"
  assert_absent "n: alice has no marker" "$acc/alice/.stub-logged-in"
  assert_absent "n: info has no marker" "$acc/info/.stub-logged-in"
  cp "$H/.zshrc" "$T/zshrc.1"
  # rc line present → no rc offer; hans-betterdoc logged in (both heuristic + verified) → not offered
  mark_logged_in hans-betterdoc hans@betterdoc.test
  write_answers y
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- setup
  assert_rc "setup, rc present, one y" 0
  outerr_lacks "rc present: no rc offer" "Append the source line"
  assert_same_file "rc present: ~/.zshrc unchanged" "$T/zshrc.1" "$H/.zshrc"
  outerr_lacks "logged-in account not offered" "Log in to hans@betterdoc.test now?"
  assert_eq "second round: one more login" "2" "$(login_lines)"
  assert_eq "second round: alice (slot 1) first" "$(expected_login_line alice alice@example.com)" "$(login_line_n 2)"
  outerr_lacks "second round: EOF stopped before hans-proton" "Log in to hans@proton.test now?"
  # the offers follow `add` too: info n, hans-proton y, the new account → EOF
  mark_logged_in alice alice@example.com
  write_answers n y
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- add e@x.test
  assert_rc "add e@x.test" 0
  assert_dir "add: dir e exists" "$acc/e"
  outerr_has "add: info offered" "Log in to info@corp.test now? [Y/n]"
  assert_eq "add: one more login" "3" "$(login_lines)"
  assert_eq "add: it was hans-proton" "$(expected_login_line hans-proton hans@proton.test)" "$(login_line_n 3)"
  assert_absent "add: info skipped (n)" "$acc/info/.stub-logged-in"
  assert_absent "add: e never reached (EOF)" "$acc/e/.stub-logged-in"
  assert_same_file "add: ~/.zshrc unchanged" "$T/zshrc.1" "$H/.zshrc"
  # --relink asks nothing
  write_answers y y y y y
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- --relink
  assert_rc "--relink" 0
  outerr_lacks "--relink: no login offer" "now? [Y/n]"
  assert_eq "--relink: no login ran" "3" "$(login_lines)"
  # a login that fails inside the offers: the next account is still offered (§12.4 is per account), setup exits 0
  # (the offers read the .claude.json heuristic, so hans-proton — stub marker only — is offered again)
  : > "$H/stub-login-fails"
  write_answers y y y
  run_script "CLAUDE_MULTI_INPUT=$T/answers" SHELL=/bin/zsh -- setup
  assert_rc "setup, y y y with a failing stub" 0
  assert_eq "failing offers: all three accepted logins were attempted" "6" "$(login_lines)"
  assert_eq "failing offers: info first" "$(expected_login_line info info@corp.test)" "$(login_line_n 4)"
  assert_eq "failing offers: then hans-proton (offered after the failure)" "$(expected_login_line hans-proton hans@proton.test)" "$(login_line_n 5)"
  assert_eq "failing offers: then e" "$(expected_login_line e e@x.test)" "$(login_line_n 6)"
  outerr_has "failing offers: 'login did not complete for info@corp.test'" "login did not complete for info@corp.test"
  outerr_has "failing offers: e still offered" "Log in to e@x.test now? [Y/n]"
  outerr_has "failing offers: the note names the per-account command" "login info"
  outerr_lacks "failing offers: no false 'skipping the remaining logins'" "skipping the remaining logins"
  rm -f "$H/stub-login-fails"
  assert_seed_untouched
}

case_T23() { # update through a stub curl serving CLAUDE_MULTI_UPDATE_URL=file://…
  local inst="$H/.claude-multi/claude-multi-setup.sh" old
  cp "$FIX/curl" "$H/bin/curl"; chmod 755 "$H/bin/curl"
  old=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$SCRIPT" | head -n 1)
  # the "newer" script: the script under test with its VERSION line bumped (no sed -i: BSD/GNU differ)
  sed 's/^VERSION=.*/VERSION="9.9.9"/' "$SCRIPT" > "$T/newer.sh"
  sed 's/^VERSION=.*/VERSION="9.9.10"/' "$SCRIPT" > "$T/newer2.sh"
  printf 'hello, not a script\n' > "$T/bogus.txt"
  printf '#!/usr/bin/env bash\nSCRIPT_NAME="claude-multi-setup.sh"\nif then fi\n' > "$T/broken.sh"
  # everything but the final `main "$@"`: the SCRIPT_NAME line is there and bash -n passes, yet it would run nothing
  head -n "$(( $(grep -c '' "$T/newer.sh") - 1 ))" "$T/newer.sh" > "$T/trunc.sh"
  set_cswap json
  run_script -- setup
  assert_rc "setup" 0
  assert_same_file "installed copy is the script under test" "$SCRIPT" "$inst"
  # a newer file installs, then setup runs
  stamp
  run_script "CLAUDE_MULTI_UPDATE_URL=file://$T/newer.sh" -- update
  assert_rc "update (newer)" 0
  out_has "update reports <old> → <new>" "update $inst $old → 9.9.9"
  assert_same_file "installed copy is now the newer file" "$T/newer.sh" "$inst"
  assert_mode "installed copy is mode 755" "$inst" "-rwxr-xr-x"
  assert_file_has "stub curl was asked for the hook URL" "$H/stub-curl.log" "file://$T/newer.sh"
  out_has "setup ran after the install (summary present)" "Accounts (source:"
  assert_file_has "aliases.sh regenerated by the new script" "$H/.claude-multi/aliases.sh" "9.9.9"
  assert_eq "no claude-multi* temp files left under TMPDIR" "" "$(find "$T/tmp" -name 'claude-multi*' 2>/dev/null)"
  assert_file_lacks "update did not print a dry-run line" "$T/out" "[dry-run]"
  out_has "update tells the terminal to reload aliases.sh" "reload the launchers in this terminal: . $H/.claude-multi/aliases.sh"
  # the same file again: already up to date, nothing rewritten
  stamp
  run_script "CLAUDE_MULTI_UPDATE_URL=file://$T/newer.sh" -- update
  assert_rc "update (same)" 0
  out_has "second update says already up to date" "already up to date (9.9.9)"
  assert_eq "second update rewrote nothing under HOME" "" "$(newer_than "$T/stamp" | grep -v -x -e "$H" -e "$H/stub-curl.log")"
  assert_same_file "installed copy untouched" "$T/newer.sh" "$inst"
  # a non-script download is refused
  stamp
  run_script "CLAUDE_MULTI_UPDATE_URL=file://$T/bogus.txt" -- update
  assert_rc "update (not a script)" 1
  err_has "refusal message" "error: downloaded file is not claude-multi-setup.sh; installed copy untouched"
  assert_same_file "installed copy byte-identical after the refusal" "$T/newer.sh" "$inst"
  assert_eq "refusal rewrote nothing under HOME" "" "$(newer_than "$T/stamp" | grep -v -x -e "$H" -e "$H/stub-curl.log")"
  run_script "CLAUDE_MULTI_UPDATE_URL=file://$T/broken.sh" -- update
  assert_rc "update (SCRIPT_NAME line but bash -n fails)" 1
  err_has "broken download refused too" "error: downloaded file is not claude-multi-setup.sh; installed copy untouched"
  assert_same_file "installed copy byte-identical after the broken download" "$T/newer.sh" "$inst"
  run_script "CLAUDE_MULTI_UPDATE_URL=file://$T/trunc.sh" -- update
  assert_rc "update (truncated before main)" 1
  err_has "truncated download refused" "error: downloaded file is not claude-multi-setup.sh; installed copy untouched"
  assert_same_file "installed copy byte-identical after the truncated download" "$T/newer.sh" "$inst"
  # a missing file (curl exits 22)
  run_script "CLAUDE_MULTI_UPDATE_URL=file://$T/missing.sh" -- update
  assert_rc "update (download fails)" 1
  err_matches "download failure is an 'error: ' line" '^error: '
  assert_same_file "installed copy byte-identical after the failed download" "$T/newer.sh" "$inst"
  # --dry-run installs nothing
  stamp
  run_script "CLAUDE_MULTI_UPDATE_URL=file://$T/newer2.sh" -- update --dry-run
  assert_rc "update --dry-run" 0
  out_matches "dry-run reports what it would do" '^  \[dry-run\] would update '
  out_has "dry-run names the new version" "9.9.10"
  assert_same_file "dry-run installed nothing" "$T/newer.sh" "$inst"
  assert_eq "dry-run rewrote nothing under HOME" "" "$(newer_than "$T/stamp" | grep -v -x -e "$H" -e "$H/stub-curl.log")"
  # without the hook the default URL is used (the stub cannot serve it → exit 1), and CLAUDE_MULTI_REF selects the ref
  rm -f "$H/stub-curl.log"
  run_script -- update
  assert_rc "update from the default URL (unserved by the stub)" 1
  assert_file_has "default URL is the main branch on raw.githubusercontent.com" "$H/stub-curl.log" \
    "https://raw.githubusercontent.com/hanslemm/claude-multi/main/skills/claude-multi/scripts/claude-multi-setup.sh"
  run_script CLAUDE_MULTI_REF=v1.1.0 -- update
  assert_file_has "CLAUDE_MULTI_REF selects the ref" "$H/stub-curl.log" "/hanslemm/claude-multi/v1.1.0/skills/claude-multi/scripts/claude-multi-setup.sh"
  assert_same_file "installed copy still the newer file" "$T/newer.sh" "$inst"
  assert_seed_untouched
}

case_title() {
  case "$1" in
    T1) printf 'cswap list --json (4 accounts, two share local part hans)' ;;
    T2) printf 'export-only cswap (list --json fails)' ;;
    T3) printf 'ANSI-only cswap (scraped listing)' ;;
    T4) printf 'jq + python3 shadowed with failing stubs' ;;
    T5) printf 'no cswap: add, add --slot 5, add again' ;;
    T6) printf 'ACCOUNT_ROWS with a broken cswap in PATH' ;;
    T7) printf 'no cswap, no registry, --no-input, stdin not a tty' ;;
    T8) printf '%s' '--dry-run on a fresh HOME' ;;
    T9) printf 'second run is a no-op' ;;
    T10) printf '5th account added in cswap' ;;
    T11) printf '%s' '--relink after deleting one link' ;;
    T12) printf 'per-repo memory links' ;;
    T13) printf '%s' '--rc twice (zsh), bash, --rc=FILE' ;;
    T14) printf 'aliases.sh sourced in zsh and bash' ;;
    T15) printf 'remove b@y.test' ;;
    T16) printf 'status before and after a fake login' ;;
    T17) printf 'v1 accounts.tsv + v1 aliases.zsh' ;;
    T18) printf 'self-install from the repo path' ;;
    T19) printf 'claude-multi umbrella + CLAUDE_MULTI_ACCOUNT in zsh and bash' ;;
    T20) printf 'login <slug|slot|email> / --all against the stub claude' ;;
    T21) printf 'status --verify' ;;
    T22) printf 'interactive offers via CLAUDE_MULTI_INPUT' ;;
    T23) printf 'update via CLAUDE_MULTI_UPDATE_URL=file:// through a stub curl' ;;
    *) printf '?' ;;
  esac
}

run_case() {
  local name=$1 rc n_ok n_fail
  printf '== %s: %s\n' "$name" "$(case_title "$name")"
  new_home
  ( "case_$name" ) 2>&1 | tee "$T/case.log"
  rc=${PIPESTATUS[0]}
  n_ok=$(grep -c '^  ok: ' "$T/case.log" 2>/dev/null || true)
  n_fail=$(grep -c '^  FAIL: ' "$T/case.log" 2>/dev/null || true)
  if [ "$rc" != 0 ]; then
    printf '  FAIL: %s crashed (exit %s)\n' "$name" "$rc"
    n_fail=$((n_fail + 1))
  fi
  TOTAL_OK=$((TOTAL_OK + n_ok))
  TOTAL_FAIL=$((TOTAL_FAIL + n_fail))
  CASES_RUN=$((CASES_RUN + 1))
  [ "$n_fail" = 0 ] || CASES_FAIL=$((CASES_FAIL + 1))
  [ "$KEEP" = 1 ] && printf '  (kept %s)\n' "$T"
  teardown_home
}

# ---------- main ----------
usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; }

main() {
  local cases="" c
  for c in "$@"; do
    case "$c" in
      -h | --help) usage; exit 0 ;;
      T[0-9] | T1[0-9] | T2[0-3]) cases="$cases $c" ;;
      *) printf 'harness: unknown case %s (T1..T23)\n' "$c" >&2; exit 2 ;;
    esac
  done
  [ -n "$cases" ] || cases=$ALL_CASES
  if [ ! -f "$SCRIPT" ]; then printf 'harness: SCRIPT not found: %s\n' "$SCRIPT" >&2; exit 2; fi
  if [ ! -x "$RUN_BASH" ]; then printf 'harness: TEST_BASH not executable: %s\n' "$RUN_BASH" >&2; exit 2; fi
  printf 'claude-multi harness\n  script: %s\n  bash:   %s (%s)\n  zsh:    %s\n' \
    "$SCRIPT" "$RUN_BASH" "$("$RUN_BASH" -c 'printf %s "$BASH_VERSION"')" "${ZSH_BIN:-<not found>}"
  make_fixtures
  trap 'if [ "$KEEP" != 1 ]; then rm -rf "$FIX"; fi' EXIT
  for c in $cases; do run_case "$c"; done
  if [ -n "$KEPT_DIRS" ]; then printf 'kept:%s\n' "$KEPT_DIRS"; fi
  printf 'asserts: %s ok, %s failed\n' "$TOTAL_OK" "$TOTAL_FAIL"
  if [ "$TOTAL_FAIL" = 0 ] && [ "$CASES_FAIL" = 0 ]; then
    printf 'PASS %s/%s\n' "$CASES_RUN" "$CASES_RUN"
    exit 0
  fi
  printf 'FAIL %s/%s\n' "$CASES_FAIL" "$CASES_RUN"
  exit 1
}

main "$@"
