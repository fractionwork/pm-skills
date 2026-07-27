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
#   pm-setup.sh              # install deps, then authenticate if needed
#   pm-setup.sh --check      # report status only, change nothing
#   pm-setup.sh --deps-only  # install deps, skip the auth step
#   pm-setup.sh --reauth     # force re-authentication

set -uo pipefail

PM_HOME="${DEVHAWK_PM_HOME:-$HOME/.devhawk/pm}"
VENV="$PM_HOME/venv"
VENV_PY="$VENV/bin/python"

# Resolve this script's directory, following symlinks, without `readlink -f`
# (GNU-only — absent on stock macOS). Same idiom audit-kit uses.
SCRIPT_DIR="$(SRC="${BASH_SOURCE[0]}"; while [ -h "$SRC" ]; do D="$(cd -P "$(dirname "$SRC")" && pwd)"; SRC="$(readlink "$SRC")"; case $SRC in /*) ;; *) SRC="$D/$SRC" ;; esac; done; cd -P "$(dirname "$SRC")" && pwd)"
SHARED="$(cd -P "$SCRIPT_DIR/../../_shared" && pwd)"

CHECK_ONLY=0; DEPS_ONLY=0; REAUTH=0
for a in "$@"; do
  case "$a" in
    --check) CHECK_ONLY=1 ;;
    --deps-only) DEPS_ONLY=1 ;;
    --reauth) REAUTH=1 ;;
    -h|--help) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "pm-setup: unknown option '$a'" >&2; exit 2 ;;
  esac
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
  if authed; then ok "asana: credential present"
  else warn "asana: not authenticated — run /pm-setup"; fi
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
    echo "  starting Asana OAuth — a browser window will open…"
    if ! "$VENV_PY" "$SHARED/asana_ops.py" --auth; then
      bad "authentication failed."
      echo "     Alternative: export ASANA_PAT=<token> and re-run." >&2
      exit 1
    fi
  fi
fi

echo
ok "pm-kit is ready — restart Claude Code so it picks up the Asana MCP server."
