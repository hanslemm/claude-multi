#!/bin/sh
# claude-multi installer — downloads claude-multi-setup.sh into ~/.claude-multi and runs it.
#
#   curl -fsSL https://raw.githubusercontent.com/hanslemm/claude-multi/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/hanslemm/claude-multi/main/install.sh | sh -s -- --dry-run
#
# CLAUDE_MULTI_REF selects a branch or tag (default: main). Any arguments are passed to the script.
# POSIX sh; the script itself needs bash (3.2 or newer). Interactive prompts read /dev/tty, so piping
# from curl works.

set -eu

REPO=hanslemm/claude-multi
REF=${CLAUDE_MULTI_REF:-main}
# a plain branch or tag name only: curl normalises `..`, which would fetch (and exec) a file from another repository
case $REF in
  ''|*..*|/*|*[!A-Za-z0-9._/-]*) printf 'error: bad CLAUDE_MULTI_REF %s (expected a branch or tag name)\n' "$REF" >&2; exit 1 ;;
esac
URL="https://raw.githubusercontent.com/$REPO/$REF/skills/claude-multi/scripts/claude-multi-setup.sh"
DEST_DIR="$HOME/.claude-multi"
DEST="$DEST_DIR/claude-multi-setup.sh"

printf '%s\n' "claude-multi: downloading claude-multi-setup.sh ($REF) into $DEST_DIR and running it"

mkdir -p "$DEST_DIR"

# Download to a temp file first, then mv into place, so a failed download never leaves a truncated script.
TMP=$(mktemp "$DEST_DIR/.claude-multi-setup.sh.XXXXXX")
trap 'rm -f "$TMP"' EXIT

if command -v curl >/dev/null 2>&1; then
  curl -fsSL "$URL" -o "$TMP"
elif command -v wget >/dev/null 2>&1; then
  wget -q -O "$TMP" "$URL"
else
  printf '%s\n' "error: neither curl nor wget is installed; install one of them, or download $URL to $DEST by hand." >&2
  exit 1
fi

if [ ! -s "$TMP" ]; then
  printf '%s\n' "error: download of $URL produced an empty file (wrong CLAUDE_MULTI_REF?)." >&2
  exit 1
fi

chmod 755 "$TMP"
mv -f "$TMP" "$DEST"
trap - EXIT

exec "$DEST" "$@"
