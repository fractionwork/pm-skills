#!/usr/bin/env bash
# Clean a machine's pre-plugin DevHawk install out of ~/.claude.
#
# The old `curl | bash` installer copied 24 skills, an agent, a Python runtime and
# an MCP registration into ~/.claude, spliced a block into ~/.claude/CLAUDE.md, and
# wrote a SessionStart hook into settings.json. All of that now shadows, duplicates
# or actively breaks the plugin install.
#
# WHY THIS SCRIPT EXISTS: the obvious cleanup — `rm -rf ~/.claude/skills` — destroys
# skills nobody here installed. A real machine had 28 skills in that directory and
# only 24 came from the seed. Everything below is removed BY NAME, and anything not
# on the list is left alone.
#
#   ./migrate-from-installer.sh            # dry run — shows what it WOULD do
#   ./migrate-from-installer.sh --apply    # do it, backing up first
#   ./migrate-from-installer.sh --apply --yes   # no confirmation prompt
#
# It lives in pm-kit because pm-kit is the one plugin everyone installs — PMs and
# engineers alike — and the one published publicly. It cleans up all 24 installer
# skills regardless of which kits you now use, because they all came from the same
# installer.
#
# Idempotent. Safe to re-run. Never touches your Asana credentials.

set -uo pipefail

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_HOME="${CLAUDE_HOME%%:*}"          # CLAUDE_CONFIG_DIR may be a list
APPLY=0
ASSUME_YES=0
BACKUP_DIR="$HOME/claude-preplugin-backup-$(date +%Y%m%d-%H%M%S)"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --backup-dir) BACKUP_DIR="${2:-$BACKUP_DIR}"; shift ;;
    --home) CLAUDE_HOME="${2:-$CLAUDE_HOME}"; shift ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "migrate: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

# The 24 skills the installer shipped. Anything else in skills/ is somebody's own.
SEED_SKILLS="add-card add-comment ado-asana-sync adopt-stack-docs asana-bootstrap
asana-hygiene bootstrap card-done cost-estimate create-pr devhawk-stack do-deploy
feature-build migrate next-task playwright-cli pr-review pr-watch security-brief
seed-data shortcut-hygiene stack-audit test-gen update-seed-skills"
# Collapse to one line: the literal above spans four, and a newline-adjacent entry
# fails a " $x " match — which silently reported six installer skills as "keeping".
SEED_SKILLS="$(echo $SEED_SKILLS)"

# Installer-owned files in scripts/. NOT .asana-token.json / .asana-workspace.json —
# pm-kit still reads those, so removing them logs the user out for no reason.
SEED_SCRIPTS="asana_ops.py asana_mcp.py shortcut_ops.py ado_auth.py ado_asana_sync.py
pr-watch-state.mjs check-skill-deps.mjs requirements-mcp.txt .venv __pycache__"
SEED_SCRIPTS="$(echo $SEED_SCRIPTS)"

say()  { printf '  %s\n' "$1"; }
act()  { printf '  \033[33m→\033[0m %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
skip() { printf '  \033[2m·\033[0m %s\n' "$1"; }

FOUND=0
note_found() { FOUND=$((FOUND + 1)); }

echo
echo "Pre-plugin DevHawk cleanup — $CLAUDE_HOME"
[ "$APPLY" = 1 ] || echo "  (dry run — nothing will change; re-run with --apply)"
echo

# ── 1. skills ───────────────────────────────────────────────────────────────
present=""
for s in $SEED_SKILLS; do
  [ -e "$CLAUDE_HOME/skills/$s" ] && present="$present $s"
done
if [ -n "$present" ]; then
  note_found
  n=$(echo $present | wc -w)
  act "remove $n of the installer's 24 skills"
  echo "$present" | tr ' ' '\n' | grep -v '^$' | sort | paste -sd' ' - \
    | fold -sw 68 | sed 's/^/        /' 
  # Everything NOT on the list — proof we are not touching it.
  if [ -d "$CLAUDE_HOME/skills" ]; then
    keep=$(ls "$CLAUDE_HOME/skills" 2>/dev/null | while read -r d; do
             case " $SEED_SKILLS " in *" $d "*) ;; *) echo "$d" ;; esac; done | tr '\n' ' ')
    [ -n "$keep" ] && say "keeping (not from the installer): $keep"
  fi
else
  skip "skills: none of the installer's 24 present"
fi

# ── 2. agent ────────────────────────────────────────────────────────────────
if [ -f "$CLAUDE_HOME/agents/pr-watch-reviewer.md" ]; then
  note_found; act "remove agents/pr-watch-reviewer.md (ship-kit ships it now)"
else
  skip "agent: already gone"
fi

# ── 3. scripts ──────────────────────────────────────────────────────────────
sp=""
for f in $SEED_SCRIPTS; do
  [ -e "$CLAUDE_HOME/scripts/$f" ] && sp="$sp $f"
done
if [ -n "$sp" ]; then
  note_found; act "remove installer scripts:$sp"
  for c in .asana-token.json .asana-workspace.json; do
    [ -f "$CLAUDE_HOME/scripts/$c" ] && say "keeping $c — pm-kit still reads it, you stay logged in"
  done
else
  skip "scripts: none of the installer's present"
fi

# ── 4. user-scope MCP ───────────────────────────────────────────────────────
# The plugin ships its own `asana` server; two under one name collide.
#
# Read the config rather than parsing `claude mcp list`: that output is health-check
# chatter that varies between runs and lists hosted connectors like
# "claude.ai Asana", which are a DIFFERENT thing and must not be touched. Grepping
# it produced a false positive on a machine that had no user-scope server at all.
mcp_asana_registered() {
  # `claude mcp add --scope user` writes next to the config dir, so check both.
  python3 - "$HOME/.claude.json" "$CLAUDE_HOME/.claude.json" <<'PY' 2>/dev/null
import json, sys
for path in sys.argv[1:]:
    try:
        if "asana" in json.load(open(path)).get("mcpServers", {}):
            sys.exit(0)
    except Exception:
        pass
sys.exit(1)
PY
}

if mcp_asana_registered; then
  note_found; act "unregister the user-scope 'asana' MCP server (pm-kit ships its own)"
  say "the hosted 'claude.ai Asana' connector is a different thing and is left alone"
else
  skip "mcp: no user-scope 'asana' server registered"
fi

# ── 5. the broken SessionStart hook ─────────────────────────────────────────
SETTINGS="$CLAUDE_HOME/settings.json"
if [ -f "$SETTINGS" ] && grep -q 'check-skill-deps' "$SETTINGS" 2>/dev/null; then
  note_found
  act "drop the SessionStart hook calling check-skill-deps.mjs"
  say "it holds an absolute path to a script this removes — it would fail every session"
else
  skip "settings.json: no stale check-skill-deps hook"
fi

# ── 6. the CLAUDE.md block ──────────────────────────────────────────────────
USER_MD="$CLAUDE_HOME/CLAUDE.md"
if [ -f "$USER_MD" ] && grep -q 'BEGIN: fraction-pm-skills' "$USER_MD" 2>/dev/null; then
  note_found
  lines=$(awk '/BEGIN: fraction-pm-skills/{f=1} f{c++} /END: fraction-pm-skills/{f=0} END{print c+0}' "$USER_MD")
  act "remove the ~${lines}-line fraction-pm-skills block from CLAUDE.md"
  say "pm-kit injects those rules from a hook now; two copies drift apart"
  say "anything you wrote outside the markers is untouched"
else
  skip "CLAUDE.md: no installer block"
fi

echo
if [ "$FOUND" = 0 ]; then
  ok "nothing to do — this machine has no pre-plugin install left"
  exit 0
fi

if [ "$APPLY" != 1 ]; then
  echo "  Re-run with --apply to make these changes (a backup is taken first)."
  exit 0
fi

if [ "$ASSUME_YES" != 1 ] && [ -t 0 ]; then
  printf "  Proceed? [y/N] "; read -r reply
  case "$reply" in [yY]*) ;; *) echo "  aborted."; exit 0 ;; esac
fi

# ── back up before touching anything ────────────────────────────────────────
mkdir -p "$BACKUP_DIR"
for p in skills agents scripts settings.json CLAUDE.md; do
  [ -e "$CLAUDE_HOME/$p" ] && cp -R "$CLAUDE_HOME/$p" "$BACKUP_DIR/" 2>/dev/null
done
ok "backed up to $BACKUP_DIR"

for s in $SEED_SKILLS; do rm -rf "${CLAUDE_HOME:?}/skills/$s"; done
rm -f "$CLAUDE_HOME/agents/pr-watch-reviewer.md"
for f in $SEED_SCRIPTS; do rm -rf "${CLAUDE_HOME:?}/scripts/$f"; done
ok "removed the installer's skills, agent and scripts"

if mcp_asana_registered && command -v claude >/dev/null 2>&1; then
  claude mcp remove asana >/dev/null 2>&1 && ok "unregistered the user-scope asana MCP server" \
    || skip "could not remove the asana MCP server — remove it by hand"
fi

if [ -f "$SETTINGS" ] && grep -q 'check-skill-deps' "$SETTINGS" 2>/dev/null; then
  python3 - "$SETTINGS" <<'PY' && ok "removed the stale SessionStart hook"
import json, sys
p = sys.argv[1]
cfg = json.load(open(p))
hooks = cfg.get("hooks", {})
for event, entries in list(hooks.items()):
    kept = []
    for entry in entries:
        inner = [h for h in entry.get("hooks", [])
                 if "check-skill-deps" not in str(h.get("command", ""))]
        if inner:
            entry["hooks"] = inner
            kept.append(entry)
    if kept:
        hooks[event] = kept
    else:
        del hooks[event]
if hooks:
    cfg["hooks"] = hooks
else:
    cfg.pop("hooks", None)
# tmp+replace so an interrupted write can't leave settings.json unparseable
tmp = p + ".tmp"
json.dump(cfg, open(tmp, "w"), indent=2)
open(tmp, "a").write("\n")
import os; os.replace(tmp, p)
PY
fi

if [ -f "$USER_MD" ] && grep -q 'BEGIN: fraction-pm-skills' "$USER_MD" 2>/dev/null; then
  awk '/BEGIN: fraction-pm-skills/{skip=1} !skip{print} /END: fraction-pm-skills/{skip=0}' \
    "$USER_MD" > "$USER_MD.tmp" && mv "$USER_MD.tmp" "$USER_MD"
  ok "removed the fraction-pm-skills block from CLAUDE.md"
fi

echo
ok "done. Next:"
say "1. install the plugins — see docs/claude-plugins.md"
say "2. restart Claude Code"
say "3. /pm-setup --reauth   (the Asana client secret was rotated)"
say "4. in each seed-derived project, remove the seed's copies BY NAME (a blanket"
say "   'rm -rf .claude/skills' also destroys skills the project itself wrote), plus"
say "   .githooks/_check-seed-updates.sh AND the post-merge/post-rewrite hooks that"
say "   exec it — then /update-seed. See docs/claude-plugins.md."
echo
say "Restore anything from $BACKUP_DIR if this went wrong."
