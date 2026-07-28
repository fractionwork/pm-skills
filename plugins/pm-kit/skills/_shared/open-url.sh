#!/usr/bin/env bash
# Open a URL in the user's browser. Used as $BROWSER so Python's webbrowser
# module has something that works, and safe to call directly.
#
#   open-url.sh <url>
#   OPEN_URL_DRY_RUN=1 open-url.sh <url>   # print the command, don't run it
#
# WHY THIS EXISTS: on WSL there is often no browser handler at all — Python's
# webbrowser._tryorder comes back empty and webbrowser.open() returns quietly, so
# an OAuth flow just appears to hang.
#
# The obvious fix, `explorer.exe <url>`, is WRONG. explorer.exe resolves its
# argument as a PATH first, and when the working directory is a WSL path Windows
# cannot map it gives up and opens a File Explorer window instead of the browser.
# wslview doesn't do that — it shells out to PowerShell's Start-Process — so this
# does the same, and prefers wslview outright when it's installed.

set -u

url="${1:-}"
[ -n "$url" ] || { echo "open-url.sh: no URL given" >&2; exit 2; }

run() {
  if [ -n "${OPEN_URL_DRY_RUN:-}" ]; then
    printf '%s\n' "$*"
    return 0
  fi
  "$@" >/dev/null 2>&1
}

is_wsl() { [ -n "${WSL_DISTRO_NAME:-}${WSL_INTEROP:-}" ]; }

if is_wsl; then
  # Purpose-built and handles quoting for us.
  if command -v wslview >/dev/null 2>&1; then
    run wslview "$url"
    exit $?
  fi
  # Single-quote for PowerShell, doubling any embedded quote. OAuth URLs carry
  # & and ? — unquoted, PowerShell would treat them as syntax.
  ps_url=$(printf "%s" "$url" | sed "s/'/''/g")
  for ps in powershell.exe pwsh.exe; do
    if command -v "$ps" >/dev/null 2>&1; then
      run "$ps" -NoProfile -NonInteractive -Command "Start-Process '$ps_url'"
      exit $?
    fi
  done
  # Last resort. Known to open File Explorer instead of a browser in some
  # working directories, but better than doing nothing.
  if command -v explorer.exe >/dev/null 2>&1; then
    run explorer.exe "$url"
    exit 0   # explorer.exe returns non-zero even on success
  fi
fi

case "$(uname -s)" in
  Darwin) command -v open >/dev/null 2>&1 && { run open "$url"; exit $?; } ;;
  *)      command -v xdg-open >/dev/null 2>&1 && { run xdg-open "$url"; exit $?; } ;;
esac

echo "open-url.sh: no way to open a browser — visit this yourself:" >&2
echo "  $url" >&2
exit 1
