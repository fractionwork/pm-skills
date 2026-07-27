#!/usr/bin/env bash
# Fallback installer: symlinks pm-kit's skills (plus the `_shared` runtime) into
# ~/.claude/skills so any Claude Code session discovers them without the plugin
# mechanism. Prefer the plugin install (see README.md); use this for a quick local
# setup from a checkout of this repo.
#
# NOTE — this path does NOT register the Asana MCP server. `.mcp.json` is read by
# the plugin loader, and nothing reads it when the skills are merely symlinked.
# The skills still work: they fall back to asana_ops.py, which is the documented
# behaviour for "MCP not connected". To get the MCP too, install the plugin.
#
# Usage: ./install.sh [--uninstall]

set -euo pipefail

KIT_DIR="$(SRC="${BASH_SOURCE[0]}"; while [ -h "$SRC" ]; do D="$(cd -P "$(dirname "$SRC")" && pwd)"; SRC="$(readlink "$SRC")"; case $SRC in /*) ;; *) SRC="$D/$SRC" ;; esac; done; cd -P "$(dirname "$SRC")" && pwd)"
SKILLS_DEST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}"

UNINSTALL=0
case " $* " in *" --uninstall "*) UNINSTALL=1 ;; esac

mkdir -p "$SKILLS_DEST"

# Loop over EVERY dir under skills/ — `_shared` included, so the relative
# ../_shared paths the skills use stay valid under a symlink install.
for dir in "$KIT_DIR"/skills/*/; do
  name="$(basename "${dir%/}")"
  link="$SKILLS_DEST/$name"
  if [ "$UNINSTALL" = 1 ]; then
    if [ -L "$link" ]; then rm -f "$link"; echo "removed $name"; fi
    continue
  fi
  if [ -e "$link" ] && [ ! -L "$link" ]; then
    echo "skip $name: $link exists and is not a symlink" >&2
    continue
  fi
  ln -sfn "${dir%/}" "$link"
  echo "linked $name"
done

[ "$UNINSTALL" = 1 ] && exit 0

echo
echo "Skills linked into $SKILLS_DEST."
echo "Next: install the Python runtime and authenticate —"
echo "  $KIT_DIR/skills/pm-setup/scripts/pm-setup.sh"
echo
echo "Note: ${CLAUDE_SKILLS_DIR:+CLAUDE_SKILLS_DIR is set; }the Asana MCP server is NOT registered by this"
echo "path — skills will use asana_ops.py directly. Install the plugin for the MCP."
