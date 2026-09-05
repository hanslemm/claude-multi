#!/usr/bin/env bash
# tests/harness.sh — the test matrix of docs/design.md §10 (T1–T18) for claude-multi-setup.sh.
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
ALL_CASES="T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11 T12 T13 T14 T15 T16 T17 T18"

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

  cat > "$FIX/claude" <<'EOF'
#!/bin/sh
# stub claude: prints what a launcher handed it, exactly as docs/design.md §10 says
printf 'stub claude CLAUDE_CONFIG_DIR=%s KEY=%s ARGS=%s\n' "${CLAUDE_CONFIG_DIR-<unset>}" "${ANTHROPIC_API_KEY-<unset>}" "$*"
printf 'stub env AUTH_TOKEN=%s OAUTH=%s\n' "${ANTHROPIC_AUTH_TOKEN-<unset>}" "${CLAUDE_CODE_OAUTH_TOKEN-<unset>}"
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
run_script() { # [VAR=value …] -- args…   → $T/out, $T/err, $RC; a 60 s watchdog kills a hung script
  local pid wd n
  local -a extra
  extra=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do extra[${#extra[@]}]=$1; shift; done
  [ "${1-}" = "--" ] && shift
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
  out_matches "summary: login hint for hans-proton" '^  claude-hans-proton +then /login as hans@proton\.test'
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
  assert_file_has "[$L] NOT logged in wording" "$P/cwho-unpinned.out" "NOT logged in → run claude-hans-proton and /login once"
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
  assert_file_line "[$L] cuse hans-proton: not-logged-in hint" "$P/cuse-slug.out" "  not logged in yet: run  claude-hans-proton  and complete /login once"
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
  out_has "next: first not-logged-in account" "next: run claude-alice and /login"
  next1=$(sed -n 's/^next: //p' "$T/out")
  printf '{"oauthAccount":{}}\n' 2>/dev/null > "$H/.claude-accounts/alice/.claude.json"
  stamp
  run_script -- status
  assert_rc "status after fake login" 0
  out_line "account 1 now logged-in" "account: 1 alice alice@example.com logged-in"
  next2=$(sed -n 's/^next: //p' "$T/out")
  assert_ne "next: changed after the login" "$next1" "$next2"
  out_has "next: now names hans-betterdoc" "claude-hans-betterdoc"
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
      T[0-9] | T1[0-8]) cases="$cases $c" ;;
      *) printf 'harness: unknown case %s (T1..T18)\n' "$c" >&2; exit 2 ;;
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
