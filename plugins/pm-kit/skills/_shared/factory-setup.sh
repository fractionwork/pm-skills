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
# Whether this run put anything new on PATH. Drives the closing notice: a
# "restart your terminal" banner that fires every time is one people stop
# reading, and then miss on the one run where it mattered.
PATH_CHANGED=0

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

# Where a LINUX `claude` lives, or nothing.
#
# `have claude` is not good enough on WSL. Interop puts the Windows PATH inside
# the distro — 19 `/mnt/c` entries on a stock box — so a Claude Code installed on
# Windows answers `command -v claude` perfectly well, and the script then reports
# it as present and installs nothing. That is exactly the install docs/
# prerequisites.md tells people they cannot reuse: calling it from WSL reaches
# the Linux project over the 9P filesystem, every file operation crosses a VM
# boundary, and path translation breaks the plugin scripts.
#
# So the WSL symptom is "Claude Code is missing" reported by a user whose script
# said it was fine. Resolve the path and reject anything under /mnt or ending
# .exe; the caller installs a native one regardless of what Windows offers.
# The rule itself, pure and separate from PATH lookup so it can be tested
# against real Windows paths — which a test cannot create under /mnt.
# `/mnt/*` is where WSL mounts the Windows drives; `*.exe` covers a Windows
# binary reached some other way (a symlink into $HOME, a wrapper on $PATH).
is_windows_path() {
  case "$1" in /mnt/*|*.exe) return 0 ;; *) return 1 ;; esac
}

native_claude() {
  local p; p="$(command -v claude 2>/dev/null)" || return 1
  is_windows_path "$p" && return 1
  printf '%s\n' "$p"
}

# A Windows claude reachable from this distro — reported, never used.
windows_claude() {
  local p; p="$(command -v claude 2>/dev/null)" || return 1
  is_windows_path "$p" || return 1
  printf '%s\n' "$p"
}

claude_version() { claude --version 2>/dev/null | head -1; }

# Ask. Second argument is the default when the human just presses Enter:
# `yes` (the default) for "shall I install this", `no` for anything that
# records a credential.
#
# Credential prompts default to NO deliberately. They are optional extras, and
# the old single-mode `[Y/n]` meant Enter — or any answer the case did not
# recognise — opted you IN to being asked for a secret you had just been told
# was optional. Reported from a real run: "I said no to shortcut, still asked
# for an api key."
#
# A read that FAILS also answers no now. It used to `return 0`, so losing the
# terminal was indistinguishable from consent — the worst possible direction for
# a prompt whose next step is "type your token".
confirm() {
  local prompt="$1" default="${2:-yes}" reply=""
  [ "$ASSUME_YES" = "1" ] && { [ "$default" = "yes" ] && return 0 || return 1; }
  if [ "$default" = "yes" ]; then printf '  %s [Y/n] ' "$prompt"
  else printf '  %s [y/N] ' "$prompt"; fi
  read -r reply </dev/tty 2>/dev/null || { printf '\n'; return 1; }
  reply="$(printf '%s' "$reply" | tr -d '[:space:]')"
  case "$reply" in
    [Yy]*) return 0 ;;
    [Nn]*) return 1 ;;
    '')    [ "$default" = "yes" ] && return 0 || return 1 ;;
    # Anything else is NOT consent. Say so rather than guessing.
    *)     say "not understood — taking that as no"; return 1 ;;
  esac
}

# Read a secret without echoing it, and never accept one from a pipe — a value
# arriving on stdin is far more likely to be the next line of a script than a
# token a human meant to type.
read_secret() {
  # Guard on /dev/tty, NOT on stdin. The requirement is "a human is at a
  # terminal", and `[ -t 0 ]` only approximates that: it is false whenever stdin
  # is redirected, which includes `curl | bash` and — the case that actually bit
  # — the inside of a `while read` loop fed by a heredoc. There the prompt was
  # skipped silently and the credential was never recorded, with no error.
  [ -r /dev/tty ] || { echo ""; return 1; }
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

BINFMT_DIR="/proc/sys/fs/binfmt_misc"

# Windows interop: whether this distro can execute Windows binaries.
#
# Everything that opens a browser from WSL — wslview, PowerShell's Start-Process,
# and therefore the Asana OAuth callback and any browser login — works by running
# a Windows binary from inside the distro. With interop off there is no error to
# find: `powershell.exe` is simply "command not found", Python's webbrowser finds
# no handler, and a sign-in appears to hang. Checked once, here, where the fix can
# be explained rather than guessed at.
interop_enabled() {
  local f
  for f in "$BINFMT_DIR/WSLInterop" "$BINFMT_DIR/WSLInterop-late"; do
    [ -e "$f" ] || continue
    head -1 "$f" 2>/dev/null | grep -qi '^enabled' && return 0
  done
  return 1
}
windows_on_path() { have powershell.exe || have pwsh.exe || have cmd.exe; }

# An unresolvable hostname makes EVERY sudo print two scary lines:
#
#   sudo: unable to resolve host factory-demo: Name or service not known
#
# It is only a warning — sudo still works — but it appears in the middle of the
# install, twice per call, and reads as the installer failing. It happens the
# moment somebody renames a WSL distro without updating /etc/hosts, which is a
# perfectly reasonable thing to do before a demo.
#
# Fixed here rather than explained, because the fix is one line and the
# explanation is three paragraphs.
check_hostname() {
  local h
  h="$(hostname 2>/dev/null)" || return 0
  [ -n "$h" ] || return 0
  getent hosts "$h" >/dev/null 2>&1 && return 0

  say "hostname \"$h\" does not resolve — sudo will warn on every call"
  if grep -qE "^127\.0\.1\.1[[:space:]]" /etc/hosts 2>/dev/null; then
    sudo sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$h/" /etc/hosts 2>/dev/null
  else
    printf '127.0.1.1\t%s\n' "$h" | sudo tee -a /etc/hosts >/dev/null 2>&1
  fi

  if getent hosts "$h" >/dev/null 2>&1; then
    ok "hostname resolves ($h)"
    # WSL rewrites /etc/hosts on boot unless told not to, so the fix above is
    # good for this session only.
    if [ "$PLATFORM" = "wsl" ] && ! grep -q "generateHosts" /etc/wsl.conf 2>/dev/null; then
      say "to make it stick across reboots, add to /etc/wsl.conf (APPEND — do not"
      say "overwrite, the [interop] block lives there too):"
      say "    [network]"
      say "    hostname = $h"
      say "    generateHosts = false"
    fi
  else
    warn "could not make \"$h\" resolve — sudo will keep warning, harmlessly"
    note_fail "hostname resolution (add '127.0.1.1 $h' to /etc/hosts)"
  fi
}

# Set a key inside a named section of an INI file, creating the section if it is
# absent and leaving every OTHER section untouched.
#
# Section-aware on purpose. /etc/wsl.conf routinely carries [boot], [network]
# and [user] alongside [interop], and the obvious `printf >> wsl.conf` produces
# a SECOND [interop] section — which WSL resolves in a way nobody can predict
# from reading the file. Appending is how you break a config while believing you
# extended it.
ini_set() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  tmp="$(mktemp)" || return 1
  sudo touch "$file" 2>/dev/null
  # Trailing blank lines are BUFFERED so an inserted key lands with the rest of
  # its section rather than after the gap that separates it from the next one.
  # Cosmetic, but a config that looks mangled invites someone to "fix" it.
  awk -v sect="$section" -v key="$key" -v val="$value" '
    function flush_blanks(  i) { for (i = 1; i <= nb; i++) print ""; nb = 0 }
    BEGIN { in_s = 0; done = 0; nb = 0 }
    /^[[:space:]]*$/ { if (in_s) { nb++; next } print; next }
    /^[[:space:]]*\[/ {
      if (in_s && !done) { print key " = " val; done = 1 }
      flush_blanks()
      in_s = ($0 ~ "^[[:space:]]*\\[" sect "\\][[:space:]]*$")
      if (in_s) seen = 1
      print; next
    }
    {
      flush_blanks()
      if (in_s && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        if (!done) { print key " = " val; done = 1 }
        next
      }
      print
    }
    END {
      if (in_s && !done) { print key " = " val; done = 1 }
      flush_blanks()
      if (!seen) { print ""; print "[" sect "]"; print key " = " val }
    }
  ' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  sudo cp "$tmp" "$file" && rm -f "$tmp"
}

check_interop() {
  [ "$PLATFORM" = "wsl" ] || return 0
  if interop_enabled && windows_on_path; then
    ok "Windows interop (browser sign-in will work)"
    return 0
  fi
  if interop_enabled; then
    warn "interop is on, but Windows is not on PATH"
    if ini_set /etc/wsl.conf interop appendWindowsPath true; then
      ok "set appendWindowsPath in /etc/wsl.conf"
      say "run 'wsl --shutdown' from Windows PowerShell to apply."
      note_fail "Windows on PATH (config written — run 'wsl --shutdown' to apply)"
    else
      note_fail "Windows on PATH (see /etc/wsl.conf: [interop] appendWindowsPath=true)"
    fi
    return 1
  fi
  bad "Windows interop is DISABLED — browser sign-in cannot open"
  if ini_set /etc/wsl.conf interop enabled true && ini_set /etc/wsl.conf interop appendWindowsPath true; then
    ok "wrote [interop] to /etc/wsl.conf"
    warn "NOT active until the distro restarts"
    say "from Windows PowerShell:  wsl --shutdown"
    say "interop is registered at boot, so closing the terminal is not enough."
    note_fail "Windows interop (config written — run 'wsl --shutdown' to apply)"
  else
    say "could not write /etc/wsl.conf; add by hand:"
    say "    [interop]"
    say "    enabled = true"
    say "    appendWindowsPath = true"
    note_fail "Windows interop (edit /etc/wsl.conf, then wsl --shutdown)"
  fi
  return 1
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
# NEVER USE AN INTERACTIVE SHELL (`-i`) TO PROBE THIS. It looks like the obvious
# way to pick up an rc file, and it SUSPENDS THIS SCRIPT: an interactive shell
# sets up job control and reaches for the terminal's foreground process group,
# so the caller takes SIGTTIN/SIGTTOU and stops dead with `[1]+ Stopped`. It
# happened here, on WSL, immediately after a sudo prompt. A version check must
# not be able to halt the installer.
#
# The problem `-i` was reaching for is real, though: macOS defaults to zsh, nvm
# appends to ~/.zshrc, and neither `bash -lc` (reads ~/.bash_profile) nor
# `zsh -lc` (does not read .zshrc — that file is for interactive shells) would
# ever see it.
#
# The fix is to source what we want EXPLICITLY in a non-interactive shell, and
# to ask nvm directly rather than inferring it from a login shell's behaviour:
#
#   1. plain login shell         — covers a system node on PATH
#   2. rc file, sourced by hand  — covers nvm written into .zshrc / .bashrc
#   3. nvm.sh, sourced directly  — covers it regardless of any rc file at all
#
# Every probe gets `</dev/null` so nothing can block on terminal input.
login_node_version() {
  local sh rc v probe bin
  sh="${SHELL:-/bin/bash}"
  rc="$(primary_rc)"

  for probe in \
    'command -v node >/dev/null 2>&1 && node -v' \
    "[ -r '$rc' ] && . '$rc' >/dev/null 2>&1; command -v node >/dev/null 2>&1 && node -v" \
    'export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null 2>&1; command -v node >/dev/null 2>&1 && node -v'
  do
    for bin in "$sh" /bin/bash; do
      [ -x "$bin" ] || continue
      v="$("$bin" -c "$probe" </dev/null 2>/dev/null | tr -d '\r' | grep -E '^v?[0-9]+\.' | head -1)"
      [ -n "$v" ] && { echo "$v"; return 0; }
    done
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

  if getent hosts "$(hostname 2>/dev/null)" >/dev/null 2>&1; then
    ok "hostname resolves ($(hostname))"
  else
    warn "hostname $(hostname) does not resolve — sudo warns on every call"
  fi
  if [ "$PLATFORM" = "wsl" ]; then
    if interop_enabled && windows_on_path; then ok "Windows interop"
    elif interop_enabled; then warn "interop on, but Windows not on PATH — browser sign-in may not open"
    else bad "Windows interop DISABLED — browser sign-in cannot open"; fi
  fi
  have git && ok "git ($(git --version 2>/dev/null | awk '{print $3}'))" || bad "git missing"
  have curl && ok "curl" || bad "curl missing"

  local v; v="$(login_node_version)"
  if [ -z "$v" ]; then bad "node not found in a login shell"
  elif node_ok; then ok "node $v (login shell)"
  else bad "node $v — below the $NODE_MAJOR floor"; fi

  local py; if py="$(find_python)"; then ok "python: $py ($($py -V 2>&1))"; else warn "no python >= $PYTHON_MIN (pm-kit's Asana MCP needs one)"; fi

  if native_claude >/dev/null; then ok "claude ($(claude_version))"
  elif local win; win="$(windows_claude)"; then
    bad "only a WINDOWS Claude Code is on PATH ($win) — it cannot drive a Linux project"
  else bad "Claude Code missing"; fi

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

  # apt on Ubuntu 22.04+ can go INTERACTIVE mid-install even with -y: debconf
  # raises config prompts, and `needrestart` opens a whiptail dialog asking which
  # services to restart. Both read the terminal, and a script that is not the
  # foreground process group takes SIGTTIN and stops. Neither fires on a machine
  # where the packages are already present, which is why this never reproduces on
  # a developer box and bites only a fresh distro.
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1

  # Before any sudo, so its warnings never appear at all.
  check_hostname
  check_interop

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
      sudo apt-get update -qq 2>/dev/null </dev/null
      if sudo apt-get install -y -qq git curl python3-venv >/dev/null 2>&1 </dev/null; then
        ok "base packages (git, curl, python3-venv)"
      else
        bad "could not install base packages"; note_fail "base packages"
      fi
      # wslview lets OAuth open a real browser instead of File Explorer. Optional.
      [ "$PLATFORM" = "wsl" ] && { sudo apt-get install -y -qq wslu >/dev/null 2>&1 </dev/null && ok "wslu (browser handoff)" || warn "wslu unavailable — links may not open"; }
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
           NONINTERACTIVE=1 bash /tmp/brew-install.sh >/dev/null 2>&1 </dev/null; then
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
      confirm "install python@3.12 via brew?" && { brew install python@3.12 >/dev/null 2>&1 </dev/null && ok "python@3.12" || note_fail "python@3.12"; }
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
         bash /tmp/nvm-install.sh >/dev/null 2>&1 </dev/null; then
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
  #
  # INSTALL OR UPDATE, not install-if-absent. A box that already had it kept
  # whatever version it had forever, so re-running the one-liner — the documented
  # way to fix a machine — never actually refreshed the tool the whole kit runs
  # inside.
  install_or_update_claude
}

# Install Claude Code, or update the one that is already here.
install_or_update_claude() {
  local win; win="$(windows_claude)" && {
    # Reported before anything else: on WSL this is why `have claude` used to
    # succeed while the user had no usable Claude Code. Not an error — we just
    # install the native one alongside it and let PATH order sort itself out.
    warn "found a WINDOWS Claude Code on PATH ($win)"
    say "that one cannot drive a Linux project — installing the native build"
  }

  if native_claude >/dev/null; then
    local before; before="$(claude_version)"
    ok "Claude Code ($before)"
    # `claude update` is the tool's own updater and a no-op when current, so
    # this is safe to run on every pass. Failure is NOT fatal: an up-to-date
    # install that cannot reach the update server still works fine, and dying
    # here would skip the marketplace and every plugin.
    if claude update >/dev/null 2>&1; then
      local after; after="$(claude_version)"
      [ "$after" != "$before" ] && ok "updated to $after"
    else
      warn "could not check for updates — continuing with $before"
    fi
    return 0
  fi

  # Keep the installer's own output. It used to go to /dev/null, so the only
  # thing a failed install could say was "could not install Claude Code" — no
  # reason, nothing to act on, on the one step everything after it depends on.
  local log="${TMPDIR:-/tmp}/factory-claude-install.log"
  if curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh 2>>"$log" &&
     bash /tmp/claude-install.sh >>"$log" 2>&1 </dev/null; then
    # The installer drops the binary in ~/.local/bin (or ~/.claude/local) and
    # edits an rc file — neither of which helps THIS shell. Telling the user
    # to open a new terminal was not a cosmetic wart: phases 3 and 4 then find
    # no `claude`, so the marketplace and every plugin are skipped, and the
    # script completes "successfully" having installed nothing it exists to
    # install. Only a fresh box shows this, because anywhere else claude is
    # already on PATH.
    adopt_path "$HOME/.local/bin" "$HOME/.claude/local" "$HOME/bin"
    if native_claude >/dev/null; then
      ok "Claude Code ($(claude_version))"
    else
      bad "installed but not on PATH — the marketplace and plugin steps cannot run"
      say "find it with:  ls ~/.local/bin/claude ~/.claude/local/claude 2>/dev/null"
      note_fail "claude on PATH (re-run this script from a new terminal)"
    fi
  else
    bad "could not install Claude Code"
    say "installer output: $log"
    # The last few lines are almost always the reason (no curl, TLS failure, a
    # read-only HOME). Showing them beats sending someone to a file they will
    # not open.
    [ -s "$log" ] && tail -3 "$log" | while IFS= read -r l; do say "$l"; done
    note_fail "Claude Code"
  fi
}

# Put directories on PATH for THIS shell and for future ones.
#
# Every installer here writes somewhere that is not yet on PATH — nvm, pipx,
# Claude Code, and the scanner binaries all do it — and each one edits an rc
# file that the running script will never read. Without this the script installs
# a tool and then cannot see it, one step later.
adopt_path() {
  local d
  for d in "$@"; do
    [ -d "$d" ] || continue
    case ":$PATH:" in
      *":$d:"*) ;;
      # A directory that was NOT already here means the user's own shell is now
      # behind — which is the whole condition for the closing notice.
      *) PATH="$d:$PATH"; export PATH; PATH_CHANGED=1 ;;
    esac
    rc_ensure "case \":\$PATH:\" in *\":$d:\"*) ;; *) PATH=\"$d:\$PATH\" ;; esac" "# devhawk: $d on PATH"
  done
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
      brew install gh >/dev/null 2>&1 </dev/null && ok "gh" || { bad "could not install gh"; note_fail "gh"; return 1; }
    elif have apt-get; then
      # GitHub's own apt repo — Ubuntu's copy lags well behind.
      sudo mkdir -p -m 755 /etc/apt/keyrings 2>/dev/null
      if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg 2>/dev/null \
           | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null 2>&1; then
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt-get update -qq 2>/dev/null </dev/null
      fi
      sudo apt-get install -y -qq gh >/dev/null 2>&1 </dev/null && ok "gh" || { bad "could not install gh"; note_fail "gh"; return 1; }
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

  # pm-kit's Python runtime. `--deps-only` builds the venv and exits BEFORE the
  # authenticate step, which is the split that matters: the venv is a property
  # of this MACHINE, and the Asana credential is a property of a PROJECT. The
  # runtime belongs here with the other plugin runtimes; the credential belongs
  # at onboarding with every other board credential.
  case " $kits " in
    *" pm-kit "*)
      local ps; ps="$(find "$HOME/.claude/plugins" -path '*pm-kit*' -name 'pm-setup.sh' -type f 2>/dev/null | head -1)"
      if [ -n "$ps" ]; then
        if bash "$ps" --deps-only >/dev/null 2>&1 </dev/null; then
          ok "pm-kit Python runtime"
        else
          warn "pm-kit's Python runtime did not build — run /pm-setup inside Claude Code"
          note_fail "pm-kit runtime (re-run: $ps)"
        fi
      fi
      ;;
  esac

  # audit-kit's optional scanners. The installer ships INSIDE the plugin, so its
  # path is only knowable after the install above — and the plugin cache is
  # content-hash addressed, so it must be discovered rather than constructed.
  case " $kits " in
    *" audit-kit "*)
      # Two of the five scanners — semgrep and pip-audit — are Python CLIs, and
      # install-scanners.sh needs pipx or Homebrew to place them. A fresh Ubuntu
      # has neither, and since 24.04 is PEP 668 "externally managed" the
      # `pip3 --user` fallback is blocked too, so both fail with "no installer
      # for <tool>" while the three binary scanners succeed. Provide pipx here
      # rather than let two of five silently drop.
      if ! have pipx && ! have brew; then
        if have apt-get; then
          if sudo apt-get install -y -qq pipx >/dev/null 2>&1 </dev/null; then
            ok "pipx (for the Python scanners)"
            pipx ensurepath >/dev/null 2>&1 </dev/null || true
            # ensurepath only edits the rc file; this shell still needs it, or
            # the very next `have pipx` fails on a box that just installed it.
            adopt_path "$HOME/.local/bin"
          else
            warn "could not install pipx — semgrep and pip-audit will be skipped"
          fi
        fi
      fi
      # The binary scanners install into ~/.local/bin. Ubuntu's ~/.profile adds
      # that to PATH only if it EXISTS at login, and it may have just been
      # created — so a new shell would still not find trivy or osv-scanner.
      mkdir -p "$HOME/.local/bin" 2>/dev/null
      adopt_path "$HOME/.local/bin"

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

  # --- Board, channel and transcript credentials are NOT collected here.
  #
  # Not because they do not matter, but because this script is the wrong place
  # to ask. It runs once per MACHINE; those credentials belong to a PROJECT. At
  # install time nobody knows which project this machine will work on, one
  # machine often serves several with different boards, and the values are read
  # by the ENGINE rather than by anything here — so a copy made now is a copy
  # somebody has to move by hand later.
  #
  # `onboard` asks instead, and asks better: it already knows the project's
  # `pm.tool`, so it requests exactly the one board credential that project uses
  # and then PROVES it by listing board fields. Asking here meant offering a
  # Linear shop an Asana prompt and an ADO prompt it would never use.
  printf '\n'
  # Two different destinations, and conflating them told a pm-kit-only user to
  # wait for a prompt that was never coming: `onboard` ships in devhawk-kit, so
  # a PM who installed pm-kit alone will never run it. Lead with the one that
  # applies to everybody.
  say "To drive an Asana board from here, run \`/pm-setup\` inside Claude Code."
  say "The runtime is already installed above; that signs it in. It is the only"
  say "step left for board work on this machine."
  case " $(kits_for_role "$ROLE") " in
    *" devhawk-kit "*)
      say ""
      say "Credentials the ENGINE reads — Linear, Azure DevOps, Fireflies, Slack —"
      say "are not asked for here either. They belong to a project rather than to"
      say "this machine, and \`onboard\` collects them: it knows which board the"
      say "project actually uses and proves each one by using it."
      ;;
  esac

  # --- The factory engine. OPTIONAL, and the wording matters: people read the
  # --- script's name and assume the engine is required. It is not.
  printf '\n'
  say "The factory engine is a separate service. If you do not use one, skip this —"
  say "every kit works without it, and no skill will mention it."
  if confirm "connect this machine to a factory engine?" no; then
    t="$(read_secret 'FACTORY_API_TOKEN')"
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

# The one instruction people actually have to follow, and it used to be the
# QUIETEST line on screen — `say`, four spaces, no colour, at the end of a page
# of output. Reported exactly as you would expect: "ran the installer again,
# claude is still not found." It was installed; the shell that asked had simply
# never re-read its PATH.
#
# So: a banner, the REASON, and a command that fixes it without opening a new
# terminal. Shown only when this run actually changed PATH — a notice that fires
# every time is one people learn to skip, and then miss when it matters.
if [ "$PATH_CHANGED" = "1" ]; then
  printf '\n\033[1;33m%s\033[0m\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  printf '\033[1;33m  ONE MORE STEP — this terminal cannot see the new tools yet\033[0m\n'
  printf '\033[1;33m%s\033[0m\n\n' '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'
  say "claude was installed, but a shell that is already running never re-reads"
  say "its PATH. Until you do one of these it will still say command not found —"
  say "the install is fine, this window is stale."
  printf '\n'
  printf '      \033[1mexec %s -l\033[0m       reload this terminal, right now\n' "${SHELL:-/bin/bash}"
  say "  ...or close this window and open a new one"
  printf '\n'
  say "Then run: claude"
else
  printf '\n'
  say "Next: start Claude Code and run /help to see the skills."
fi
say "Re-run with --check at any time to see the state of this machine."
printf '\n'
