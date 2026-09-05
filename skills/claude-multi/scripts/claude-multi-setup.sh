#!/usr/bin/env bash
# claude-multi-setup.sh — one Claude Code login per terminal.
#
# Contract: docs/design.md in the claude-multi repository (this file implements §2–§9 and §12 of it).
#
# Produces:
#   ~/.claude-accounts/<slug>/          one CLAUDE_CONFIG_DIR per account (own login, own Keychain entry, own
#                                       .claude.json). Never deleted by this script.
#   ~/.claude-shared/                   settings.json, mcp.json, CLAUDE.md, commands/, agents/, skills/,
#                                       output-styles/ — seeded ONCE by COPYING from ~/.claude, never overwritten.
#   ~/.claude-multi/aliases.sh          claude-<slug> launchers, claude<N> slot aliases, cuse, cwho and the
#                                       claude-multi umbrella function (zsh + bash)
#   ~/.claude-multi/accounts.tsv        slot<TAB>email<TAB>slug registry; a slug never changes once assigned
#   ~/.claude-multi/claude-multi-setup.sh   self-installed copy of this script (the stable path)
#   <account>/projects/<repo>/memory -> ~/.claude/projects/<repo>/memory   per-repo auto-memory, shared
#
# Sharing model: CLAUDE.md + the four directories are SYMLINKED into every account dir (Claude only reads
# them). settings.json and mcp.json are passed as --settings / --mcp-config flags, never symlinked, because
# Claude Code rewrites settings.json on /config and would replace a symlink with a plain file.
#
# Discovery: $ACCOUNT_ROWS if set, else cswap (`list --json`, `export <tmp>`, ANSI-stripped `list`), then the
# union with accounts.tsv rows that carry a slot, then an interactive prompt (reads /dev/tty), then an error.
#
# v1.1 (§12): `login <slug|slot|email>` / `login --all` runs `claude auth login --email …` under the account dir,
# `status --verify` asks `claude auth status` per account, `update` replaces the installed copy from GitHub, and
# setup/add end with interactive offers (append the rc line, log in to each account) when a terminal is there.
#
# Internal test hook: CLAUDE_MULTI_INPUT=<file> makes every interactive prompt (emails, rc offer, login offers)
# read its answers line by line from that file instead of the terminal, and counts as "a terminal is available".
# CLAUDE_MULTI_UPDATE_URL=<url> makes `update` download from that URL instead of GitHub (whoever controls the
# environment already controls PATH, so this widens nothing).
#
# bash 3.2 + BSD/GNU userland. set -u, no set -e: every mutating command is checked explicitly.
# Idempotent: a re-run with nothing new changes nothing (mtimes included).

# shellcheck disable=SC2004,SC2016,SC2018,SC2019  # $i in indices is deliberate (bash 3.2 style); literal-$ strings are intended
set -u

VERSION="1.1.0"
SCRIPT_NAME="claude-multi-setup.sh"

[ -n "${HOME:-}" ] || { printf 'error: HOME is not set\n' >&2; exit 1; }
ACCOUNTS_ROOT="$HOME/.claude-accounts"
SHARED_DIR="$HOME/.claude-shared"
MULTI_DIR="$HOME/.claude-multi"
ALIASES_FILE="$MULTI_DIR/aliases.sh"
LEGACY_ALIASES_FILE="$MULTI_DIR/aliases.zsh"
REGISTRY_FILE="$MULTI_DIR/accounts.tsv"
RC_MEMO_FILE="$MULTI_DIR/rc-file"   # the rc file --rc appended to, so status finds a custom --rc=FILE later
INSTALL_PATH="$MULTI_DIR/$SCRIPT_NAME"
SEED_DIR="$HOME/.claude"
SEED_JSON="$HOME/.claude.json"
RC_LINE='[ -f "$HOME/.claude-multi/aliases.sh" ] && . "$HOME/.claude-multi/aliases.sh"'
RC_MARKER='claude-multi/aliases'
REGISTRY_HEADER='# claude-multi accounts: slot<TAB>email<TAB>slug. Edit with `claude-multi-setup.sh add|remove`.'
SHARED_LINKS="CLAUDE.md commands agents skills output-styles"
SHARED_SUBDIRS="commands agents skills output-styles"
EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$'
SLOT_RE='^[0-9]+$'
SLUG_RE='^[a-z0-9][a-z0-9-]*$'   # a slug is a path component AND a shell function name: nothing else gets in
TAB=$(printf '\t')

CMD=""            # setup | add | remove | status | login | update
EMAIL_ARG=""      # add/remove operand
SLOT_ARG=""       # add --slot N
LOGIN_ARG=""      # login operand: slug | slot | email
LOGIN_ALL=0       # login --all
VERIFY=0          # status --verify
DRY_RUN=0
RELINK=0
RC_APPEND=0
RC_FILE_ARG=""
NO_INPUT=0
UPDATE_REPO="hanslemm/claude-multi"
UPDATE_PATH="skills/claude-multi/scripts/claude-multi-setup.sh"
CHANGES=0
WARNINGS=0
TMP_DIR=""
REMOVED_EMAIL=""  # remove: excluded from this run's account list even if cswap still lists it
REMOVED_SEEN=0    # remove: cswap still lists the email
REMOVED_SLUG=""   # remove: slug of the forgotten row (names the kept dir in the summary)

# ---------- output ----------
say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
warn() { printf '  warning: %s\n' "$*" >&2; WARNINGS=$((WARNINGS + 1)); }
die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
usage_err() { printf 'error: %s\n' "$*" >&2; printf "try '%s --help'\\n" "$(self_cmd)" >&2; exit 2; }
dry()  { [ "$DRY_RUN" = 1 ]; }
did()  {
  CHANGES=$((CHANGES + 1))
  if dry; then printf '  [dry-run] would %s\n' "$*"; else printf '  + %s\n' "$*"; fi
}

usage() {
  cat <<EOF
claude-multi-setup.sh $VERSION — one Claude Code login per terminal.

usage:
  $SCRIPT_NAME [setup] [--dry-run] [--relink] [--rc[=FILE]] [--no-input]
  $SCRIPT_NAME add <email> [--slot N] [setup flags]
  $SCRIPT_NAME remove <email> [setup flags]
  $SCRIPT_NAME status [--verify]
  $SCRIPT_NAME login <slug|slot|email> | --all
  $SCRIPT_NAME update [--dry-run]
  $SCRIPT_NAME --help | -h | --version

commands:
  setup          (default) discover accounts, seed ~/.claude-shared, create one CLAUDE_CONFIG_DIR per
                 account under ~/.claude-accounts, write accounts.tsv + aliases.sh, self-install, summary;
                 in a terminal it then offers to append the rc line and to log in to each account
  add <email>    register an account (slot N, or the lowest free slot), then run setup
  remove <email> forget an account (its dir and login are kept), then run setup
  status         read-only report: paths, cswap, this terminal, every account's login state, next step
                 --verify asks 'claude auth status' under each account dir instead of the .claude.json heuristic
  login <acct>   run 'claude auth login --email <email>' under that account's dir (opens the browser; needs a
                 terminal); --all does it for every account that is not logged in, in slot order
  update         download the latest script from GitHub into ~/.claude-multi (CLAUDE_MULTI_REF picks a branch
                 or tag), then run setup --no-input so aliases.sh gains any new functions

flags:
  --dry-run      print every change as '[dry-run] would …'; create nothing
  --relink       only (re)create the shared + memory symlinks in the account dirs that already exist
  --rc[=FILE]    append the source line to the rc file (by \$SHELL, or FILE), once; never touched otherwise
  --no-input     never prompt (scripted / AI-driven runs); exit 1 with instructions instead

discovery order: \$ACCOUNT_ROWS ('slot<TAB>email' lines) · cswap · accounts.tsv rows · interactive prompt.
exit codes: 0 ok · 1 error ('error: …' on stderr) · 2 usage.
EOF
}

cleanup() { [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"; }
trap cleanup EXIT
mk_tmp() {
  [ -n "$TMP_DIR" ] && return 0
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/claude-multi.XXXXXX") || die "mktemp failed"
  chmod 700 "$TMP_DIR" || die "cannot chmod $TMP_DIR"
}

# Absolute path of the running script (for self-install and `status`).
script_path() {
  local p="$0" d b
  case "$p" in
    */*) ;;
    *) p=$(command -v -- "$p" 2>/dev/null) || p="$PWD/$p" ;;
  esac
  d=${p%/*}; b=${p##*/}
  [ -n "$d" ] || d=/
  d=$(cd -- "$d" 2>/dev/null && pwd -P) || d=${p%/*}
  printf '%s/%s' "${d%/}" "$b"
}
SCRIPT_PATH=$(script_path)
# The command a message tells the user to run next: the installed copy (the stable path) once it exists.
self_cmd() { if [ -f "$INSTALL_PATH" ]; then printf '%s' "$INSTALL_PATH"; else printf '%s' "$SCRIPT_PATH"; fi; }

# ---------- fs helpers ----------
ensure_dir() { # dir mode
  [ -d "$1" ] && return 0
  did "create $1"
  dry || { mkdir -p -- "$1" && chmod "$2" "$1"; } || die "cannot create $1"
}

ensure_link() { # link target
  local link="$1" target="$2" cur
  if [ -L "$link" ]; then
    cur=$(readlink -- "$link")
    [ "$cur" = "$target" ] && return 0
    did "repoint $link -> $target (was $cur)"
    dry || { rm -f -- "$link" && ln -s -- "$target" "$link"; } || die "cannot relink $link"
  elif [ -d "$link" ] && [ -z "$(ls -A -- "$link")" ]; then
    did "replace empty dir $link with link -> $target"
    dry || { rmdir -- "$link" && ln -s -- "$target" "$link"; } || die "cannot replace $link"
  elif [ -e "$link" ]; then
    warn "$link exists and is not a symlink; left alone (move it aside, then --relink, to share it)"
  else
    did "link $link -> $target"
    dry || ln -s -- "$target" "$link" || die "cannot link $link"
  fi
}

# Install content from a temp file only when the destination differs (keeps a no-op run byte-identical).
install_file() { # tmp dest mode what
  local tmp="$1" dest="$2" mode="$3" what="$4"
  if [ -f "$dest" ] && cmp -s -- "$tmp" "$dest"; then return 0; fi
  if [ -f "$dest" ]; then did "regenerate $what"; else did "write $what"; fi
  dry && return 0
  { cp -- "$tmp" "$dest.tmp" && chmod "$mode" "$dest.tmp" && mv -f -- "$dest.tmp" "$dest"; } || die "cannot write $dest"
}

link_shared_into() { # account-dir
  local n
  for n in $SHARED_LINKS; do ensure_link "$1/$n" "$SHARED_DIR/$n"; done
}

link_memory_into() { # account-dir — every repo whose auto-memory exists in ~/.claude gets a link to it
  local m p
  [ -d "$SEED_DIR/projects" ] || return 0
  for m in "$SEED_DIR"/projects/*/memory; do
    [ -d "$m" ] && [ ! -L "$m" ] || continue
    p=${m%/memory}; p=${p##*/}
    ensure_dir "$1/projects/$p" 700
    ensure_link "$1/projects/$p/memory" "$m"
  done
}

logged_in() { # slug — the .claude.json heuristic (no network, no claude binary needed)
  local f="$ACCOUNTS_ROOT/$1/.claude.json"
  [ -f "$f" ] && grep -q '"oauthAccount"' -- "$f" 2>/dev/null
}

# ---------- claude auth (§12.2 / §12.3): every call runs under the account dir, with the three credential ----------
# ---------- variables unset so the CLI looks at that directory's login and nothing else ----------
claude_in_path() { command -v claude >/dev/null 2>&1; }
run_as_account() { # slug cmd args… — stdio inherited (the CLI's own URL and prompts must reach the user)
  local slug="$1"; shift
  (
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
    export CLAUDE_CONFIG_DIR="$ACCOUNTS_ROOT/$slug"
    "$@"
  )
}
auth_status_json() { # slug → the `claude auth status` JSON on stdout ('' when the call fails)
  # a missing dir holds no login — and the CLI would create it (mode 755, with a .claude.json) just to say so
  [ -d "$ACCOUNTS_ROOT/$1" ] || return 1
  run_as_account "$1" claude auth status 2>/dev/null < /dev/null
}
json_logged_in() { grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true' ; }     # stdin: the JSON
json_email() { sed -n 's/.*"email"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1; }   # stdin: the JSON
verified_logged_in() { auth_status_json "$1" | json_logged_in; }   # slug

account_state_line() { # slot slug email [verified] → 'account: …' exactly as status prints it (§8 / §12.3)
  local state
  if [ "${4:-}" = verified ]; then
    if verified_logged_in "$2"; then state='logged-in (verified)'; else state='not-logged-in (verified)'; fi
  elif logged_in "$2"; then state=logged-in
  else state=not-logged-in
  fi
  printf 'account: %s %s %s %s\n' "$1" "$2" "$3" "$state"
}

# The one login procedure (§12.2): claude auth login --email <email> under the account dir, then claude auth status.
login_account() { # slot slug email → 0 logged in, 1 the login did not complete
  local slot="$1" slug="$2" email="$3" dir rc json other
  dir="$ACCOUNTS_ROOT/$slug"
  if [ ! -d "$dir" ]; then
    { mkdir -p -- "$dir" && chmod 700 "$dir"; } || die "cannot create $dir"
  fi
  say "Logging in to $email — CLAUDE_CONFIG_DIR=$dir (the browser opens; finish the login there):"
  # stdin is the pipe on the `curl … | sh` path (install.sh execs this script); the CLI's paste-code fallback
  # reads stdin, so give it the terminal when there is one and stdin is not it
  if ! [ -t 0 ] && ( : < /dev/tty ) 2>/dev/null; then
    run_as_account "$slug" claude auth login --email "$email" < /dev/tty; rc=$?
  else
    run_as_account "$slug" claude auth login --email "$email"; rc=$?
  fi
  if [ $rc != 0 ]; then
    say "login did not complete for $email (claude auth login exited $rc)"
    return 1
  fi
  json=$(auth_status_json "$slug")
  if printf '%s' "$json" | json_logged_in; then
    say "logged in as $email"
    other=$(printf '%s' "$json" | json_email)
    [ -n "$other" ] && [ "$other" != "$email" ] && warn "logged in as $other, expected $email"
  else
    warn "claude auth login exited 0 but claude auth status reports no login for $email"
  fi
  account_state_line "$slot" "$slug" "$email" verified
  return 0
}

# ---------- shared config (seeded once, never overwritten) ----------
mcp_server_count() { # json-file → count of .mcpServers keys ('' if unreadable)
  if command -v jq >/dev/null 2>&1; then
    jq -r '(.mcpServers // {}) | length' "$1" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("mcpServers") or {}))' "$1" 2>/dev/null
  fi
}

write_mcp_json() { # dest ← {"mcpServers": <from SEED_JSON>}
  if command -v jq >/dev/null 2>&1; then
    jq '{mcpServers: (.mcpServers // {})}' "$SEED_JSON" > "$1"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); json.dump({"mcpServers": d.get("mcpServers") or {}}, open(sys.argv[2],"w"), indent=2); open(sys.argv[2],"a").write("\n")' "$SEED_JSON" "$1"
  else
    return 1
  fi
}

# A settings file passed via --settings re-injects env.ANTHROPIC_API_KEY / apiKeyHelper on EVERY launch, above the
# launcher's unset — so it would silently bill the API. Names the file only; never prints a value.
settings_credential_warning() { # file
  [ -f "$1" ] || return 0
  grep -qE '"(ANTHROPIC_API_KEY|ANTHROPIC_AUTH_TOKEN|CLAUDE_CODE_OAUTH_TOKEN|apiKeyHelper)"' -- "$1" 2>/dev/null || return 0
  warn "$1 carries an API credential (env.ANTHROPIC_API_KEY / apiKeyHelper / …): every claude-<slug> launch passes it via --settings and will use it instead of the account login — remove it from that file"
}

seed_shared() {
  local d count
  ensure_dir "$SHARED_DIR" 755

  if [ ! -e "$SHARED_DIR/settings.json" ]; then
    if [ -f "$SEED_DIR/settings.json" ]; then
      did "seed $SHARED_DIR/settings.json (copy of $SEED_DIR/settings.json)"
      dry || cp -- "$SEED_DIR/settings.json" "$SHARED_DIR/settings.json" || die "cannot copy settings.json"
    else
      did "seed empty $SHARED_DIR/settings.json (no $SEED_DIR/settings.json to copy)"
      dry || printf '{}\n' > "$SHARED_DIR/settings.json" || die "cannot write settings.json"
    fi
  fi
  if [ -e "$SHARED_DIR/settings.json" ]; then settings_credential_warning "$SHARED_DIR/settings.json"
  else settings_credential_warning "$SEED_DIR/settings.json"; fi

  if [ ! -e "$SHARED_DIR/mcp.json" ]; then
    count=""
    [ -f "$SEED_JSON" ] && count=$(mcp_server_count "$SEED_JSON")
    if [ -n "$count" ] && [ "$count" != 0 ]; then
      did "seed $SHARED_DIR/mcp.json ($count user-scope MCP server(s) copied from $SEED_JSON)"
      # user-scope MCP servers carry headers/env tokens: keep the copy as private as ~/.claude.json (0600)
      dry || { write_mcp_json "$SHARED_DIR/mcp.json" && chmod 600 "$SHARED_DIR/mcp.json"; } || die "cannot write mcp.json"
    else
      if [ -f "$SEED_JSON" ] && [ -z "$count" ]; then
        warn "neither jq nor python3 available: could not read mcpServers from $SEED_JSON; seeding an empty mcp.json"
      fi
      did "seed empty $SHARED_DIR/mcp.json (no user-scope mcpServers in $SEED_JSON)"
      dry || { printf '{\n  "mcpServers": {}\n}\n' > "$SHARED_DIR/mcp.json" && chmod 600 "$SHARED_DIR/mcp.json"; } || die "cannot write mcp.json"
    fi
  fi

  if [ ! -e "$SHARED_DIR/CLAUDE.md" ]; then
    if [ -f "$SEED_DIR/CLAUDE.md" ]; then
      did "seed $SHARED_DIR/CLAUDE.md (copy of $SEED_DIR/CLAUDE.md)"
      dry || cp -- "$SEED_DIR/CLAUDE.md" "$SHARED_DIR/CLAUDE.md" || die "cannot copy CLAUDE.md"
    else
      did "seed empty $SHARED_DIR/CLAUDE.md (no $SEED_DIR/CLAUDE.md to copy)"
      dry || : > "$SHARED_DIR/CLAUDE.md" || die "cannot write CLAUDE.md"
    fi
  fi

  for d in $SHARED_SUBDIRS; do
    [ -e "$SHARED_DIR/$d" ] && continue
    if [ -d "$SEED_DIR/$d" ]; then
      did "seed $SHARED_DIR/$d/ (copy of $SEED_DIR/$d/)"
      dry || cp -R -- "$SEED_DIR/$d" "$SHARED_DIR/$d" || die "cannot copy $d"
    else
      did "create empty $SHARED_DIR/$d/ (no $SEED_DIR/$d/ to copy)"
      dry || mkdir -p -- "$SHARED_DIR/$d" || die "cannot create $d"
    fi
  done
}

# ---------- discovery (steps 1–2 of §4) ----------
strip_ansi() {
  local esc; esc=$(printf '\033')
  sed -e "s/${esc}\[[0-9;?]*[A-Za-z]//g" -e "s/${esc}[()][A-Za-z0-9]//g"
}

json_to_rows() { # json-file → "slot<TAB>email" lines
  if command -v jq >/dev/null 2>&1; then
    jq -r '.accounts[]? | select(.email != null) | "\(.number)\t\(.email)"' "$1" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY' 2>/dev/null && return 0
import json, sys
d = json.load(open(sys.argv[1]))
for a in d.get("accounts", []):
    if a.get("email"):
        print("%s\t%s" % (a.get("number", ""), a["email"]))
PY
  fi
  # last resort: pair "number" and "email" keys in document order
  grep -oE '"(number|email)"[[:space:]]*:[[:space:]]*("[^"]*"|[0-9]+)' "$1" 2>/dev/null \
    | sed -E 's/^"([a-z]+)"[[:space:]]*:[[:space:]]*"?([^"]*)"?$/\1 \2/' \
    | awk '$1 == "number" { n = $2; next }
           $1 == "email" && n != "" { printf "%s\t%s\n", n, $2; n = "" }'
}

scrape_rows() { # stdin: ANSI-stripped `cswap list` → "slot<TAB>email" lines
  local text rows
  text=$(cat)
  rows=$(printf '%s\n' "$text" | awk '
    /^[[:space:]]*[0-9]+[.:)][[:space:]]+[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+/ {
      n = $1; sub(/[.:)]$/, "", n); printf "%s\t%s\n", n, $2
    }')
  if [ -z "$rows" ]; then # no slot numbers: every distinct email in order, numbered 1..n
    rows=$(printf '%s\n' "$text" | grep -oE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' \
      | awk '!seen[$0]++ { printf "%d\t%s\n", ++n, $0 }')
  fi
  printf '%s\n' "$rows"
}

DISCOVERED_ROWS=""
DISCOVERY_SOURCE=""
CSWAP_STATE=""
discover() { # → DISCOVERED_ROWS, DISCOVERY_SOURCE, CSWAP_STATE
  if [ -n "${ACCOUNT_ROWS:-}" ]; then
    DISCOVERED_ROWS="$ACCOUNT_ROWS"
    DISCOVERY_SOURCE='$ACCOUNT_ROWS'
    return 0
  fi
  command -v cswap >/dev/null 2>&1 || { CSWAP_STATE="not in PATH"; return 1; }
  mk_tmp
  # 1. machine-readable listing, no tokens involved
  if cswap list --json > "$TMP_DIR/list.json" 2>/dev/null; then
    DISCOVERED_ROWS=$(json_to_rows "$TMP_DIR/list.json")
    [ -n "$DISCOVERED_ROWS" ] && { DISCOVERY_SOURCE='cswap list --json'; return 0; }
  fi
  # 2. plaintext export — carries OAuth tokens, so it lives only inside the 0700 tmp dir and is removed here
  if cswap export "$TMP_DIR/export.json" > /dev/null 2>&1 && [ -s "$TMP_DIR/export.json" ]; then
    DISCOVERED_ROWS=$(json_to_rows "$TMP_DIR/export.json")
    rm -f -- "$TMP_DIR/export.json"
    [ -n "$DISCOVERED_ROWS" ] && { DISCOVERY_SOURCE='cswap export'; return 0; }
  fi
  rm -f -- "$TMP_DIR/export.json"
  # 3. scrape the human listing
  DISCOVERED_ROWS=$(cswap list 2>/dev/null | strip_ansi | scrape_rows)
  [ -n "$DISCOVERED_ROWS" ] && { DISCOVERY_SOURCE='cswap list (ANSI-stripped, scraped)'; return 0; }
  DISCOVERED_ROWS=""
  CSWAP_STATE="listed nothing"
  return 1
}

DISC_SLOTS=()
DISC_EMAILS=()
parse_discovered() { # DISCOVERED_ROWS → DISC_SLOTS[], DISC_EMAILS[] (sorted by slot, de-duplicated by email)
  local slot email rest i dup
  DISC_SLOTS=(); DISC_EMAILS=()
  [ -n "$DISCOVERED_ROWS" ] || return 0
  while read -r slot email rest; do
    [ -z "$slot" ] && continue
    case "$slot" in '#'*) continue ;; esac
    [[ "$slot" =~ $SLOT_RE ]] || die "bad slot '$slot' in row '$slot $email' (from $DISCOVERY_SOURCE)"
    [[ "$email" =~ $EMAIL_RE ]] || die "bad email '$email' in row '$slot $email' (from $DISCOVERY_SOURCE)"
    dup=0; i=0
    while [ $i -lt ${#DISC_EMAILS[@]} ]; do
      [ "${DISC_EMAILS[$i]}" = "$email" ] && dup=1
      [ "${DISC_SLOTS[$i]}" = "$slot" ] && [ $dup = 0 ] && die "slot $slot listed twice (${DISC_EMAILS[$i]} and $email)"
      i=$((i + 1))
    done
    [ $dup = 1 ] && continue
    if [ "$email" = "$REMOVED_EMAIL" ]; then REMOVED_SEEN=1; continue; fi
    DISC_SLOTS[${#DISC_SLOTS[@]}]=$slot
    DISC_EMAILS[${#DISC_EMAILS[@]}]=$email
  done <<EOF
$(printf '%s\n' "$DISCOVERED_ROWS" | sort -n)
EOF
}

# ---------- registry (accounts.tsv) ----------
REG_SLOTS=()   # '' for a v1 row (email<TAB>slug, no slot)
REG_EMAILS=()
REG_SLUGS=()   # '' for a row added this run (slug assigned below)
TAKEN=()
load_registry() {
  local a b c slot email slug i lineno=0
  REG_SLOTS=(); REG_EMAILS=(); REG_SLUGS=(); TAKEN=()
  [ -f "$REGISTRY_FILE" ] || return 0
  while IFS="$TAB" read -r a b c; do
    lineno=$((lineno + 1))
    case "$a" in '' | '#'*) continue ;; esac
    if [ -n "$c" ]; then slot=$a; email=$b; slug=$c
    elif [ -n "$b" ]; then slot=""; email=$a; slug=$b        # v1: email<TAB>slug
    else warn "$REGISTRY_FILE:$lineno: unreadable row skipped"; continue
    fi
    if [ -n "$slot" ] && ! [[ "$slot" =~ $SLOT_RE ]]; then warn "$REGISTRY_FILE:$lineno: bad slot '$slot'; row skipped"; continue; fi
    [[ "$email" =~ $EMAIL_RE ]] || { warn "$REGISTRY_FILE:$lineno: bad email '$email'; row skipped"; continue; }
    [[ "$slug" =~ $SLUG_RE ]] || { warn "$REGISTRY_FILE:$lineno: bad slug '$slug'; row skipped"; continue; }
    i=0
    while [ $i -lt ${#REG_EMAILS[@]} ]; do
      [ "${REG_EMAILS[$i]}" = "$email" ] && { warn "$REGISTRY_FILE:$lineno: $email listed twice; later row skipped"; continue 2; }
      if [ -n "$slot" ] && [ "${REG_SLOTS[$i]}" = "$slot" ]; then
        # status must exit 0 whatever the file looks like (§3); setup treats the duplicate as the error §4 names
        [ "$CMD" = status ] && { warn "$REGISTRY_FILE:$lineno: slot $slot already held by ${REG_EMAILS[$i]}; row skipped"; continue 2; }
        die "$REGISTRY_FILE: slot $slot listed twice (${REG_EMAILS[$i]} and $email)"
      fi
      i=$((i + 1))
    done
    REG_SLOTS[${#REG_SLOTS[@]}]=$slot
    REG_EMAILS[${#REG_EMAILS[@]}]=$email
    REG_SLUGS[${#REG_SLUGS[@]}]=$slug
    TAKEN[${#TAKEN[@]}]=$slug
  done < "$REGISTRY_FILE"
}
reg_index_for() { # email → index (rc 1 if unknown)
  local i=0
  while [ $i -lt ${#REG_EMAILS[@]} ]; do
    [ "${REG_EMAILS[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
    i=$((i + 1))
  done
  return 1
}
registry_slug_for() { # email → slug (rc 1 if unknown or not yet assigned)
  local i
  i=$(reg_index_for "$1") || return 1
  [ -n "${REG_SLUGS[$i]}" ] || return 1
  printf '%s' "${REG_SLUGS[$i]}"
}
slot_holder() { # slot → email holding it (discovered or registry), rc 1 if free
  local i=0
  while [ $i -lt ${#DISC_SLOTS[@]} ]; do
    [ "${DISC_SLOTS[$i]}" = "$1" ] && { printf '%s' "${DISC_EMAILS[$i]}"; return 0; }
    i=$((i + 1))
  done
  i=0
  while [ $i -lt ${#REG_EMAILS[@]} ]; do
    [ "${REG_SLOTS[$i]}" = "$1" ] && [ "${REG_EMAILS[$i]}" != "$REMOVED_EMAIL" ] && { printf '%s' "${REG_EMAILS[$i]}"; return 0; }
    i=$((i + 1))
  done
  return 1
}
lowest_free_slot() { # → lowest slot ≥ 1 held by nobody (discovered, registry, or the account list)
  local s=1
  while slot_holder "$s" >/dev/null || acc_has_slot "$s"; do s=$((s + 1)); done
  printf '%s' "$s"
}

# add <email> [--slot N]: register in REG_* (slug assigned with the other new emails). Already registered → no-op.
apply_add() {
  local idx="" slot holder
  idx=$(reg_index_for "$EMAIL_ARG") || idx=""
  if [ -n "$idx" ] && [ -n "${REG_SLOTS[$idx]}" ]; then
    if [ -n "$SLOT_ARG" ] && [ "$SLOT_ARG" != "${REG_SLOTS[$idx]}" ]; then
      note "$EMAIL_ARG is already registered in slot ${REG_SLOTS[$idx]}; --slot $SLOT_ARG ignored"
    else
      note "$EMAIL_ARG is already registered (slot ${REG_SLOTS[$idx]}, launcher claude-${REG_SLUGS[$idx]}); nothing to add"
    fi
    return 0
  fi
  if [ -n "$SLOT_ARG" ]; then
    if holder=$(slot_holder "$SLOT_ARG"); then die "slot $SLOT_ARG is already taken by $holder"; fi
    slot=$SLOT_ARG
  else
    slot=$(lowest_free_slot)
  fi
  if [ -n "$idx" ]; then
    REG_SLOTS[$idx]=$slot                    # v1 row (slug known, no slot) gains its slot
  else
    REG_SLOTS[${#REG_SLOTS[@]}]=$slot
    REG_EMAILS[${#REG_EMAILS[@]}]=$EMAIL_ARG
    REG_SLUGS[${#REG_SLUGS[@]}]=""
  fi
  note "register $EMAIL_ARG in slot $slot"
}

# remove <email>: drop the row. The dir is kept; the email is excluded from this run's list (REMOVED_EMAIL).
apply_remove() {
  local i n=0 keep_slots=() keep_emails=() keep_slugs=()
  i=$(reg_index_for "$EMAIL_ARG") || die "$EMAIL_ARG is not registered in $REGISTRY_FILE (see: $(self_cmd) status)"
  REMOVED_SLUG=${REG_SLUGS[$i]}
  i=0
  while [ $i -lt ${#REG_EMAILS[@]} ]; do
    if [ "${REG_EMAILS[$i]}" != "$EMAIL_ARG" ]; then
      keep_slots[$n]=${REG_SLOTS[$i]}; keep_emails[$n]=${REG_EMAILS[$i]}; keep_slugs[$n]=${REG_SLUGS[$i]}
      n=$((n + 1))
    fi
    i=$((i + 1))
  done
  REG_SLOTS=(); REG_EMAILS=(); REG_SLUGS=()
  i=0
  while [ $i -lt $n ]; do
    REG_SLOTS[$i]=${keep_slots[$i]}; REG_EMAILS[$i]=${keep_emails[$i]}; REG_SLUGS[$i]=${keep_slugs[$i]}
    i=$((i + 1))
  done
  note "forget $EMAIL_ARG (row removed from $REGISTRY_FILE)"
}

# ---------- the account list: discovered ∪ registry rows with a slot (step 3 of §4) ----------
SLOTS=()
EMAILS=()
SLUGS=()      # '-' until assign_slugs runs
acc_has_email() { local i=0; while [ $i -lt ${#EMAILS[@]} ]; do [ "${EMAILS[$i]}" = "$1" ] && return 0; i=$((i + 1)); done; return 1; }
acc_has_slot()  { local i=0; while [ $i -lt ${#SLOTS[@]} ];  do [ "${SLOTS[$i]}" = "$1" ]  && return 0; i=$((i + 1)); done; return 1; }
acc_add() { # slot email slug
  SLOTS[${#SLOTS[@]}]=$1; EMAILS[${#EMAILS[@]}]=$2; SLUGS[${#SLUGS[@]}]=$3
}

REGISTRY_CONTRIBUTED=0
build_accounts() {
  local i s slug email order
  SLOTS=(); EMAILS=(); SLUGS=()
  i=0
  while [ $i -lt ${#DISC_EMAILS[@]} ]; do
    slug=$(registry_slug_for "${DISC_EMAILS[$i]}") || slug='-'
    acc_add "${DISC_SLOTS[$i]}" "${DISC_EMAILS[$i]}" "$slug"
    i=$((i + 1))
  done
  # registry rows that carry a slot, in slot order; a slot already taken by a discovered account moves down
  order=""
  i=0
  while [ $i -lt ${#REG_EMAILS[@]} ]; do
    [ -n "${REG_SLOTS[$i]}" ] && order="$order${REG_SLOTS[$i]} $i
"
    i=$((i + 1))
  done
  [ -n "$order" ] || return 0
  while read -r s i; do
    [ -n "$s" ] || continue
    email=${REG_EMAILS[$i]}
    [ "$email" = "$REMOVED_EMAIL" ] && continue
    acc_has_email "$email" && continue
    if acc_has_slot "$s"; then
      s=$(lowest_free_slot)
      note "slot ${REG_SLOTS[$i]} of $email is taken by $(slot_holder "${REG_SLOTS[$i]}"); moved to slot $s"
    fi
    slug=${REG_SLUGS[$i]}; [ -n "$slug" ] || slug='-'
    acc_add "$s" "$email" "$slug"
    REGISTRY_CONTRIBUTED=1
  done <<EOF
$(printf '%s' "$order" | sort -n)
EOF
  sort_accounts
}

sort_accounts() { # SLOTS/EMAILS/SLUGS → sorted by slot
  local lines="" i s_slots=() s_emails=() s_slugs=() n=0 s idx
  i=0
  while [ $i -lt ${#SLOTS[@]} ]; do
    lines="$lines${SLOTS[$i]} $i
"
    i=$((i + 1))
  done
  [ -n "$lines" ] || return 0
  while read -r s idx; do
    [ -n "$s" ] || continue
    s_slots[$n]=${SLOTS[$idx]}; s_emails[$n]=${EMAILS[$idx]}; s_slugs[$n]=${SLUGS[$idx]}
    n=$((n + 1))
  done <<EOF
$(printf '%s' "$lines" | sort -n)
EOF
  SLOTS=(); EMAILS=(); SLUGS=()
  i=0
  while [ $i -lt $n ]; do
    SLOTS[$i]=${s_slots[$i]}; EMAILS[$i]=${s_emails[$i]}; SLUGS[$i]=${s_slugs[$i]}
    i=$((i + 1))
  done
}

# ---------- interactive prompt (step 4 of §4) ----------
prompt_allowed() { # → 0 when a prompt may be shown; sets PROMPT_IN (file|tty|stdin)
  [ "$NO_INPUT" = 1 ] && return 1
  if [ -n "${CLAUDE_MULTI_INPUT:-}" ]; then PROMPT_IN="file"; return 0; fi   # internal test hook (header)
  if ( : < /dev/tty ) 2>/dev/null; then PROMPT_IN="tty"; return 0; fi
  if [ -t 0 ]; then PROMPT_IN="stdin"; return 0; fi
  return 1
}
PROMPT_IN=""
INPUT_FD_OPEN=0
ANSWER=""
ask() { # prompt-text → ANSWER (rc 1 on EOF). Every interactive prompt goes through here (§4 step 4, §12.4).
  local rc
  ANSWER=""
  case "$PROMPT_IN" in
    file) # answers consumed line by line across prompts: one descriptor, opened once
      if [ "$INPUT_FD_OPEN" = 0 ]; then
        exec 3< "$CLAUDE_MULTI_INPUT" || return 1
        INPUT_FD_OPEN=1
      fi
      read -r ANSWER <&3; rc=$?
      # at EOF nothing is asked; otherwise prompt + answer are echoed so the transcript reads like a terminal session
      { [ $rc = 0 ] || [ -n "$ANSWER" ]; } && printf '%s%s\n' "$1" "$ANSWER" ;;
    tty)
      printf '%s' "$1" > /dev/tty
      read -r ANSWER < /dev/tty; rc=$? ;;
    *)
      printf '%s' "$1" >&2
      read -r ANSWER; rc=$? ;;
  esac
  [ $rc = 0 ] || [ -z "$ANSWER" ] || rc=0   # a last line without a newline is still an answer
  return $rc
}
prompt_rows() { # asks for emails until an empty line; fills SLOTS/EMAILS/SLUGS with slots 1..n
  local n=1 line
  say "Enter the email of each Claude account, one per line; empty line to finish:"
  while :; do
    ask "  $n> " || { say ""; break; }
    line=$ANSWER
    line=${line#"${line%%[! ]*}"}; line=${line%"${line##*[! ]}"}   # trim spaces
    [ -n "$line" ] || break
    if ! [[ "$line" =~ $EMAIL_RE ]]; then note "not an email: $line"; continue; fi
    if acc_has_email "$line"; then note "$line already listed"; continue; fi
    acc_add "$n" "$line" '-'
    n=$((n + 1))
  done
}

# ---------- slugs (stable via the registry) ----------
slug_taken() {
  local i=0
  while [ $i -lt ${#TAKEN[@]} ]; do
    [ "${TAKEN[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  return 1
}
slugify() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'; }

NEW_IDX=()
BASES=()
CANDS=()
assign_slugs() { # new emails get: local part, then +first domain label, then +slot. Known emails keep theirs.
  local i j n email domain label base cand collide
  NEW_IDX=(); BASES=(); CANDS=()
  i=0
  while [ $i -lt ${#EMAILS[@]} ]; do
    [ "${SLUGS[$i]}" = '-' ] && NEW_IDX[${#NEW_IDX[@]}]=$i
    i=$((i + 1))
  done
  [ ${#NEW_IDX[@]} -gt 0 ] || return 0
  # pass 1: base = local part; collision (with anything taken or another new base) → append first domain label
  n=0
  while [ $n -lt ${#NEW_IDX[@]} ]; do
    i=${NEW_IDX[$n]}; email=${EMAILS[$i]}
    BASES[$n]=$(slugify "${email%%@*}")
    [ -n "${BASES[$n]}" ] || BASES[$n]=acct      # a local part made only of ._%+- slugifies to nothing
    n=$((n + 1))
  done
  n=0
  while [ $n -lt ${#NEW_IDX[@]} ]; do
    i=${NEW_IDX[$n]}; email=${EMAILS[$i]}; base=${BASES[$n]}
    collide=0
    slug_taken "$base" && collide=1
    j=0
    while [ $j -lt ${#NEW_IDX[@]} ]; do
      [ $j != $n ] && [ "${BASES[$j]}" = "$base" ] && collide=1
      j=$((j + 1))
    done
    if [ $collide = 1 ]; then
      domain=${email#*@}; label=$(slugify "${domain%%.*}")
      CANDS[$n]="$base-$label"
    else
      CANDS[$n]=$base
    fi
    n=$((n + 1))
  done
  # pass 2: still ambiguous → append the slot number
  n=0
  while [ $n -lt ${#NEW_IDX[@]} ]; do
    i=${NEW_IDX[$n]}; cand=${CANDS[$n]}
    collide=0
    slug_taken "$cand" && collide=1
    j=0
    while [ $j -lt ${#NEW_IDX[@]} ]; do
      [ $j != $n ] && [ "${CANDS[$j]}" = "$cand" ] && collide=1
      j=$((j + 1))
    done
    [ $collide = 1 ] && cand="$cand-${SLOTS[$i]}"
    slug_taken "$cand" && die "cannot find a free slug for ${EMAILS[$i]} (tried $cand)"
    SLUGS[$i]=$cand
    TAKEN[${#TAKEN[@]}]=$cand
    n=$((n + 1))
  done
}

# Rewritten in full whenever the content changes: every account (slot order), then v1 rows (slug memory only).
write_registry() {
  local i
  mk_tmp
  {
    printf '%s\n' "$REGISTRY_HEADER"
    i=0
    while [ $i -lt ${#SLOTS[@]} ]; do
      printf '%s\t%s\t%s\n' "${SLOTS[$i]}" "${EMAILS[$i]}" "${SLUGS[$i]}"
      i=$((i + 1))
    done
    i=0
    while [ $i -lt ${#REG_EMAILS[@]} ]; do
      if [ -z "${REG_SLOTS[$i]}" ] && [ -n "${REG_SLUGS[$i]}" ] && ! acc_has_email "${REG_EMAILS[$i]}"; then
        printf '%s\t%s\n' "${REG_EMAILS[$i]}" "${REG_SLUGS[$i]}"
      fi
      i=$((i + 1))
    done
  } > "$TMP_DIR/accounts.tsv" || die "cannot generate the registry"
  install_file "$TMP_DIR/accounts.tsv" "$REGISTRY_FILE" 644 "$REGISTRY_FILE (${#SLOTS[@]} account(s))"
}

# ---------- aliases.sh (§6): one file for zsh and bash, no arrays, printf only ----------
gen_aliases() { # → stdout
  local i slugw=6 emailw=8 v
  i=0
  while [ $i -lt ${#SLUGS[@]} ]; do
    v=${#SLUGS[$i]};  [ "$v" -gt "$slugw" ]  && slugw=$v
    v=${#EMAILS[$i]}; [ "$v" -gt "$emailw" ] && emailw=$v
    i=$((i + 1))
  done
  cat <<HEAD
# ~/.claude-multi/aliases.sh — GENERATED by ~/.claude-multi/claude-multi-setup.sh (claude-multi $VERSION).
# Do not edit; re-run the script (or \`claude-multi-setup.sh add|remove <email>\`). Sourced by zsh and bash.
#
# One Claude Code login per terminal. Every account owns a CLAUDE_CONFIG_DIR under ~/.claude-accounts, which
# relocates the whole ~/.claude tree, .claude.json AND the macOS Keychain credential entry. ~/.claude itself is
# untouched and stays the default account.
#
#   claude-<slug> [args…]   run Claude Code as that account, for this command only, with the shared
#                           ~/.claude-shared/settings.json + mcp.json and ANTHROPIC_API_KEY removed
#   claude<N>               the same launchers, by slot number
#   cuse <slug|slot>        pin THIS terminal: exports CLAUDE_CONFIG_DIR so bare \`claude\`, \`claude mcp add\`
#                           and scripts use that account too (they do not get the shared-config flags)
#   cuse default            unpin: back to ~/.claude, whatever the default login is
#   cwho                    which account this terminal is on, and the full list with login state
#   claude-multi <verb>     umbrella: use/who (= cuse/cwho, in THIS shell), help, and add | remove | status |
#                           login | update | setup | relink … passed to ~/.claude-multi/claude-multi-setup.sh
#
# cuse also exports CLAUDE_MULTI_ACCOUNT=<slug> (for a prompt: \${CLAUDE_MULTI_ACCOUNT:+[\$CLAUDE_MULTI_ACCOUNT] });
# cuse default unsets it. Sourcing this file sets neither variable.

CLAUDE_MULTI_ACCOUNTS_ROOT="\$HOME/.claude-accounts"
CLAUDE_MULTI_SHARED_DIR="\$HOME/.claude-shared"
CLAUDE_MULTI_SETUP="\$HOME/.claude-multi/claude-multi-setup.sh"
# bash only expands aliases in interactive shells unless told otherwise; zsh skips this line (no BASH_VERSION).
[ -n "\${BASH_VERSION:-}" ] && shopt -s expand_aliases

HEAD
  # the account table: 'slot slug email' lines, slot order
  if [ ${#SLUGS[@]} = 0 ]; then
    printf '_claude_multi_accounts() { :; }\n'
  else
    printf '_claude_multi_accounts() {\n  printf '"'"'%%s\\n'"'"' \\\n'
    i=0
    while [ $i -lt ${#SLUGS[@]} ]; do
      printf "    '%s %s %s'" "${SLOTS[$i]}" "${SLUGS[$i]}" "${EMAILS[$i]}"
      i=$((i + 1))
      if [ $i -lt ${#SLUGS[@]} ]; then printf ' \\\n'; else printf '\n'; fi
    done
    printf '}\n'
  fi
  sed -e "s/@SLUGW@/$slugw/g" -e "s/@EMAILW@/$emailw/g" <<'BODY'

_claude_multi_find() { # <slug|slot> → the matching 'slot slug email' line, or nothing
  local slot slug email   # zsh runs the last pipeline stage in the CURRENT shell: without this the loop sets globals
  _claude_multi_accounts | while read -r slot slug email; do
    if [ "$slug" = "$1" ] || [ "$slot" = "$1" ]; then
      printf '%s %s %s\n' "$slot" "$slug" "$email"
      break
    fi
  done
}

_claude_multi_logged_in() { # <slug>
  [ -f "$CLAUDE_MULTI_ACCOUNTS_ROOT/$1/.claude.json" ] \
    && grep -q '"oauthAccount"' "$CLAUDE_MULTI_ACCOUNTS_ROOT/$1/.claude.json" 2>/dev/null
}

_claude_multi_list() {
  local slot slug email state mark
  printf '%s\n' 'Accounts (slot · launcher · email · login):'
  _claude_multi_accounts | while read -r slot slug email; do
    [ -n "$slot" ] || continue
    if _claude_multi_logged_in "$slug"; then
      state='logged in'
    else
      state="NOT logged in → run claude-multi login $slug"
    fi
    mark=' '
    [ "${CLAUDE_CONFIG_DIR:-}" = "$CLAUDE_MULTI_ACCOUNTS_ROOT/$slug" ] && mark='*'
    printf '  %s %s  claude-%-@SLUGW@s  %-@EMAILW@s  %s\n' "$mark" "$slot" "$slug" "$email" "$state"
  done
}

_claude_multi_run() { # <slug> [args…]
  local slug="$1" dir bin
  shift
  dir="$CLAUDE_MULTI_ACCOUNTS_ROOT/$slug"
  if [ -n "${ZSH_VERSION:-}" ]; then bin=$(whence -p claude 2>/dev/null); else bin=$(type -P claude 2>/dev/null); fi
  if [ -z "$bin" ]; then
    printf '%s\n' "claude-multi: 'claude' is not in PATH" >&2
    return 127
  fi
  if [ ! -d "$dir" ]; then
    printf '%s\n' "claude-multi: $dir is missing — re-run $CLAUDE_MULTI_SETUP" >&2
    return 1
  fi
  (
    # ANTHROPIC_API_KEY outranks the subscription login in credential precedence: never let it bill the API.
    # CLAUDE_CODE_OAUTH_TOKEN / ANTHROPIC_AUTH_TOKEN override the directory's login the same way.
    unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN
    export CLAUDE_CONFIG_DIR="$dir"
    # Root options must precede any subcommand, and --settings sits right after the VARIADIC --mcp-config so it
    # terminates that list instead of a user argument being swallowed.
    exec "$bin" --mcp-config "$CLAUDE_MULTI_SHARED_DIR/mcp.json" --settings "$CLAUDE_MULTI_SHARED_DIR/settings.json" "$@"
  )
}

cuse() { # <slug|slot|default>
  local want="${1:-}" line rest slot slug email
  if [ -z "$want" ]; then
    printf '%s\n' 'usage: cuse <slug|slot|default>' >&2
    _claude_multi_list >&2
    return 2
  fi
  case "$want" in
    default | off | -)
      unset CLAUDE_CONFIG_DIR CLAUDE_MULTI_ACCOUNT
      printf '%s\n' 'This terminal: default (~/.claude)'
      return 0 ;;
  esac
  line=$(_claude_multi_find "$want")
  if [ -z "$line" ]; then
    printf "cuse: no account '%s'\n" "$want" >&2
    _claude_multi_list >&2
    return 1
  fi
  slot=${line%% *}; rest=${line#* }; slug=${rest%% *}; email=${rest#* }
  export CLAUDE_CONFIG_DIR="$CLAUDE_MULTI_ACCOUNTS_ROOT/$slug"
  export CLAUDE_MULTI_ACCOUNT="$slug"
  printf '%s\n' "This terminal: $slug ($email)  CLAUDE_CONFIG_DIR=$CLAUDE_CONFIG_DIR"
  _claude_multi_logged_in "$slug" || printf '%s\n' "  not logged in yet: run  claude-multi login $slug"
  [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && printf '%s\n' "  note: ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN is set in this shell — bare 'claude' will use it over the login; claude-$slug unsets them"
  return 0
}

cwho() {
  local cur="${CLAUDE_CONFIG_DIR:-}" line rest slug email
  case "$cur" in
    '')
      printf '%s\n' 'This terminal: default — ~/.claude (whatever the default login is)' ;;
    "$CLAUDE_MULTI_ACCOUNTS_ROOT"/*)
      slug=${cur#"$CLAUDE_MULTI_ACCOUNTS_ROOT"/}; slug=${slug%%/*}
      line=$(_claude_multi_find "$slug")
      if [ -n "$line" ]; then
        rest=${line#* }; email=${rest#* }
        printf '%s\n' "This terminal: $slug ($email)  CLAUDE_CONFIG_DIR=$cur"
      else
        printf '%s\n' "This terminal: CLAUDE_CONFIG_DIR=$cur (not managed by claude-multi)"
      fi ;;
    *)
      printf '%s\n' "This terminal: CLAUDE_CONFIG_DIR=$cur (not managed by claude-multi)" ;;
  esac
  [ -n "${ANTHROPIC_API_KEY:-}${ANTHROPIC_AUTH_TOKEN:-}${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && printf '%s\n' "  note: ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN / CLAUDE_CODE_OAUTH_TOKEN is set in this shell — bare 'claude' uses it over the login; the claude-<slug> launchers unset them"
  _claude_multi_list
  return 0
}

claude-multi() { # <verb> [args…] — a function, so `use` can change THIS shell's environment
  local verb="${1:-help}"
  case "$verb" in
    use) shift; cuse "$@" ;;
    who) cwho ;;
    help | -h | --help)
      printf '%s\n' \
        'claude-multi <verb> [args…] — one Claude Code login per terminal' \
        '' \
        '  use <slug|slot>       pin this terminal to that account (exports CLAUDE_CONFIG_DIR + CLAUDE_MULTI_ACCOUNT)' \
        '  use default           unpin: back to ~/.claude' \
        '  who                   which account this terminal is on, and every account with its login state' \
        '  status [--verify]     read-only report; --verify asks claude auth status per account' \
        '  login <slug|slot|email> | --all   log in to that account (opens the browser), or every account not yet logged in' \
        '  add <email> [--slot N]            register an account and create its dir + launcher' \
        '  remove <email>        forget an account (its dir and login are kept)' \
        '  setup [--dry-run] [--rc[=FILE]] [--no-input]   re-run the setup (discover, seed, link, aliases)' \
        '  relink                only (re)create the shared + memory symlinks (= setup --relink)' \
        '  update [--dry-run]    fetch the latest claude-multi-setup.sh from GitHub and re-run setup' \
        '  help                  this table' \
        '' \
        "  launchers: claude-<slug> [args…] (or claude<slot>) run Claude Code as that account for one command." \
        "  script: $CLAUDE_MULTI_SETUP"
      return 0 ;;
    *)
      if [ ! -x "$CLAUDE_MULTI_SETUP" ]; then
        printf '%s\n' "claude-multi: $CLAUDE_MULTI_SETUP is missing — re-run the setup script (or install.sh)" >&2
        return 1
      fi
      if [ "$verb" = relink ]; then shift; "$CLAUDE_MULTI_SETUP" setup --relink "$@"
      else "$CLAUDE_MULTI_SETUP" "$@"
      fi ;;
  esac
}

BODY
  i=0
  while [ $i -lt ${#SLUGS[@]} ]; do
    printf 'claude-%s() { _claude_multi_run %s "$@"; }\n' "${SLUGS[$i]}" "${SLUGS[$i]}"
    i=$((i + 1))
  done
  i=0
  while [ $i -lt ${#SLUGS[@]} ]; do
    printf "alias claude%s='claude-%s'\n" "${SLOTS[$i]}" "${SLUGS[$i]}"
    i=$((i + 1))
  done
}

write_aliases() {
  mk_tmp
  gen_aliases > "$TMP_DIR/aliases.sh" || die "cannot generate aliases"
  install_file "$TMP_DIR/aliases.sh" "$ALIASES_FILE" 644 "$ALIASES_FILE"
}

# Legacy v1: a generated aliases.zsh becomes a one-line shim so a v1 rc line keeps working.
write_legacy_shim() {
  [ -f "$LEGACY_ALIASES_FILE" ] || return 0
  grep -q 'GENERATED' -- "$LEGACY_ALIASES_FILE" 2>/dev/null || return 0
  mk_tmp
  printf '%s  # GENERATED by claude-multi %s: legacy shim, the launchers now live in aliases.sh\n' "$RC_LINE" "$VERSION" \
    > "$TMP_DIR/aliases.zsh" || die "cannot generate the legacy shim"
  install_file "$TMP_DIR/aliases.zsh" "$LEGACY_ALIASES_FILE" 644 "$LEGACY_ALIASES_FILE as a shim for aliases.sh"
}

# ---------- self-install (§7) ----------
self_install() {
  [ "$SCRIPT_PATH" = "$INSTALL_PATH" ] && return 0
  [ -e "$INSTALL_PATH" ] && [ "$SCRIPT_PATH" -ef "$INSTALL_PATH" ] && return 0
  [ -f "$SCRIPT_PATH" ] || { warn "cannot find the running script at $SCRIPT_PATH; not installed to $INSTALL_PATH"; return 0; }
  # Fed on stdin (`curl … | bash`, `bash -c "$(…)"`) $0 is `bash` and resolves to the bash BINARY: never copy that.
  grep -q '^SCRIPT_NAME="claude-multi-setup.sh"$' -- "$SCRIPT_PATH" 2>/dev/null \
    || { warn "running from a pipe or an unknown path ($SCRIPT_PATH); not installed to $INSTALL_PATH — use install.sh, or copy the script there yourself"; return 0; }
  if [ -f "$INSTALL_PATH" ] && cmp -s -- "$SCRIPT_PATH" "$INSTALL_PATH"; then return 0; fi
  did "install script to $INSTALL_PATH"
  dry && return 0
  { cp -- "$SCRIPT_PATH" "$INSTALL_PATH.tmp" && chmod 755 "$INSTALL_PATH.tmp" && mv -f -- "$INSTALL_PATH.tmp" "$INSTALL_PATH"; } \
    || die "cannot install to $INSTALL_PATH"
}

# ---------- rc line (§7) ----------
rc_target() { # → the rc file for --rc (FILE, else by $SHELL); rc 1 for an unknown shell
  if [ -n "$RC_FILE_ARG" ]; then
    case "$RC_FILE_ARG" in /*) printf '%s' "$RC_FILE_ARG" ;; *) printf '%s/%s' "$PWD" "$RC_FILE_ARG" ;; esac
    return 0
  fi
  case "${SHELL:-}" in
    *zsh)  printf '%s' "${ZDOTDIR:-$HOME}/.zshrc" ;;
    *bash) printf '%s' "$HOME/.bashrc" ;;
    *) return 1 ;;
  esac
}
rc_has_line() { [ -f "$1" ] && grep -qF -- "$RC_MARKER" "$1"; }
rc_remember() { # target → record it in rc-file once (one path per line)
  [ -f "$RC_MEMO_FILE" ] && grep -qxF -- "$1" "$RC_MEMO_FILE" && return 0
  printf '%s\n' "$1" >> "$RC_MEMO_FILE"
}
rc_found() { # → the first rc file that already carries the line: remembered ones, the $SHELL target, then the usual files
  local f
  if [ -s "$RC_MEMO_FILE" ]; then
    while IFS= read -r f; do
      [ -n "$f" ] && rc_has_line "$f" && { printf '%s' "$f"; return 0; }
    done < "$RC_MEMO_FILE"
  fi
  for f in "$(rc_target 2>/dev/null)" "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    [ -n "$f" ] && rc_has_line "$f" && { printf '%s' "$f"; return 0; }
  done
  return 1
}

# macOS terminals open LOGIN shells, which read ~/.bash_profile and never ~/.bashrc unless the profile chains to it.
rc_login_shell_note() { # target → a note when a bash login shell on macOS would not read it
  local f
  [ "$1" = "$HOME/.bashrc" ] || return 0
  [ "$(uname -s 2>/dev/null)" = Darwin ] || return 0
  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
    [ -f "$f" ] && grep -q 'bashrc' -- "$f" 2>/dev/null && return 0
  done
  printf '%s' " (macOS terminals open login shells, which read ~/.bash_profile, not ~/.bashrc: add '[ -f ~/.bashrc ] && . ~/.bashrc' to ~/.bash_profile, or re-run with --rc=$HOME/.bash_profile)"
}

RC_STATE=""
handle_rc() {
  local target found
  if ! target=$(rc_target); then
    RC_STATE="not appended (unknown shell '${SHELL:-}'). Add this line to your shell's rc file, or re-run with --rc=FILE — the claude-<slug> launchers, cuse and cwho exist only in a terminal that has sourced $ALIASES_FILE:
    $RC_LINE"
    return 0
  fi
  if [ "$RC_APPEND" = 1 ]; then
    # --rc means "this target": append here even if another rc file already has the line (a user with both shells wants both)
    if rc_has_line "$target"; then
      RC_STATE="sourced from $target$(rc_login_shell_note "$target")"
      return 0
    fi
    did "append the source line to $target"
    dry || printf '\n%s\n' "$RC_LINE" >> "$target" || die "cannot append to $target"
    dry || rc_remember "$target" || die "cannot write $RC_MEMO_FILE"
    RC_STATE="source line appended to $target (open a new terminal, or: . $ALIASES_FILE)$(rc_login_shell_note "$target")"
    return 0
  fi
  if found=$(rc_found); then
    RC_STATE="sourced from $found$(rc_login_shell_note "$found")"
    return 0
  fi
  # the §12.4 offer follows the summary under exactly these conditions: say so instead of "add it by hand"
  if ! dry && { [ "$CMD" = setup ] || [ "$CMD" = add ]; } && prompt_allowed; then
    RC_STATE="not sourced yet (asked below)"
    return 0
  fi
  RC_STATE="NOT touched. Add this line to $target (or re-run with --rc), then open a new terminal or run: . $ALIASES_FILE — the claude-<slug> launchers, cuse and cwho exist only after that:
    $RC_LINE"
}

# ---------- summary (§8) ----------
summary() {
  local i slugw=6 emailw=8 v
  say ""
  if [ "$CHANGES" = 0 ]; then say "No changes — everything was already in place."; say ""; fi
  [ "$WARNINGS" = 0 ] || { say "$WARNINGS warning(s) above."; say ""; }
  if [ -n "$REMOVED_EMAIL" ]; then
    say "Removed $REMOVED_EMAIL from the account list. Its dir $ACCOUNTS_ROOT/${REMOVED_SLUG:-<slug>} and its login are KEPT (this script never deletes an account dir; remove it yourself if you want it gone)."
    [ "$REMOVED_SEEN" = 1 ] && say "  note: cswap still lists $REMOVED_EMAIL — it will come back on the next run until it is removed there too."
    say ""
  fi
  i=0
  while [ $i -lt ${#SLUGS[@]} ]; do
    v=${#SLUGS[$i]};  [ "$v" -gt "$slugw" ]  && slugw=$v
    v=${#EMAILS[$i]}; [ "$v" -gt "$emailw" ] && emailw=$v
    i=$((i + 1))
  done
  say "Accounts (source: $DISCOVERY_SOURCE):"
  i=0
  while [ $i -lt ${#SLOTS[@]} ]; do
    printf "  %s  claude-%-${slugw}s  %-${emailw}s  %s\n" "${SLOTS[$i]}" "${SLUGS[$i]}" "${EMAILS[$i]}" "$ACCOUNTS_ROOT/${SLUGS[$i]}"
    i=$((i + 1))
  done
  [ ${#SLOTS[@]} -gt 0 ] || note "(none)"
  say ""
  say "Shared config: $SHARED_DIR (settings.json + mcp.json via flags; CLAUDE.md, commands/, agents/, skills/, output-styles/ symlinked)"
  say "Shared memory: $SEED_DIR/projects/<repo>/memory, linked from each account's projects/<repo>/memory (re-run or --relink after a new repo gets memory)"
  say "Aliases: $ALIASES_FILE"
  say "rc file: $RC_STATE"
  say ""
  say "One-time login, once per account (opens the browser; the credential lands in that dir's own Keychain entry):"
  i=0
  while [ $i -lt ${#SLOTS[@]} ]; do
    if logged_in "${SLUGS[$i]}"; then
      printf "  claude-multi login %-${slugw}s  (already logged in)\n" "${SLUGS[$i]}"
    else
      printf "  claude-multi login %-${slugw}s  (%s)\n" "${SLUGS[$i]}" "${EMAILS[$i]}"
    fi
    i=$((i + 1))
  done
  [ ${#SLOTS[@]} -gt 0 ] || note "(no accounts — run: $(self_cmd) add <email>)"
}

# ---------- status (§8): read-only, no discovery, no network ----------
cmd_status() {
  local i target cur slug state next="" first_missing="" order verified line
  printf 'script: %s\n' "$SCRIPT_PATH"
  printf 'version: %s\n' "$VERSION"
  if target=$(command -v cswap 2>/dev/null); then printf 'cswap: found at %s\n' "$target"; else printf 'cswap: not found (manual account list)\n'; fi
  if [ -d "$SHARED_DIR" ]; then printf 'shared: ok %s\n' "$SHARED_DIR"; else printf 'shared: missing\n'; fi
  if [ -f "$ALIASES_FILE" ]; then printf 'aliases: ok %s\n' "$ALIASES_FILE"; else printf 'aliases: missing\n'; fi
  if target=$(rc_found); then printf 'rc: sourced from %s\n' "$target"; else printf 'rc: not sourced (run --rc)\n'; fi
  settings_credential_warning "$SHARED_DIR/settings.json"
  load_registry
  cur="${CLAUDE_CONFIG_DIR:-}"
  state="unmanaged $cur"
  if [ -z "$cur" ]; then
    state="default"
  else
    case "$cur" in
      "$ACCOUNTS_ROOT"/*)
        slug=${cur#"$ACCOUNTS_ROOT"/}; slug=${slug%%/*}
        i=0
        while [ $i -lt ${#REG_EMAILS[@]} ]; do
          [ "${REG_SLUGS[$i]}" = "$slug" ] && { state="$slug (${REG_EMAILS[$i]})"; break; }
          i=$((i + 1))
        done ;;
    esac
  fi
  printf 'terminal: %s\n' "$state"
  verified=""
  if [ "$VERIFY" = 1 ]; then
    if claude_in_path; then verified=verified
    else warn "claude not in PATH; login states are the .claude.json heuristic"
    fi
  fi
  order=""
  i=0
  while [ $i -lt ${#REG_EMAILS[@]} ]; do
    [ -n "${REG_SLOTS[$i]}" ] && order="$order${REG_SLOTS[$i]} $i
"
    i=$((i + 1))
  done
  while read -r slug i; do
    [ -n "$slug" ] || continue
    line=$(account_state_line "${REG_SLOTS[$i]}" "${REG_SLUGS[$i]}" "${REG_EMAILS[$i]}" "$verified")
    printf '%s\n' "$line"
    case "$line" in *" not-logged-in" | *" not-logged-in (verified)") [ -n "$first_missing" ] || first_missing=${REG_SLUGS[$i]} ;; esac
    next="set"
  done <<EOF
$(printf '%s' "$order" | sort -n)
EOF
  if [ -z "$next" ]; then next="run setup"
  elif [ ! -f "$ALIASES_FILE" ]; then next="run setup"
  elif [ -n "$first_missing" ]; then next="run claude-multi login $first_missing"
  else next="all accounts logged in"
  fi
  printf 'next: %s\n' "$next"
  return 0
}

# ---------- login (§12.2): registry rows with a slot, in slot order ----------
LOGIN_SLOTS=()
LOGIN_SLUGS=()
LOGIN_EMAILS=()
load_login_accounts() { # → LOGIN_* from the registry, slot order
  local i order s
  LOGIN_SLOTS=(); LOGIN_SLUGS=(); LOGIN_EMAILS=()
  load_registry
  order=""
  i=0
  while [ $i -lt ${#REG_EMAILS[@]} ]; do
    [ -n "${REG_SLOTS[$i]}" ] && order="$order${REG_SLOTS[$i]} $i
"
    i=$((i + 1))
  done
  [ -n "$order" ] || return 0
  while read -r s i; do
    [ -n "$i" ] || continue
    LOGIN_SLOTS[${#LOGIN_SLOTS[@]}]=${REG_SLOTS[$i]}
    LOGIN_SLUGS[${#LOGIN_SLUGS[@]}]=${REG_SLUGS[$i]}
    LOGIN_EMAILS[${#LOGIN_EMAILS[@]}]=${REG_EMAILS[$i]}
  done <<EOF
$(printf '%s' "$order" | sort -n)
EOF
}
login_account_list() { # → stderr: one line per registered account, for the "no account" error
  local i=0
  if [ ${#LOGIN_SLOTS[@]} = 0 ]; then
    printf '  (no accounts registered — run: %s add <email>)\n' "$(self_cmd)" >&2
    return 0
  fi
  printf '  registered accounts (slot · slug · email):\n' >&2
  while [ $i -lt ${#LOGIN_SLOTS[@]} ]; do
    printf '    %s  %s  %s\n' "${LOGIN_SLOTS[$i]}" "${LOGIN_SLUGS[$i]}" "${LOGIN_EMAILS[$i]}" >&2
    i=$((i + 1))
  done
}
login_index_for() { # slug|slot|email → index, rc 1 if unknown
  local i=0
  while [ $i -lt ${#LOGIN_SLOTS[@]} ]; do
    if [ "${LOGIN_SLUGS[$i]}" = "$1" ] || [ "${LOGIN_SLOTS[$i]}" = "$1" ] || [ "${LOGIN_EMAILS[$i]}" = "$1" ]; then
      printf '%s' "$i"; return 0
    fi
    i=$((i + 1))
  done
  return 1
}
login_needs_terminal() { # exit 2 unless a login can be run interactively (§12.2)
  prompt_allowed && return 0
  printf 'error: login opens a browser and needs a terminal; run: claude-multi login <slug>\n' >&2
  exit 2
}

cmd_login() {
  local i idx line wanted done_any=0
  load_login_accounts
  if [ "$LOGIN_ALL" = 0 ]; then
    if ! idx=$(login_index_for "$LOGIN_ARG"); then
      printf "error: no account '%s'\\n" "$LOGIN_ARG" >&2
      login_account_list
      exit 1
    fi
  fi
  claude_in_path || die "'claude' is not in PATH — install Claude Code (or open a terminal where it is) and re-run: $(self_cmd) login ${LOGIN_ARG:---all}"
  login_needs_terminal
  if dry; then   # a login opens the browser: under --dry-run only say what would run
    say "claude-multi login (dry-run — nothing will be changed)"
    i=0
    while [ $i -lt ${#LOGIN_SLOTS[@]} ]; do
      if [ "$LOGIN_ALL" = 1 ]; then wanted=$(! verified_logged_in "${LOGIN_SLUGS[$i]}" && echo 1 || echo 0)
      elif [ "$i" = "$idx" ]; then wanted=1
      else wanted=0
      fi
      [ "$wanted" = 1 ] && did "run claude auth login --email ${LOGIN_EMAILS[$i]} with CLAUDE_CONFIG_DIR=$ACCOUNTS_ROOT/${LOGIN_SLUGS[$i]}"
      i=$((i + 1))
    done
    return 0
  fi
  if [ "$LOGIN_ALL" = 0 ]; then
    login_account "${LOGIN_SLOTS[$idx]}" "${LOGIN_SLUGS[$idx]}" "${LOGIN_EMAILS[$idx]}" || exit 1
    return 0
  fi
  # --all: every account whose VERIFIED state (claude auth status) is not-logged-in, in slot order, stopping at
  # the first failure. The .claude.json heuristic is not consulted: a stale oauthAccount must not hide a missing
  # login (claude is known to be in PATH here). A skipped account prints the state that skipped it.
  i=0
  while [ $i -lt ${#LOGIN_SLOTS[@]} ]; do
    line=$(account_state_line "${LOGIN_SLOTS[$i]}" "${LOGIN_SLUGS[$i]}" "${LOGIN_EMAILS[$i]}" verified)
    case "$line" in
      *" not-logged-in (verified)") login_account "${LOGIN_SLOTS[$i]}" "${LOGIN_SLUGS[$i]}" "${LOGIN_EMAILS[$i]}" || exit 1; done_any=1 ;;
      *) printf '%s\n' "$line" ;;
    esac
    i=$((i + 1))
  done
  [ ${#LOGIN_SLOTS[@]} -gt 0 ] || { say "no accounts registered — run: $(self_cmd) add <email>"; return 0; }
  [ "$done_any" = 1 ] || say "all accounts logged in"
  return 0
}

# ---------- interactive offers after the summary of setup / add (§12.4) ----------
offer_interactive() {
  local target i asked=0
  dry && return 0
  case "$CMD" in setup | add) ;; *) return 0 ;; esac
  prompt_allowed || return 0
  # 1. the rc line, when it is nowhere yet and --rc was not given (that case was handled above)
  if [ "$RC_APPEND" = 0 ] && ! rc_found >/dev/null && target=$(rc_target); then
    say ""
    if ask "Append the source line to $target? [y/N] "; then
      case "$ANSWER" in
        y | Y | yes)
          did "append the source line to $target"
          printf '\n%s\n' "$RC_LINE" >> "$target" || die "cannot append to $target"
          rc_remember "$target" || die "cannot write $RC_MEMO_FILE"
          say "source line appended to $target (open a new terminal, or: . $ALIASES_FILE)$(rc_login_shell_note "$target")" ;;
        *) say "rc file not touched. Add this line yourself (or re-run with --rc):"; note "$RC_LINE" ;;
      esac
    else
      say ""
      return 0   # EOF: stop asking
    fi
  fi
  # 2. one login offer per account that is not logged in, slot order; EOF stops asking
  i=0
  while [ $i -lt ${#SLOTS[@]} ]; do
    if ! logged_in "${SLUGS[$i]}"; then
      if ! claude_in_path; then
        note "'claude' is not in PATH here, so the logins cannot be offered; run  $(self_cmd) login --all  where it is"
        return 0
      fi
      [ $asked = 1 ] || say ""
      asked=1
      ask "Log in to ${EMAILS[$i]} now? [Y/n] " || { say ""; return 0; }
      case "$ANSWER" in
        '' | y | Y | yes) login_account "${SLOTS[$i]}" "${SLUGS[$i]}" "${EMAILS[$i]}" || note "(later: $(self_cmd) login ${SLUGS[$i]})" ;;
        *) note "skipped ${EMAILS[$i]} (later: $(self_cmd) login ${SLUGS[$i]})" ;;
      esac
    fi
    i=$((i + 1))
  done
}

# ---------- update (§12.5): replace ~/.claude-multi/claude-multi-setup.sh from GitHub ----------
cmd_update() {
  local ref url new old_ver new_ver
  ref=${CLAUDE_MULTI_REF:-main}
  # a plain branch or tag name only (as install.sh): `..` would fetch a file from another repository
  case "$ref" in
    '' | *..* | /* | *[!A-Za-z0-9._/-]*) die "bad CLAUDE_MULTI_REF $ref (expected a branch or tag name)" ;;
  esac
  url=${CLAUDE_MULTI_UPDATE_URL:-https://raw.githubusercontent.com/$UPDATE_REPO/$ref/$UPDATE_PATH}
  mk_tmp
  new="$TMP_DIR/$SCRIPT_NAME"
  note "downloading $url"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$new" || die "download of $url failed (curl)"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- "$url" > "$new" || die "download of $url failed (wget)"
  else
    die "neither curl nor wget is installed; install one of them, or download $url to $INSTALL_PATH by hand"
  fi
  [ -s "$new" ] || die "download of $url produced an empty file (wrong CLAUDE_MULTI_REF?); installed copy untouched"
  # the last line is `main "$@"`: a download cut at any earlier statement boundary still carries the SCRIPT_NAME
  # line and passes bash -n, but would install a script that defines everything and runs nothing
  if ! grep -q '^SCRIPT_NAME="claude-multi-setup.sh"$' -- "$new" || [ "$(tail -n 1 "$new")" != 'main "$@"' ] \
     || ! "${BASH:-bash}" -n "$new" 2>/dev/null; then
    die "downloaded file is not claude-multi-setup.sh; installed copy untouched"
  fi
  new_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$new" | head -n 1); [ -n "$new_ver" ] || new_ver="unknown"
  if [ -f "$INSTALL_PATH" ]; then
    old_ver=$(sed -n 's/^VERSION="\(.*\)"$/\1/p' "$INSTALL_PATH" | head -n 1); [ -n "$old_ver" ] || old_ver="unknown"
    if cmp -s -- "$new" "$INSTALL_PATH"; then say "already up to date ($new_ver)"; return 0; fi
  else
    old_ver="none"
  fi
  did "update $INSTALL_PATH $old_ver → $new_ver"
  if dry; then
    say "  [dry-run] would then run: $INSTALL_PATH setup --no-input"
    return 0
  fi
  ensure_dir "$MULTI_DIR" 755
  { cp -- "$new" "$INSTALL_PATH.tmp" && chmod 755 "$INSTALL_PATH.tmp" && mv -f -- "$INSTALL_PATH.tmp" "$INSTALL_PATH"; } \
    || die "cannot install to $INSTALL_PATH"
  say "updated $INSTALL_PATH: $old_ver → $new_ver; running setup so aliases.sh gains any new functions"
  say ""
  "$INSTALL_PATH" setup --no-input || return $?
  say ""
  say "reload the launchers in this terminal: . $ALIASES_FILE  (new terminals pick them up from the rc line)"
  return 0
}

# ---------- argument parsing ----------
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --relink) RELINK=1 ;;
      --rc) RC_APPEND=1 ;;
      --rc=*) RC_APPEND=1; RC_FILE_ARG=${1#--rc=} ;;
      --no-input) NO_INPUT=1 ;;
      --all) LOGIN_ALL=1 ;;
      --verify) VERIFY=1 ;;
      --slot) shift; [ $# -gt 0 ] || usage_err "--slot needs a number"; SLOT_ARG=$1 ;;
      --slot=*) SLOT_ARG=${1#--slot=} ;;
      -h | --help) usage; exit 0 ;;
      --version) printf '%s\n' "$VERSION"; exit 0 ;;
      -*) usage_err "unknown option: $1" ;;
      setup | add | remove | status | login | update)
        [ -z "$CMD" ] || usage_err "unexpected argument: $1"
        CMD=$1 ;;
      *)
        case "$CMD" in
          add | remove) [ -z "$EMAIL_ARG" ] || usage_err "unexpected argument: $1"; EMAIL_ARG=$1 ;;
          login) [ -z "$LOGIN_ARG" ] || usage_err "unexpected argument: $1"; LOGIN_ARG=$1 ;;
          *) usage_err "unexpected argument: $1" ;;
        esac ;;
    esac
    shift
  done
  [ -n "$CMD" ] || CMD=setup
  case "$CMD" in
    add | remove)
      [ -n "$EMAIL_ARG" ] || usage_err "$CMD needs an email"
      [[ "$EMAIL_ARG" =~ $EMAIL_RE ]] || usage_err "not an email: $EMAIL_ARG"
      [ "$RELINK" = 0 ] || usage_err "--relink cannot be combined with $CMD"
      [ "$CMD" = remove ] && REMOVED_EMAIL=$EMAIL_ARG ;;   # excluded from discovery below, even if cswap lists it
    login)
      if [ "$LOGIN_ALL" = 1 ]; then [ -z "$LOGIN_ARG" ] || usage_err "login takes either <slug|slot|email> or --all, not both"
      elif [ -z "$LOGIN_ARG" ]; then
        # no account named and no terminal: the §12.2 message is more useful than a usage line
        login_needs_terminal
        usage_err "login needs <slug|slot|email> or --all"
      fi
      [ "$RELINK" = 0 ] || usage_err "--relink cannot be combined with login" ;;
    update)
      [ "$RELINK" = 0 ] && [ "$RC_APPEND" = 0 ] || usage_err "update only takes --dry-run" ;;
  esac
  [ "$LOGIN_ALL" = 0 ] || [ "$CMD" = login ] || usage_err "--all only applies to login"
  [ "$VERIFY" = 0 ] || [ "$CMD" = status ] || usage_err "--verify only applies to status"
  if [ -n "$SLOT_ARG" ]; then
    [ "$CMD" = add ] || usage_err "--slot only applies to add"
    [[ "$SLOT_ARG" =~ $SLOT_RE ]] && [ "$SLOT_ARG" -ge 1 ] || usage_err "--slot needs a number ≥ 1, got '$SLOT_ARG'"
  fi
}

# ---------- main ----------
cmd_relink() {
  local d
  say "Relinking shared config into existing account dirs under $ACCOUNTS_ROOT:"
  [ -d "$ACCOUNTS_ROOT" ] || die "$ACCOUNTS_ROOT does not exist yet — run without --relink first"
  ensure_dir "$MULTI_DIR" 755
  seed_shared
  for d in "$ACCOUNTS_ROOT"/*/; do
    [ -d "$d" ] || continue
    d=${d%/}
    note "$d"
    link_shared_into "$d"
    link_memory_into "$d"
  done
  say ""
  if [ "$CHANGES" = 0 ]; then say "No changes — everything was already in place."; else say "Done."; fi
}

cmd_setup() { # also the second half of add / remove
  local i reason
  discover || :
  parse_discovered
  load_registry
  case "$CMD" in
    add) apply_add ;;
    remove) apply_remove ;;
  esac
  build_accounts
  if [ ${#EMAILS[@]} = 0 ] && [ "$CMD" != remove ]; then
    if prompt_allowed; then
      prompt_rows
      DISCOVERY_SOURCE='prompt'
    fi
  fi
  if [ ${#EMAILS[@]} = 0 ] && [ "$CMD" != remove ]; then
    if [ "$NO_INPUT" = 1 ]; then reason="--no-input given"; else reason="no terminal to ask on"; fi
    die "could not find any Claude account.
  cswap: ${CSWAP_STATE:-consulted, nothing usable}; $REGISTRY_FILE: no rows; $reason.
  Three ways out:
    1. ACCOUNT_ROWS=\$'1\\tyou@example.com\\n2\\tyou@work.example' $(self_cmd)    (one 'slot<TAB>email' line per account)
    2. $(self_cmd) add you@example.com
    3. re-run without --no-input in a terminal to be asked for the emails"
  fi
  if [ -z "$DISCOVERY_SOURCE" ]; then
    DISCOVERY_SOURCE='accounts.tsv'
  elif [ "$REGISTRY_CONTRIBUTED" = 1 ]; then
    DISCOVERY_SOURCE="$DISCOVERY_SOURCE + accounts.tsv"
  fi
  assign_slugs

  ensure_dir "$MULTI_DIR" 755
  seed_shared
  [ ${#SLOTS[@]} -gt 0 ] && ensure_dir "$ACCOUNTS_ROOT" 755
  i=0
  while [ $i -lt ${#SLOTS[@]} ]; do
    ensure_dir "$ACCOUNTS_ROOT/${SLUGS[$i]}" 700
    link_shared_into "$ACCOUNTS_ROOT/${SLUGS[$i]}"
    link_memory_into "$ACCOUNTS_ROOT/${SLUGS[$i]}"
    i=$((i + 1))
  done
  write_registry
  write_aliases
  write_legacy_shim
  self_install
  handle_rc
  summary
  offer_interactive
}

main() {
  parse_args "$@"
  case "$CMD" in
    status) cmd_status; exit 0 ;;
    login) cmd_login; exit 0 ;;
  esac
  if dry; then say "claude-multi $CMD (dry-run — nothing will be changed)"; else say "claude-multi $CMD"; fi
  case "$CMD" in
    update) cmd_update; return $? ;;
  esac
  if [ "$RELINK" = 1 ]; then cmd_relink; return 0; fi
  cmd_setup
}

main "$@"
