#!/usr/bin/env bash
# Install pm-kit's Python runtime and authenticate against Asana.
#
# This is all that survives of the old 817-line installer. Everything else it did
# — copying skills, registering the MCP server, filtering by profile, splicing
# prose into ~/.claude/CLAUDE.md — is now the plugin system's job. What remains
# is the one thing a plugin genuinely cannot do: create a Python environment.
#
# Everything is written OUTSIDE the plugin directory, to ~/.devhawk/pm. The
# plugin root is content-hash addressed and replaced wholesale on every update,
# so a venv or a token stored there would be destroyed by the next `/plugin
# marketplace update`.
#
# Idempotent: safe to re-run, and re-running is how you upgrade the deps.
#
# Usage:
#   pm-setup.sh                          # install deps, configure the app, authenticate
#   pm-setup.sh --check                  # report status only, change nothing
#   pm-setup.sh --deps-only              # install deps, skip app config + auth
#   pm-setup.sh --reauth                 # force re-authentication
#   pm-setup.sh --client-id ID           # supply the OAuth app non-interactively
#   pm-setup.sh --client-secret SECRET   # (or set ASANA_CLIENT_ID / ASANA_CLIENT_SECRET)
#
# The OAuth app is NOT shipped with the plugin — it used to be hardcoded, which
# published a client secret to a public marketplace and tied the kit to one Asana
# app. It is collected here instead and stored at 0600 in workspace.json.

set -uo pipefail

PM_HOME="${DEVHAWK_PM_HOME:-$HOME/.devhawk/pm}"
VENV="$PM_HOME/venv"
VENV_PY="$VENV/bin/python"

# Resolve this script's directory, following symlinks, without `readlink -f`
# (GNU-only — absent on stock macOS). Same idiom audit-kit uses.
SCRIPT_DIR="$(SRC="${BASH_SOURCE[0]}"; while [ -h "$SRC" ]; do D="$(cd -P "$(dirname "$SRC")" && pwd)"; SRC="$(readlink "$SRC")"; case $SRC in /*) ;; *) SRC="$D/$SRC" ;; esac; done; cd -P "$(dirname "$SRC")" && pwd)"
SHARED="$(cd -P "$SCRIPT_DIR/../../_shared" && pwd)"

CHECK_ONLY=0; DEPS_ONLY=0; REAUTH=0
CLIENT_ID="${ASANA_CLIENT_ID:-}"; CLIENT_SECRET="${ASANA_CLIENT_SECRET:-}"
while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --client-id) CLIENT_ID="${2:-}"; shift ;;
    --client-secret) CLIENT_SECRET="${2:-}"; shift ;;
    --check) CHECK_ONLY=1 ;;
    --deps-only) DEPS_ONLY=1 ;;
    --reauth) REAUTH=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "pm-setup: unknown option '$a'" >&2; exit 2 ;;
  esac
  shift
done

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⊙\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

# ── locate a base interpreter ───────────────────────────────────────────────
# The MCP SDK needs >= 3.10. Check the version rather than trusting `python3`:
# several distros still ship 3.9 there, and the failure would otherwise appear
# as an opaque syntax error deep inside the mcp package.
find_python() {
  for c in python3.13 python3.12 python3.11 python3.10 python3 python; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      echo "$c"; return 0
    fi
  done
  return 1
}

deps_present() { [ -x "$VENV_PY" ] && "$VENV_PY" -c 'import mcp, requests' >/dev/null 2>&1; }

# Legacy path is ~/.claude/scripts/, where the old installer pointed
# ASANA_TOKEN_FILE (install.sh:523) — not ~/.claude/.
LEGACY_TOKEN="$HOME/.claude/scripts/.asana-token.json"

WS_CONFIG="$PM_HOME/workspace.json"

# Any python that runs — these helpers are used by --check, which runs BEFORE
# the venv exists. Pointing at $VENV_PY there makes the probe fail silently and
# report a configured app as missing.
cfg_py() {
  if [ -x "$VENV_PY" ]; then echo "$VENV_PY"
  elif command -v python3 >/dev/null 2>&1; then echo python3
  else echo python; fi
}

# Is an OAuth app available? The flag/env wins, else workspace.json must carry
# both halves. A PAT makes all of this unnecessary.
oauth_app_configured() {
  [ -n "$CLIENT_ID" ] && [ -n "$CLIENT_SECRET" ] && return 0
  [ -f "$WS_CONFIG" ] || return 1
  "$(cfg_py)" -c '
import json, sys
try:
    o = json.load(open(sys.argv[1])).get("oauth") or {}
except Exception:
    sys.exit(1)
sys.exit(0 if o.get("clientId") and o.get("clientSecret") else 1)
' "$WS_CONFIG" 2>/dev/null
}

# Merge the app into workspace.json WITHOUT disturbing the other blocks
# (requiredFields, requiredAdmins, ...) a user may already have configured.
save_oauth_app() {
  "$(cfg_py)" -c '
import json, os, pathlib, sys
path, cid, secret = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
try:
    cfg = json.loads(p.read_text())
except Exception:
    cfg = {}
cfg.setdefault("oauth", {})
cfg["oauth"]["clientId"] = cid
cfg["oauth"]["clientSecret"] = secret
p.parent.mkdir(parents=True, exist_ok=True)
p.write_text(json.dumps(cfg, indent=2) + "\n")
os.chmod(p, 0o600)
' "$WS_CONFIG" "$1" "$2"
}

authed() {
  [ -f "$PM_HOME/asana-token.json" ] || [ -f "$LEGACY_TOKEN" ] \
    || [ -n "${ASANA_PAT:-}" ] || [ -n "${ASANA_ACCESS_TOKEN:-}" ]
}

# ── status ──────────────────────────────────────────────────────────────────
echo "pm-kit setup — $PM_HOME"

if [ "$CHECK_ONLY" = 1 ]; then
  if BASE_PY="$(find_python)"; then ok "python: $BASE_PY ($("$BASE_PY" -V 2>&1))"
  else bad "no python >= 3.10 on PATH"; fi
  if deps_present; then ok "runtime: venv ready (mcp, requests)"
  else warn "runtime: not installed — run /pm-setup"; fi
  if oauth_app_configured; then ok "oauth app: configured"
  elif [ -n "${ASANA_PAT:-}${ASANA_ACCESS_TOKEN:-}" ]; then ok "oauth app: not needed (using a PAT)"
  else warn "oauth app: not configured — /pm-setup will ask, or use ASANA_PAT"; fi
  if authed; then ok "asana: credential present"
  else warn "asana: not authenticated — run /pm-setup"; fi
  # A missing workspace.json is NOT an error: the board skills still work, they
  # just skip the field/admin policy rather than writing another workspace's GIDs.
  if [ -f "$WS_CONFIG" ]; then ok "workspace config: $WS_CONFIG"
  else warn "workspace config: none — field/admin policy skipped (see workspace.example.json)"; fi
  exit 0
fi

# ── install deps ────────────────────────────────────────────────────────────
if deps_present && [ "$REAUTH" = 0 ]; then
  ok "runtime already installed"
else
  BASE_PY="$(find_python)" || {
    bad "no Python >= 3.10 found on PATH."
    echo "     Install one (macOS: brew install python@3.12 · Debian/Ubuntu:" >&2
    echo "     sudo apt install python3.12-venv) and re-run /pm-setup." >&2
    exit 1
  }
  echo "  using $BASE_PY ($("$BASE_PY" -V 2>&1))"
  mkdir -p "$PM_HOME"
  if [ ! -x "$VENV_PY" ]; then
    echo "  creating venv…"
    if ! "$BASE_PY" -m venv "$VENV" 2>/dev/null; then
      bad "could not create a venv."
      echo "     On Debian/Ubuntu this usually means the venv module is missing:" >&2
      echo "       sudo apt install python3-venv" >&2
      exit 1
    fi
  fi
  echo "  installing mcp + requests…"
  # Stream progress rather than buffering: a silent multi-minute pip run reads
  # as a hang, which is what the old installer was reported for.
  if ! "$VENV_PY" -m pip install --quiet --upgrade pip 2>&1 | sed 's/^/    /'; then
    warn "pip self-upgrade failed — continuing with the bundled pip"
  fi
  if ! "$VENV_PY" -m pip install --upgrade -r "$SHARED/requirements-mcp.txt" 2>&1 | sed 's/^/    /'; then
    bad "dependency install failed (see the pip output above)."
    exit 1
  fi
  deps_present && ok "runtime installed" || { bad "deps installed but not importable"; exit 1; }
fi

[ "$DEPS_ONLY" = 1 ] && exit 0

# ── authenticate ────────────────────────────────────────────────────────────
if authed && [ "$REAUTH" = 0 ]; then
  ok "asana credential already present (--reauth to replace it)"
else
  if [ -n "${ASANA_PAT:-}${ASANA_ACCESS_TOKEN:-}" ]; then
    ok "using the PAT from the environment"
  else
    # Collect the OAuth app before starting the flow. It is deliberately not
    # shipped: hardcoding it published a client secret to a public marketplace
    # and tied the kit to a single Asana app.
    if ! oauth_app_configured; then
      if [ -t 0 ]; then
        echo
        echo "  Asana OAuth app — from https://app.asana.com/0/my-apps"
        echo "  (redirect URI must be http://localhost:8372/callback)"
        echo
        echo "  No app? Press Enter twice to skip and use a personal access token instead."
        [ -n "$CLIENT_ID" ] || { printf "    Client ID: "; read -r CLIENT_ID; }
        # -s so the secret never lands in the terminal or scrollback.
        [ -n "$CLIENT_SECRET" ] || { printf "    Client secret: "; read -rs CLIENT_SECRET; echo; }
      fi
      if [ -z "$CLIENT_ID" ] || [ -z "$CLIENT_SECRET" ]; then
        bad "no Asana OAuth app configured, and no PAT set."
        echo "     Either re-run with --client-id/--client-secret," >&2
        echo "     or use a token instead:  export ASANA_PAT=<token>" >&2
        echo "     (app.asana.com → My settings → Apps → Personal access tokens)" >&2
        exit 1
      fi
      save_oauth_app "$CLIENT_ID" "$CLIENT_SECRET"
      ok "oauth app saved to $WS_CONFIG (0600)"
    fi

    # Python's webbrowser often finds no handler on WSL — _tryorder comes back
    # empty, webbrowser.open() returns quietly, and the OAuth step looks like a
    # hang. Point BROWSER at our opener, which prefers wslview and otherwise
    # goes through PowerShell's Start-Process.
    #
    # NOT explorer.exe: it resolves its argument as a PATH first, and from a WSL
    # working directory Windows can't map it gives up and opens a File Explorer
    # window instead of the browser.
    # A BROWSER of explorer.exe is treated as unset: it is a known-bad value that
    # opens a File Explorer window rather than a browser, and earlier guidance
    # (including ours) told people to set it. Honouring it would silently defeat
    # the opener below on exactly the machines that need it.
    case "${BROWSER:-}" in
      explorer|explorer.exe|*/explorer.exe)
        say "ignoring BROWSER=$BROWSER — it opens File Explorer, not a browser"
        say "  remove it from your shell profile if you set it there"
        BROWSER=""
        ;;
    esac

    if [ -z "${BROWSER:-}" ] && [ -x "$SHARED/open-url.sh" ]; then
      export BROWSER="$SHARED/open-url.sh"
      [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ] \
        && say "using $SHARED/open-url.sh to open the browser (WSL)"
    fi

    echo "  starting Asana OAuth — a browser window will open…"
    if ! ASANA_CLIENT_ID="$CLIENT_ID" ASANA_CLIENT_SECRET="$CLIENT_SECRET" \
         "$VENV_PY" "$SHARED/asana_ops.py" --auth; then
      bad "authentication failed."
      echo "     If no browser opened: set BROWSER (e.g. export BROWSER=explorer.exe on WSL)," >&2
      echo "     or check the app's redirect URI is http://localhost:8372/callback." >&2
      echo "     or use a token instead:  export ASANA_PAT=<token>" >&2
      exit 1
    fi
  fi
fi

echo
ok "pm-kit is ready — restart Claude Code so it picks up the Asana MCP server."
