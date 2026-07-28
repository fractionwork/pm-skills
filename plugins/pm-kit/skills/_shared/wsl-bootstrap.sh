#!/usr/bin/env bash
# One-shot setup for a fresh WSL2 Ubuntu: everything Claude Code and the Fraction
# plugins need, in one command.
#
#   curl -fsSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/plugins/pm-kit/skills/_shared/wsl-bootstrap.sh -o /tmp/wsl-setup.sh
#   bash /tmp/wsl-setup.sh
#
#   bash /tmp/wsl-setup.sh --check    # report what's installed, change nothing
#
# Downloaded rather than piped into bash on purpose: this needs sudo, and a
# password prompt cannot read from the terminal when stdin is the pipe.
#
# Written for people who should not have to care what any of this is. Every step
# is idempotent, a step that fails does not stop the ones after it, and the
# summary at the end says plainly what worked and what to do next.

set -uo pipefail

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⊙\033[0m %s\n' "$1"; }
say()  { printf '  %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILED=""
note_fail() { FAILED="$FAILED$1"$'\n'; }
NEEDS_WSL_RESTART=0

have() { command -v "$1" >/dev/null 2>&1; }

# ── Windows interop ─────────────────────────────────────────────────────────
# Interop is what lets the distro execute Windows binaries. Its state lives in
# binfmt_misc, under one of two names depending on the WSL build — WSLInterop on
# older/non-systemd images, WSLInterop-late once systemd is in play. Absent
# entirely means off, so both are checked.
WSL_CONF="${WSL_CONF:-/etc/wsl.conf}"
BINFMT_DIR="${BINFMT_DIR:-/proc/sys/fs/binfmt_misc}"

interop_enabled() {
  for f in "$BINFMT_DIR/WSLInterop" "$BINFMT_DIR/WSLInterop-late"; do
    [ -e "$f" ] || continue
    head -1 "$f" 2>/dev/null | grep -qi '^enabled' && return 0
  done
  return 1
}

# enabled=true governs whether .exe runs at all; appendWindowsPath governs
# whether you can name one without its full path. They fail differently, so they
# are reported differently.
windows_on_path() {
  have powershell.exe || have pwsh.exe || have cmd.exe
}

# Set [interop] enabled=true without disturbing the rest of wsl.conf — it is an
# INI file that commonly already carries [boot] systemd=true, and [automount]
# has an `enabled` key of its own, so a file-wide sed would hit the wrong one.
enable_interop_in_wsl_conf() {
  local tmp src rc
  tmp="$(mktemp)" || return 1
  # A missing wsl.conf is the common case on a fresh image. Reading /dev/null
  # still runs the END block, which writes the section from scratch.
  src="$WSL_CONF"; [ -f "$src" ] || src=/dev/null
  awk '
    # Blank lines at the tail of the section are held back so an added key lands
    # against the keys it belongs with, not after the gap separating sections.
    function flush(   i) {
      if (!have_en) print "enabled=true"
      if (!have_ap) print "appendWindowsPath=true"
      for (i = 0; i < nblank; i++) print ""
      nblank = 0; have_en = 0; have_ap = 0
    }
    /^[[:space:]]*\[/ {
      if (insec) flush()
      insec = ($0 ~ /^[[:space:]]*\[interop\][[:space:]]*$/)
      if (insec) seen = 1
      print; next
    }
    insec && /^[[:space:]]*$/                              { nblank++; next }
    insec && /^[[:space:]]*enabled[[:space:]]*=/           { print "enabled=true";           have_en=1; next }
    insec && /^[[:space:]]*appendWindowsPath[[:space:]]*=/ { print "appendWindowsPath=true"; have_ap=1; next }
    { print }
    END {
      if (insec) flush()
      else if (!seen) {
        if (NR > 0) print ""      # separate from whatever came before
        print "[interop]"; print "enabled=true"; print "appendWindowsPath=true"
      }
    }
  ' "$src" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  sudo cp "$tmp" "$WSL_CONF"
  rc=$?
  rm -f "$tmp"
  # Best-effort, like the credential writer: the content is what matters, and a
  # filesystem that refuses chmod must not turn a successful write into a
  # reported failure that sends the user editing the file by hand.
  [ "$rc" = 0 ] && sudo chmod 644 "$WSL_CONF" 2>/dev/null
  return $rc
}

echo
echo "Fraction setup for WSL"
if ! grep -qi microsoft /proc/version 2>/dev/null; then
  bad "This does not look like WSL. Run it inside your Ubuntu terminal."
  exit 1
fi
. /etc/os-release 2>/dev/null
echo "  ${PRETTY_NAME:-unknown distro}"

# ── supported release ───────────────────────────────────────────────────────
# One release, on purpose. The apt source format, the Python version and the
# package names below are all the 24.04 ones. On another release the mismatched
# branches don't error — they quietly do nothing, and the failure resurfaces
# much later as something that looks unrelated (universe never enabled, so no
# wslview, so OAuth appears to hang). Pinning is the honest option until there
# is a reason to carry more than one.
SUPPORTED_VERSION="24.04"

supported_release() {
  [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "$SUPPORTED_VERSION" ]
}

unsupported_note() {
  cat <<EOF

  This is built for Ubuntu $SUPPORTED_VERSION. Install it from Windows
  PowerShell (not from this window):

      wsl --install Ubuntu-$SUPPORTED_VERSION

  Then open "Ubuntu $SUPPORTED_VERSION" from the Start menu and run this
  again there. Nothing you already have is removed — the two sit side by
  side, and you can pick either one from the Start menu.

EOF
}

# ── status only ─────────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" = 1 ]; then
  step "What's installed"
  supported_release && ok "Ubuntu $SUPPORTED_VERSION" \
                    || warn "${PRETTY_NAME:-unknown} — this is built for Ubuntu $SUPPORTED_VERSION"
  if interop_enabled; then
    windows_on_path && ok "Windows interop" \
                    || warn "Windows interop on, but not on PATH (appendWindowsPath=false)"
  else
    warn "Windows interop DISABLED — links cannot open; re-run without --check to fix"
  fi
  for c in git curl python3 gh claude; do
    have "$c" && ok "$c" || warn "$c — missing"
  done
  python3 -c 'import venv' 2>/dev/null && ok "python venv module" || warn "python venv module — missing"
  have wslview && ok "wslview (opens links in a browser)" || warn "wslview — missing (optional)"
  echo
  exit 0
fi

if ! supported_release; then
  bad "Wrong Ubuntu version — found ${PRETTY_NAME:-unknown}."
  unsupported_note
  # Deliberately not a prompt: someone who knows why they want this can set the
  # variable, and everyone else gets a stop with instructions instead of a
  # half-finished install they cannot diagnose.
  if [ -z "${FRACTION_ALLOW_ANY_UBUNTU:-}" ]; then
    printf '  \033[2m(to run it here anyway: FRACTION_ALLOW_ANY_UBUNTU=1 bash %s)\033[0m\n\n' "$0"
    exit 1
  fi
  warn "continuing on an unsupported release because FRACTION_ALLOW_ANY_UBUNTU is set"
  echo
fi

echo "  This installs git, Python, the GitHub CLI and Claude Code."
echo "  You will be asked for your password once."
echo

# ── 1. Windows interop ──────────────────────────────────────────────────────
step "1/5  Windows interop"
# Everything that opens a browser from WSL — wslview, PowerShell's Start-Process,
# and so both the Asana OAuth callback and /pm-setup's config form — works by
# executing a Windows binary from inside the distro. That is interop, and it can
# be off: /etc/wsl.conf can disable it outright, or leave it on but stop putting
# the Windows directories on PATH.
#
# It fails silently rather than loudly. With interop off, `powershell.exe` is
# simply "command not found", Python's webbrowser finds no handler, and the OAuth
# step looks like a hang with nothing in any log to explain it. Check it here,
# once, where the fix can be explained.
if interop_enabled; then
  if windows_on_path; then
    ok "interop enabled (Windows programs reachable)"
  else
    # enabled=true but appendWindowsPath=false. Browsers still open — open-url.sh
    # falls back to PowerShell's absolute path — so this is a note, not a repair.
    warn "interop is on but Windows isn't on PATH (appendWindowsPath=false)"
    say "  links still open; pm-kit falls back to PowerShell's full path"
  fi
else
  bad "Windows interop is disabled — nothing can open a browser"
  if enable_interop_in_wsl_conf; then
    ok "set enabled=true in /etc/wsl.conf"
    NEEDS_WSL_RESTART=1
  else
    bad "could not update /etc/wsl.conf"
    note_fail "interop (edit /etc/wsl.conf by hand: [interop] enabled=true)"
  fi
fi

step "2/5  Base packages"
sudo apt-get update -qq 2>/dev/null || warn "apt update had warnings — continuing"
if sudo apt-get install -y -qq git curl ca-certificates python3 python3-venv >/dev/null 2>&1; then
  ok "git, curl, python3 (+venv)"
else
  bad "could not install the base packages"; note_fail "base packages"
fi

# wslview makes links open in a Windows browser. Optional: /pm-setup falls back
# to PowerShell. It lives in universe, which a minimal image may not enable, and
# add-apt-repository itself may be absent — so try, and never fail the run.
if have wslview; then
  ok "wslview already present"
else
  sudo apt-get install -y -qq software-properties-common >/dev/null 2>&1
  if have add-apt-repository; then
    sudo add-apt-repository -y universe >/dev/null 2>&1
  elif [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
    # deb822, Ubuntu 24.04+. Idempotent: appends universe only where absent.
    sudo sed -i '/^Components:/{/universe/!s/$/ universe/}' \
      /etc/apt/sources.list.d/ubuntu.sources
  elif [ -s /etc/apt/sources.list ]; then
    # Legacy one-line format, 22.04 and earlier. Without this branch the deb822
    # sed above silently edits nothing on those images and universe never
    # arrives — a failure with no error message anywhere.
    sudo sed -i '/^deb /{/ universe/!s/$/ universe/}' /etc/apt/sources.list
  fi
  sudo apt-get update -qq 2>/dev/null
  if sudo apt-get install -y -qq wslu >/dev/null 2>&1; then
    ok "wslview (links open in your browser)"
  else
    warn "wslview unavailable — links will open via PowerShell instead, which is fine"
  fi
fi

# ── 2. GitHub CLI ───────────────────────────────────────────────────────────
step "3/5  GitHub CLI"
if have gh; then
  ok "gh already installed ($(gh --version 2>/dev/null | head -1 | awk '{print $3}'))"
else
  # GitHub's own repo — Ubuntu's copy lags well behind.
  sudo mkdir -p -m 755 /etc/apt/keyrings
  if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1; then
    sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt-get update -qq 2>/dev/null
  fi
  if sudo apt-get install -y -qq gh >/dev/null 2>&1; then
    ok "gh installed"
  else
    bad "could not install gh"; note_fail "gh"
  fi
fi

# ── 3. GitHub's host key ────────────────────────────────────────────────────
# Without this, anything non-interactive (git, gh, Claude Code's plugin fetch)
# fails with "host key not in known hosts" instead of prompting.
step "4/5  Trusting github.com"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
if ssh-keygen -F github.com >/dev/null 2>&1; then
  ok "github.com already trusted"
else
  ssh-keyscan -t ed25519 github.com 2>/dev/null >> ~/.ssh/known_hosts
  fp=$(ssh-keygen -lF github.com 2>/dev/null | awk '/ED25519/{print $3}')
  if [ "$fp" = "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU" ]; then
    ok "github.com verified and trusted"
  else
    # Removing it again is the safe move: a wrong key is worse than none.
    sed -i '/^github\.com /d' ~/.ssh/known_hosts 2>/dev/null
    bad "github.com's key did not match the published fingerprint — not trusting it"
    note_fail "github.com host key (check your network)"
  fi
fi

# ── 4. Claude Code ──────────────────────────────────────────────────────────
step "5/5  Claude Code"
if have claude; then
  ok "already installed ($(claude --version 2>/dev/null))"
else
  if curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1; then
    export PATH="$HOME/.local/bin:$PATH"
    have claude && ok "installed ($(claude --version 2>/dev/null))" \
                || { bad "installed but not on PATH — open a new terminal"; note_fail "claude on PATH"; }
  else
    bad "could not install Claude Code"; note_fail "Claude Code"
  fi
fi

# ── summary ─────────────────────────────────────────────────────────────────
echo
if [ -n "$FAILED" ]; then
  printf '\033[1mSome things did not install:\033[0m\n'
  printf '%s' "$FAILED" | sed 's/^/  ✗ /'
  echo "  Send this output to whoever set this up — everything else is ready."
else
  printf '\033[1;32mAll set.\033[0m\n'
fi

# Interop is registered when the distro boots, so a wsl.conf edit changes
# nothing until every distro session has actually stopped. Closing the window is
# not enough, and skipping this leaves the browser steps failing exactly as they
# did before — which reads as "the fix didn't work".
if [ "$NEEDS_WSL_RESTART" = 1 ]; then
  cat <<'RESTART'

  ┌──────────────────────────────────────────────────────────────────┐
  │  RESTART WSL BEFORE GOING FURTHER                                │
  │                                                                  │
  │  Windows interop was off. It is fixed, but the change only       │
  │  takes effect after WSL fully stops.                             │
  │                                                                  │
  │  1. Open Windows PowerShell (not this window) and run:           │
  │                                                                  │
  │         wsl --shutdown                                           │
  │                                                                  │
  │  2. Reopen Ubuntu from the Start menu.                           │
  │                                                                  │
  │  Skip this and links will still refuse to open.                  │
  └──────────────────────────────────────────────────────────────────┘
RESTART
fi

cat <<'NEXT'

Next — copy these one at a time:

  1. Close this terminal and open a new one (so it finds the new commands).

  2. Sign in to GitHub:

       gh auth login --git-protocol ssh --web

     Choose "Login with a web browser", press Enter, and follow the prompts.

  3. Start Claude Code:

       claude

  4. Inside Claude Code, add the tools:

       /plugin marketplace add fractionwork/software-factory-tools
       /plugin install pm-kit@software-factory-tools

  5. Restart Claude Code, then run:

       /pm-setup

     It will ask for your Asana app details and open a browser to sign in.

NEXT
