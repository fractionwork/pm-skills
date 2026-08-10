#!/usr/bin/env bash
# factory-setup — one command from a bare machine to working Claude Code plugins.
#
# Installs prerequisites, authenticates to GitHub, adds the marketplace, installs
# the kits you pick (plus audit-kit's scanners), and optionally records the
# credentials that have a LOCAL consumer.
#
# WHAT THIS DELIBERATELY DOES NOT DO. An 817-line installer used to live here and
# was deleted on purpose: copying skills, registering MCP servers and splicing
# prose into ~/.claude/CLAUDE.md are the plugin system's job now, and doing them
# by hand is how installed copies drift from the repo. This script's remit is
# strictly what has to happen BEFORE or OUTSIDE Claude Code. If a plugin can do
# it, this must not.
#
# THE ENGINE IS OPTIONAL. Of 34 skills across the four kits, four consult the
# factory and each does so as an extra step at the END, never a precondition. A
# machine that never sets FACTORY_API_TOKEN gets a complete, working install —
# the token prompt is skippable and says so. Do not read "factory" in the name as
# a requirement; it is the name of the toolkit, not a dependency.
#
# Server-side credentials (Linear, Azure DevOps, Fireflies, Teams, Slack) are NOT
# collected here. Nothing on a workstation reads them — they live in
# /etc/factory/env on the engine host and are an operator's job. Writing them
# locally would create files that look like configuration and are loaded by
# nothing, which is worse than their absence.
#
# Usage:
#   ./factory-setup.sh                    # interactive
#   ./factory-setup.sh --check            # report state, change nothing
#   ./factory-setup.sh --role engineer --yes   # non-interactive
#   ./factory-setup.sh --role pm          # public marketplace only, no GitHub auth
#
# Roles: pm · engineer · devhawk · auditor · all
#
# Safe to re-run: every phase is idempotent, and a phase that fails does not stop
# the ones after it — failures are collected and printed once at the end.

# NOT `set -e`: one failing phase must never abort the rest. The summary is the
# contract, and it can only be honest if execution reaches it.
set -uo pipefail

NVM_VERSION="v0.40.6"
NODE_MAJOR="24"
PYTHON_MIN="3.10"
PRIVATE_MARKETPLACE="fractionwork/software-factory-tools"
PUBLIC_MARKETPLACE="fractionwork/pm-skills"
DEVHAWK_HOME="${DEVHAWK_HOME:-$HOME/.devhawk}"
ENV_FILE="$DEVHAWK_HOME/env"

CHECK_ONLY=0
ASSUME_YES=0
ROLE=""
FAILED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --role) ROLE="${2:-}"; shift ;;
    --role=*) ROLE="${1#--role=}" ;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    *) echo "factory-setup: unknown option '$1'" >&2; exit 2 ;;
  esac
  shift
done

# ── output ──────────────────────────────────────────────────────────────────
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⊙\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
say()  { printf '    %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
note_fail() { FAILED="$FAILED$1"$'\n'; }
have() { command -v "$1" >/dev/null 2>&1; }

# Ask, unless --yes. Default is YES so a bare Enter keeps things moving.
confirm() {
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '  %s [Y/n] ' "$1"
  read -r reply </dev/tty 2>/dev/null || return 0
  case "$reply" in [Nn]*) return 1 ;; *) return 0 ;; esac
}

# Read a secret without echoing it, and never accept one from a pipe — a value
# arriving on stdin is far more likely to be the next line of a script than a
# token a human meant to type.
read_secret() {
  [ -t 0 ] || { echo ""; return 1; }
  printf '  %s: ' "$1" >&2
  local v=""
  read -r -s v </dev/tty 2>/dev/null || { echo ""; return 1; }
  printf '\n' >&2
  echo "$v"
}

# ── platform ────────────────────────────────────────────────────────────────
PLATFORM="unknown"
IS_WSL=0
detect_platform() {
  case "$(uname -s)" in
    Darwin) PLATFORM="macos" ;;
    Linux)
      PLATFORM="linux"
      # WSL2 advertises itself in /proc/version; `uname -r` also carries it, but
      # only on some kernels, so check both.
      if grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null; then IS_WSL=1; PLATFORM="wsl"; fi
      ;;
  esac
}

ubuntu_release() {
  [ -r /etc/os-release ] || { echo ""; return; }
  # shellcheck disable=SC1091
  ( . /etc/os-release; echo "${VERSION_ID:-}" )
}

# ── node ────────────────────────────────────────────────────────────────────
# nvm is a shell FUNCTION, not a binary. It is sourced from an rc file, so it
# does not exist in this script's shell unless we source it ourselves — and a
# `command -v nvm` check would report nothing on a machine where it is installed
# and working. Load it explicitly before every use.
load_nvm() {
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  # shellcheck disable=SC1091
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1
}

# The version that MATTERS is the one a NEW shell resolves, because that is what
# Claude Code and the kits' .mjs scripts get. A node that works only in the
# installing terminal is the most common way this setup half-works.
#
# Probing that correctly is fiddlier than it looks, and getting it wrong is a
# macOS-only false negative:
#
#   - macOS defaults to zsh, so nvm appends to ~/.zshrc. `bash -lc` reads
#     ~/.bash_profile / ~/.profile and would never see it — the script would
#     report "no node" on a machine where node works perfectly.
#   - `zsh -lc` does not help: .zshrc is sourced for INTERACTIVE shells only, so
#     a login-but-not-interactive zsh misses it too.
#
# So try the user's own shell first, interactive AND login, and fall back
# through the other plausible combinations. Any hit means a real session will
# find node; no hit across all four means none will.
login_node_version() {
  local sh candidates c v
  sh="${SHELL:-/bin/bash}"
  candidates="$sh:-lic $sh:-lc /bin/bash:-lic /bin/bash:-lc"
  for c in $candidates; do
    local bin="${c%%:*}" flag="${c##*:}"
    [ -x "$bin" ] || continue
    # `-i` makes some shells emit job-control noise on a non-tty; discard it and
    # keep only a line that actually looks like a version.
    v="$("$bin" "$flag" 'command -v node >/dev/null 2>&1 && node -v' 2>/dev/null \
          | tr -d '\r' | grep -E '^v?[0-9]+\.' | head -1)"
    [ -n "$v" ] && { echo "$v"; return 0; }
  done
  echo ""
  return 1
}

node_major() { echo "${1#v}" | cut -d. -f1; }

node_ok() {
  local v; v="$(login_node_version)"
  [ -n "$v" ] || return 1
  [ "$(node_major "$v")" -ge "$NODE_MAJOR" ] 2>/dev/null
}

# ── python ──────────────────────────────────────────────────────────────────
# Only pm-kit needs this, and only for its Asana MCP. Check the VERSION rather
# than trusting `python3`: macOS ships 3.9.x on several releases, and the failure
# would otherwise surface as an opaque error deep inside the mcp package.
find_python() {
  local c
  for c in python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python3 python; do
    have "$c" || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      echo "$c"; return 0
    fi
  done
  return 1
}

# ── role → kits ─────────────────────────────────────────────────────────────
kits_for_role() {
  case "$1" in
    pm)       echo "pm-kit" ;;
    engineer) echo "pm-kit ship-kit" ;;
    devhawk)  echo "pm-kit ship-kit devhawk-kit" ;;
    auditor)  echo "audit-kit" ;;
    all)      echo "pm-kit ship-kit devhawk-kit audit-kit" ;;
    *)        echo "" ;;
  esac
}

# pm-kit alone comes from the PUBLIC mirror, which Claude Code clones with no
# credentials at all. That is the whole reason a PM never has to run `gh auth`.
needs_private_marketplace() {
  case " $1 " in *" ship-kit "*|*" devhawk-kit "*|*" audit-kit "*) return 0 ;; esac
  return 1
}

prompt_role() {
  [ -n "$ROLE" ] && return 0
  if [ "$ASSUME_YES" = "1" ]; then ROLE="engineer"; return 0; fi
  cat <<'EOF'

  Which kits do you want?

    1) PM / delivery      pm-kit                                (no GitHub access needed)
    2) Engineer           pm-kit ship-kit
    3) DevHawk engineer   pm-kit ship-kit devhawk-kit
    4) Auditor            audit-kit
    5) Everything

EOF
  printf '  Choose [2]: '
  local n=""; read -r n </dev/tty 2>/dev/null || n=""
  case "${n:-2}" in
    1) ROLE="pm" ;; 2) ROLE="engineer" ;; 3) ROLE="devhawk" ;;
    4) ROLE="auditor" ;; 5) ROLE="all" ;;
    *) ROLE="engineer" ;;
  esac
}

# ── status ──────────────────────────────────────────────────────────────────
report_state() {
  step "factory-setup — status only, nothing will be changed"
  say "platform: $PLATFORM"

  have git && ok "git ($(git --version 2>/dev/null | awk '{print $3}'))" || bad "git missing"
  have curl && ok "curl" || bad "curl missing"

  local v; v="$(login_node_version)"
  if [ -z "$v" ]; then bad "node not found in a login shell"
  elif node_ok; then ok "node $v (login shell)"
  else bad "node $v — below the $NODE_MAJOR floor"; fi

  local py; if py="$(find_python)"; then ok "python: $py ($($py -V 2>&1))"; else warn "no python >= $PYTHON_MIN (pm-kit's Asana MCP needs one)"; fi

  if have claude; then ok "claude ($(claude --version 2>/dev/null | head -1))"; else bad "Claude Code missing"; fi

  if have gh; then
    if gh auth status >/dev/null 2>&1; then ok "gh authenticated"; else warn "gh installed but not authenticated"; fi
  else warn "gh missing (needed only for the private marketplace)"; fi

  if have claude; then
    local m; m="$(claude plugin marketplace list 2>/dev/null)"
    case "$m" in
      *software-factory-tools*) ok "marketplace: $PRIVATE_MARKETPLACE" ;;
      *pm-skills*)              ok "marketplace: $PUBLIC_MARKETPLACE" ;;
      *)                        warn "no factory marketplace configured" ;;
    esac
    local p; p="$(claude plugin list 2>/dev/null | tr '\n' ' ')"
    local k; for k in pm-kit ship-kit devhawk-kit audit-kit; do
      case " $p " in *"$k"*) ok "plugin: $k" ;; *) say "plugin: $k not installed" ;; esac
    done
  fi

  if [ -r "$ENV_FILE" ]; then
    ok "credentials file: $ENV_FILE ($(stat -c '%a' "$ENV_FILE" 2>/dev/null || stat -f '%Lp' "$ENV_FILE" 2>/dev/null))"
    grep -oE '^export [A-Z_]+' "$ENV_FILE" 2>/dev/null | awk '{print "      " $2}'
  else
    say "no credentials recorded (fine — the kits work without them)"
  fi
  printf '\n'
}

# ── phases ──────────────────────────────────────────────────────────────────
phase_prereqs() {
  step "1/5  Prerequisites"

  if [ "$PLATFORM" = "wsl" ] || [ "$PLATFORM" = "linux" ]; then
    if [ "$PLATFORM" = "wsl" ]; then
      local rel; rel="$(ubuntu_release)"
      if [ -n "$rel" ] && [ "$rel" != "24.04" ]; then
        bad "Ubuntu $rel — the supported WSL distro is 24.04"
        say "apt sources, python version and package names all differ between releases,"
        say "and the mismatches do not error; they resurface later as unrelated failures."
        say "From Windows PowerShell:  wsl --install Ubuntu-24.04"
        note_fail "unsupported WSL distro (Ubuntu $rel)"
        return 1
      fi
    fi
    if have apt-get; then
      sudo apt-get update -qq 2>/dev/null
      if sudo apt-get install -y -qq git curl python3-venv >/dev/null 2>&1; then
        ok "base packages (git, curl, python3-venv)"
      else
        bad "could not install base packages"; note_fail "base packages"
      fi
      # wslview lets OAuth open a real browser instead of File Explorer. Optional.
      [ "$PLATFORM" = "wsl" ] && { sudo apt-get install -y -qq wslu >/dev/null 2>&1 && ok "wslu (browser handoff)" || warn "wslu unavailable — links may not open"; }
    fi
  elif [ "$PLATFORM" = "macos" ]; then
    have git || { warn "git missing — run: xcode-select --install"; note_fail "git (xcode-select --install)"; }
    if have brew; then
      ok "homebrew"
    else
      # Warning and continuing used to dead-end later: phase_github has no way
      # to install gh without it and fails with "no package manager".
      warn "homebrew not installed — gh and python cannot be installed without it"
      if [ "$ASSUME_YES" != "1" ] && confirm "install Homebrew now?"; then
        if curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o /tmp/brew-install.sh 2>/dev/null &&
           NONINTERACTIVE=1 bash /tmp/brew-install.sh >/dev/null 2>&1; then
          # Apple silicon installs to /opt/homebrew, which is not on PATH until
          # shellenv runs; Intel uses /usr/local and usually already is.
          for p in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            [ -x "$p" ] && eval "$("$p" shellenv)" && break
          done
          have brew && ok "homebrew" || { bad "installed but not on PATH"; note_fail "homebrew on PATH"; }
        else
          bad "could not install Homebrew"; note_fail "homebrew (see https://brew.sh)"
        fi
      else
        note_fail "homebrew (see https://brew.sh)"
      fi
    fi
    # macOS is the platform where python3 is genuinely in doubt.
    if find_python >/dev/null; then ok "python $( "$(find_python)" -V 2>&1 )"
    elif have brew; then
      confirm "install python@3.12 via brew?" && { brew install python@3.12 >/dev/null 2>&1 && ok "python@3.12" || note_fail "python@3.12"; }
    else warn "no python >= $PYTHON_MIN — pm-kit's Asana MCP will not run"; fi
  fi

  # ── node, via nvm ──
  if node_ok; then
    ok "node $(login_node_version) (login shell)"
  else
    local cur; cur="$(login_node_version)"
    [ -n "$cur" ] && say "found node $cur — below the $NODE_MAJOR floor, installing via nvm"
    # Make sure the rc file exists BEFORE nvm runs. nvm's installer appends to a
    # profile it detects, and when it finds none it prints "Profile not found"
    # and appends nothing — leaving node absent from every future shell. A fresh
    # macOS account with no ~/.zshrc hits this exactly.
    local rc; rc="$(primary_rc)"
    [ -f "$rc" ] || { touch "$rc" 2>/dev/null && say "created $rc for nvm to write to"; }

    load_nvm
    if ! command -v nvm >/dev/null 2>&1 && ! type nvm >/dev/null 2>&1; then
      if curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh" -o /tmp/nvm-install.sh 2>/dev/null &&
         bash /tmp/nvm-install.sh >/dev/null 2>&1; then
        ok "nvm $NVM_VERSION"
      else
        bad "could not install nvm"; note_fail "nvm"
      fi
      load_nvm
    else
      ok "nvm already present"
    fi

    if type nvm >/dev/null 2>&1; then
      if nvm install "$NODE_MAJOR" >/dev/null 2>&1; then
        # Without a default alias, `nvm install` affects only THIS shell: every
        # future terminal, and anything Claude Code spawns, finds no node at all.
        nvm alias default "$NODE_MAJOR" >/dev/null 2>&1
        if node_ok; then ok "node $(login_node_version) (login shell)"
        else bad "node installed but a login shell cannot find it"
             say "check that your rc file sources nvm, then: nvm alias default $NODE_MAJOR"
             note_fail "node on PATH in a login shell"; fi
      else
        bad "nvm could not install node $NODE_MAJOR"; note_fail "node $NODE_MAJOR"
      fi
    fi
  fi

  # ── Claude Code ──
  if have claude; then
    ok "Claude Code ($(claude --version 2>/dev/null | head -1))"
  else
    if curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh 2>/dev/null && bash /tmp/claude-install.sh >/dev/null 2>&1; then
      have claude && ok "Claude Code" || { warn "installed but not on PATH — open a new terminal"; note_fail "claude on PATH"; }
    else
      bad "could not install Claude Code"; note_fail "Claude Code"
    fi
  fi
}

phase_github() {
  step "2/5  GitHub access"
  local kits; kits="$(kits_for_role "$ROLE")"
  if ! needs_private_marketplace "$kits"; then
    ok "not needed — pm-kit comes from the public marketplace"
    say "no gh auth, no SSH key, no GitHub account required"
    return 0
  fi

  if ! have gh; then
    if [ "$PLATFORM" = "macos" ] && have brew; then
      brew install gh >/dev/null 2>&1 && ok "gh" || { bad "could not install gh"; note_fail "gh"; return 1; }
    elif have apt-get; then
      # GitHub's own apt repo — Ubuntu's copy lags well behind.
      sudo mkdir -p -m 755 /etc/apt/keyrings 2>/dev/null
      if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null \
           | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1; then
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq 2>/dev/null
      fi
      sudo apt-get install -y -qq gh >/dev/null 2>&1 && ok "gh" || { bad "could not install gh"; note_fail "gh"; return 1; }
    else
      bad "no package manager to install gh with"; note_fail "gh"; return 1
    fi
  else
    ok "gh present"
  fi

  if gh auth status >/dev/null 2>&1; then
    ok "gh authenticated"
  else
    say "the marketplace repo is PRIVATE, so this cannot be skipped for these kits"
    say "choose SSH — it is the only protocol that lets the marketplace auto-update"
    if [ "$ASSUME_YES" = "1" ]; then
      bad "not authenticated, and --yes cannot complete a browser login"
      say "run: gh auth login --git-protocol ssh --web"
      note_fail "gh auth (run: gh auth login --git-protocol ssh --web)"
      return 1
    fi
    gh auth login --git-protocol ssh --web </dev/tty
    gh auth status >/dev/null 2>&1 && ok "gh authenticated" || { bad "still not authenticated"; note_fail "gh auth"; return 1; }
  fi

  # Trust github.com's host key non-interactively. Without this, callers that
  # cannot prompt — git, gh, Claude Code's marketplace fetch — fail with
  # "host key not in known hosts" rather than asking.
  mkdir -p "$HOME/.ssh" 2>/dev/null && chmod 700 "$HOME/.ssh" 2>/dev/null
  if ! ssh-keygen -F github.com >/dev/null 2>&1; then
    ssh-keyscan -t rsa,ecdsa,ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null \
      && ok "trusted github.com's host key" \
      || { warn "could not add github.com's host key"; note_fail "github.com host key"; }
  else
    ok "github.com host key already trusted"
  fi
}

phase_marketplace() {
  step "3/5  Marketplace"
  have claude || { bad "Claude Code is not installed — skipping"; note_fail "marketplace (no claude)"; return 1; }

  local kits source
  kits="$(kits_for_role "$ROLE")"
  if needs_private_marketplace "$kits"; then source="$PRIVATE_MARKETPLACE"; else source="$PUBLIC_MARKETPLACE"; fi

  local existing; existing="$(claude plugin marketplace list 2>/dev/null)"
  case "$existing" in
    *"${source##*/}"*) ok "marketplace already added: $source"; return 0 ;;
  esac

  if claude plugin marketplace add "$source" >/dev/null 2>&1; then
    ok "added marketplace: $source"
  else
    bad "could not add marketplace: $source"
    if [ "$source" = "$PRIVATE_MARKETPLACE" ]; then
      say "this repo is private — a not-found here is usually a permissions problem,"
      say "not a typo. Confirm with: gh repo view $PRIVATE_MARKETPLACE"
    fi
    note_fail "marketplace $source"
    return 1
  fi
}

phase_plugins() {
  step "4/5  Plugins"
  have claude || { bad "Claude Code is not installed — skipping"; note_fail "plugins (no claude)"; return 1; }

  local kits mp k installed
  kits="$(kits_for_role "$ROLE")"
  if needs_private_marketplace "$kits"; then mp="software-factory-tools"; else mp="pm-skills"; fi
  installed="$(claude plugin list 2>/dev/null | tr '\n' ' ')"

  for k in $kits; do
    case " $installed " in
      *"$k"*) ok "$k already installed"; continue ;;
    esac
    if claude plugin install "$k@$mp" >/dev/null 2>&1; then
      ok "installed $k"
    else
      bad "could not install $k"; note_fail "plugin $k"
    fi
  done

  # audit-kit's optional scanners. The installer ships INSIDE the plugin, so its
  # path is only knowable after the install above — and the plugin cache is
  # content-hash addressed, so it must be discovered rather than constructed.
  case " $kits " in
    *" audit-kit "*)
      local s; s="$(find "$HOME/.claude/plugins" -path '*audit-kit*' -name 'install-scanners.sh' -type f 2>/dev/null | head -1)"
      if [ -n "$s" ]; then
        if [ "$ASSUME_YES" = "1" ] || confirm "install audit-kit's scanners (semgrep, gitleaks, trivy, osv-scanner, pip-audit)?"; then
          bash "$s" --yes && ok "scanners" || { warn "some scanners did not install"; note_fail "audit scanners (re-run: $s)"; }
        else
          say "skipped — audit-kit still works, it degrades to LLM-only analysis and says so"
        fi
      else
        warn "scanner installer not found — run /audit-install-scanners inside Claude Code"
      fi
      ;;
  esac
}

# The rc file the user's OWN shell will actually read on a new session.
#
# Not a cosmetic choice. On macOS the default shell is zsh and a fresh account
# frequently has no ~/.zshrc at all; on Linux it is bash and ~/.bashrc. Picking
# the wrong one — or skipping because the file is absent — writes credentials
# that are never loaded.
#
# macOS bash is the subtle case: Terminal starts LOGIN shells, which read
# ~/.bash_profile and never ~/.bashrc.
primary_rc() {
  case "$(basename "${SHELL:-/bin/bash}")" in
    zsh)  echo "${ZDOTDIR:-$HOME}/.zshrc" ;;
    bash) if [ "$PLATFORM" = "macos" ]; then echo "$HOME/.bash_profile"; else echo "$HOME/.bashrc"; fi ;;
    *)    echo "$HOME/.profile" ;;
  esac
}

# Append a line to the shell rc exactly once, keyed by a marker.
#
# CREATES the primary rc if it is missing. The previous version skipped absent
# files, which on a fresh Mac (no ~/.zshrc) meant the credential file was
# written and the line that loads it never was — a 0600 file that looks like
# working configuration and is read by nothing.
rc_ensure() {
  local line="$1" marker="$2" rc primary
  primary="$(primary_rc)"
  [ -f "$primary" ] || { touch "$primary" 2>/dev/null && say "created $primary"; }
  for rc in "$primary" "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.bash_profile"; do
    [ -f "$rc" ] || continue
    grep -qF "$marker" "$rc" 2>/dev/null && continue
    printf '\n%s\n%s\n' "$marker" "$line" >> "$rc"
  done
}

save_secret() {
  local name="$1" value="$2"
  mkdir -p "$DEVHAWK_HOME" 2>/dev/null
  touch "$ENV_FILE" 2>/dev/null
  chmod 600 "$ENV_FILE" 2>/dev/null
  # Replace any existing line for this variable rather than appending a second.
  if grep -q "^export $name=" "$ENV_FILE" 2>/dev/null; then
    local tmp="$ENV_FILE.tmp.$$"
    grep -v "^export $name=" "$ENV_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$ENV_FILE"
    chmod 600 "$ENV_FILE" 2>/dev/null
  fi
  printf "export %s='%s'\n" "$name" "$value" >> "$ENV_FILE"
  rc_ensure '[ -f "$HOME/.devhawk/env" ] && . "$HOME/.devhawk/env"' '# devhawk: local credentials'
}

phase_credentials() {
  step "5/5  Credentials — all optional"
  say "Everything below can be skipped. The kits are fully usable without any of it."

  # --- Asana: delegate entirely to /pm-setup, which already does OAuth, guest
  # --- PATs, a venv and a 0600 workspace.json. Reimplementing it here would be
  # --- the start of the installer we deleted.
  case " $(kits_for_role "$ROLE") " in
    *" pm-kit "*)
      local ps; ps="$(find "$HOME/.claude/plugins" -path '*pm-kit*' -name 'pm-setup.sh' -type f 2>/dev/null | head -1)"
      if [ -n "$ps" ]; then
        if [ "$ASSUME_YES" = "1" ]; then
          say "Asana: run /pm-setup inside Claude Code (needs an interactive browser login)"
        elif confirm "set up pm-kit's Python runtime and Asana access now?"; then
          bash "$ps" </dev/tty || note_fail "pm-setup (re-run: $ps)"
        else
          say "skipped — run /pm-setup inside Claude Code whenever you want it"
        fi
      else
        say "Asana: run /pm-setup inside Claude Code once the plugins have loaded"
      fi
      ;;
  esac

  [ "$ASSUME_YES" = "1" ] && { say "skipping remaining prompts under --yes"; return 0; }

  # --- Shortcut: a plain token, and pm-kit reads it directly.
  if confirm "record a Shortcut API token?"; then
    local t; t="$(read_secret 'SHORTCUT_API_TOKEN')"
    [ -n "$t" ] && { save_secret SHORTCUT_API_TOKEN "$t"; ok "saved to $ENV_FILE (0600)"; } || warn "nothing entered — skipped"
  fi

  # --- The factory engine. OPTIONAL, and the wording matters: people read the
  # --- script's name and assume the engine is required. It is not.
  printf '\n'
  say "The factory engine is a separate service. If you do not use one, skip this —"
  say "every kit works without it, and no skill will mention it."
  if confirm "connect this machine to a factory engine?"; then
    local t; t="$(read_secret 'FACTORY_API_TOKEN')"
    if [ -n "$t" ]; then
      save_secret FACTORY_API_TOKEN "$t"
      ok "saved to $ENV_FILE (0600)"
      warn "RESTART Claude Code before this takes effect"
      say "MCP servers are resolved at startup, so a token exported into a running"
      say "session changes nothing — this is the most common 'the tools don't exist' report."
    else
      warn "nothing entered — skipped"
    fi
  else
    say "skipped — nothing here depends on it"
  fi
}

# ── main ────────────────────────────────────────────────────────────────────
detect_platform

if [ "$CHECK_ONLY" = "1" ]; then report_state; exit 0; fi

case "$PLATFORM" in
  wsl|macos|linux) ;;
  *) echo "factory-setup: unsupported platform '$(uname -s)'" >&2; exit 2 ;;
esac

printf '\n\033[1mfactory-setup\033[0m — prerequisites, marketplace, plugins, credentials\n'
say "platform: $PLATFORM"
say "you will be asked for your password once, for system packages"

prompt_role
say "role: $ROLE  →  $(kits_for_role "$ROLE")"

phase_prereqs
phase_github
phase_marketplace
phase_plugins
phase_credentials

# ── summary ─────────────────────────────────────────────────────────────────
step "Done"
if [ -n "$FAILED" ]; then
  bad "some steps did not complete:"
  printf '%s' "$FAILED" | sed 's/^/      - /'
  printf '\n'
  say "everything else finished. Re-running this script is safe and will retry only these."
else
  ok "everything completed"
fi

printf '\n'
say "Next: restart your terminal, then start Claude Code and run /help to see the skills."
say "Re-run with --check at any time to see the state of this machine."
printf '\n'
