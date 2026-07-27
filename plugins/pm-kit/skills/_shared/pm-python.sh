#!/usr/bin/env bash
# Resolve a Python interpreter that can run pm-kit's Asana MCP server, and exec it.
#
# Why this wrapper exists: .mcp.json is static — it cannot probe for a venv, and it
# cannot branch on whether `mcp` is importable. Without it, a user who hasn't run
# /pm-setup gets whatever cryptic thing bare `python3` produces (usually a
# ModuleNotFoundError buried in MCP startup logs) and no hint about the fix.
#
# Resolution order:
#   1. $DEVHAWK_PM_PYTHON            — explicit override
#   2. ~/.devhawk/pm/venv/bin/python — what /pm-setup creates
#   3. the first python3 on PATH that can already `import mcp`
# Failing all three, print the one-line fix and exit non-zero.
#
# Usage: pm-python.sh <script.py> [args...]

set -u

PM_HOME="${DEVHAWK_PM_HOME:-$HOME/.devhawk/pm}"

die() {
  echo "pm-kit: $1" >&2
  echo "pm-kit: run /pm-setup in Claude Code to install the Asana MCP runtime." >&2
  exit 1
}

if [ -n "${DEVHAWK_PM_PYTHON:-}" ]; then
  [ -x "$DEVHAWK_PM_PYTHON" ] || die "DEVHAWK_PM_PYTHON is set but not executable: $DEVHAWK_PM_PYTHON"
  exec "$DEVHAWK_PM_PYTHON" "$@"
fi

if [ -x "$PM_HOME/venv/bin/python" ]; then
  exec "$PM_HOME/venv/bin/python" "$@"
fi

# No venv — fall back to a system python that already has the deps. Probe rather
# than assume, so we fail with an actionable message instead of at import time
# inside the MCP handshake (where Claude Code shows only "server exited").
for candidate in python3 python; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import mcp, requests' >/dev/null 2>&1; then
      exec "$candidate" "$@"
    fi
  fi
done

command -v python3 >/dev/null 2>&1 \
  || die "no python3 on PATH (the Asana MCP needs Python >= 3.10)"
die "python3 found, but the 'mcp' and 'requests' packages are missing"
