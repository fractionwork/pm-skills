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
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

FAILED=""
note_fail() { FAILED="$FAILED$1"$'\n'; }

have() { command -v "$1" >/dev/null 2>&1; }

echo
echo "Fraction setup for WSL"
if ! grep -qi microsoft /proc/version 2>/dev/null; then
  bad "This does not look like WSL. Run it inside your Ubuntu terminal."
  exit 1
fi
. /etc/os-release 2>/dev/null
echo "  ${PRETTY_NAME:-unknown distro}"

# ── status only ─────────────────────────────────────────────────────────────
if [ "$CHECK_ONLY" = 1 ]; then
  step "What's installed"
  for c in git curl python3 gh claude; do
    have "$c" && ok "$c" || warn "$c — missing"
  done
  python3 -c 'import venv' 2>/dev/null && ok "python venv module" || warn "python venv module — missing"
  have wslview && ok "wslview (opens links in a browser)" || warn "wslview — missing (optional)"
  echo
  exit 0
fi

echo "  This installs git, Python, the GitHub CLI and Claude Code."
echo "  You will be asked for your password once."
echo

# ── 1. base packages ────────────────────────────────────────────────────────
step "1/4  Base packages"
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
  else
    # deb822 format on Ubuntu 24.04+; idempotent, appends universe only if absent
    sudo sed -i '/^Components:/{/universe/!s/$/ universe/}' \
      /etc/apt/sources.list.d/ubuntu.sources 2>/dev/null
  fi
  sudo apt-get update -qq 2>/dev/null
  if sudo apt-get install -y -qq wslu >/dev/null 2>&1; then
    ok "wslview (links open in your browser)"
  else
    warn "wslview unavailable — links will open via PowerShell instead, which is fine"
  fi
fi

# ── 2. GitHub CLI ───────────────────────────────────────────────────────────
step "2/4  GitHub CLI"
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
step "3/4  Trusting github.com"
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
step "4/4  Claude Code"
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
