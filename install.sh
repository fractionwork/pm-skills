#!/usr/bin/env bash
# Fraction PM Skills — installer
#
# Copies the PM-only skills, scripts, and memories from this bundle into
# the user's ~/.claude/ directories so Claude Code can run them.
# Idempotent — safe to re-run after updates.
#
# Usage:
#   # Local clone:
#   bash install.sh                # interactive
#   bash install.sh --dry-run      # show what would change, do nothing
#   bash install.sh --systems=asana,shortcut  # skip the multi-select prompt
#
#   # Curl one-liner (auto-clones the repo into a tmp dir):
#   curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash
#   curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash -s -- --dry-run

set -euo pipefail

REPO_URL="${PM_SKILLS_REPO_URL:-https://github.com/fractionwork/pm-skills.git}"
REPO_BRANCH="${PM_SKILLS_REPO_BRANCH:-main}"

# /dev/tty probe — wrapped in a subshell because bash sometimes prints
# redirect-failure errors to the original stderr even when 2>/dev/null
# is on the same line. The subshell's stderr is fully captured.
has_tty() { (exec </dev/tty) 2>/dev/null; }

# ── Self-fetch path ────────────────────────────────────────────────────
# When invoked via `curl ... | bash`, BASH_SOURCE is empty / the script
# isn't on disk, and the bundle files (skills/, scripts/, memory/) aren't
# alongside us. Clone the repo into a temp dir and re-exec from there
# with the original args preserved.
SCRIPT_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ -f "${BASH_SOURCE[0]}" ]]; then
  SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

if [[ -z "$SCRIPT_PATH" ]] || [[ ! -d "$SCRIPT_PATH/skills" ]]; then
  if ! command -v git >/dev/null 2>&1; then
    echo "✗ git is required for the curl-pipe install path" >&2
    echo "  Install git first, or clone the repo manually:" >&2
    echo "    git clone $REPO_URL && cd pm-skills && bash install.sh" >&2
    exit 1
  fi
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  echo "→ Fetching pm-skills..."
  if ! git clone --depth=1 --branch "$REPO_BRANCH" --quiet "$REPO_URL" "$TMP/pm-skills"; then
    echo "✗ Failed to clone $REPO_URL" >&2
    exit 1
  fi
  cd "$TMP/pm-skills"
  # Re-exec with stdin redirected to the terminal — when piped via curl,
  # the original stdin is the curl output (EOF by now), so any later
  # `read` prompt would return immediately and abort the install.
  # Test the redirect itself (file existence isn't enough — the process
  # group may have no controlling terminal even when /dev/tty exists).
  if has_tty; then
    exec bash install.sh "$@" </dev/tty
  else
    exec bash install.sh "$@"
  fi
fi

DRY_RUN=0
SYSTEMS_ARG=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --systems=*) SYSTEMS_ARG="${arg#--systems=}" ;;
    -h|--help)
      sed -n '1,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown arg: $arg" >&2
      exit 1
      ;;
  esac
done

BUNDLE_DIR="$SCRIPT_PATH"
CLAUDE_HOME="${CLAUDE_HOME:-$HOME/.claude}"
SKILLS_DIR="$CLAUDE_HOME/skills"
SCRIPTS_DIR="$CLAUDE_HOME/scripts"
ENV_FILE="$CLAUDE_HOME/.env"
USER_CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"

say() { printf "  %s\n" "$*"; }
ok()  { printf "  ✓ %s\n" "$*"; }
warn(){ printf "  ⚠ %s\n" "$*"; }
err() { printf "  ✗ %s\n" "$*" >&2; }

do_step() {
  if [[ $DRY_RUN -eq 1 ]]; then
    say "(dry-run) $*"
  else
    eval "$@"
  fi
}

echo ""
echo "Fraction PM Skills installer"
echo "============================"
echo ""

# ── Step 1: Prereq check ─────────────────────────────────────────────
echo "1. Checking prerequisites..."
if ! command -v claude >/dev/null 2>&1; then
  err "Claude Code CLI not found in PATH."
  err "  Install it first: https://docs.claude.com/en/docs/claude-code/installation"
  exit 1
fi
ok "Claude Code: $(claude --version 2>/dev/null || echo 'present')"

if ! command -v python3 >/dev/null 2>&1; then
  err "python3 not found — required by asana_ops.py / shortcut_ops.py"
  exit 1
fi
ok "python3: $(python3 --version)"

if ! python3 -c 'import requests' 2>/dev/null; then
  warn "Python 'requests' module not installed."
  warn "  Install with: pip install --user requests"
fi

# Pre-create the Claude Code home and its standard subdirs so the rest of
# the installer can drop files in unconditionally — even if the PM has
# never opened Claude Code before. mkdir -p creates parents and is a
# no-op if the dir already exists.
do_step "mkdir -p '$CLAUDE_HOME' '$SKILLS_DIR' '$SCRIPTS_DIR'"
ok "Claude home ready: $CLAUDE_HOME"

# ── Step 2: System selection ─────────────────────────────────────────
echo ""
echo "2. Which PM systems do you use?"

if [[ -n "$SYSTEMS_ARG" ]]; then
  IFS=',' read -ra SYSTEMS <<< "$SYSTEMS_ARG"
else
  echo "   Choose all that apply (space-separated, e.g. '1 2'):"
  echo "     1) Asana"
  echo "     2) Shortcut"
  echo "     3) Linear"
  echo "     4) Jira"
  echo ""
  if has_tty; then
    read -rp "  > " choice </dev/tty
  else
    err "Interactive prompt needed but no terminal available."
    err "  Run with --systems=asana,shortcut (or similar) to skip."
    exit 1
  fi
  SYSTEMS=()
  for c in $choice; do
    case "$c" in
      1) SYSTEMS+=(asana) ;;
      2) SYSTEMS+=(shortcut) ;;
      3) SYSTEMS+=(linear) ;;
      4) SYSTEMS+=(jira) ;;
      *) warn "ignoring unknown choice: $c" ;;
    esac
  done
fi

if [[ ${#SYSTEMS[@]} -eq 0 ]]; then
  err "No PM systems selected — nothing to install."
  exit 1
fi
ok "Selected: ${SYSTEMS[*]}"

# ── Step 3: Copy universal skills (add-card, add-comment, card-done) ──
echo ""
echo "3. Installing skills..."
do_step "mkdir -p '$SKILLS_DIR'"
for skill in add-card add-comment card-done; do
  do_step "cp -R '$BUNDLE_DIR/skills/$skill' '$SKILLS_DIR/'"
  ok "skill: $skill"
done

# Per-system hygiene skills
for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      do_step "cp -R '$BUNDLE_DIR/skills/asana-hygiene' '$SKILLS_DIR/'"
      ok "skill: asana-hygiene"
      ;;
    shortcut)
      do_step "cp -R '$BUNDLE_DIR/skills/shortcut-hygiene' '$SKILLS_DIR/'"
      ok "skill: shortcut-hygiene"
      ;;
    linear|jira)
      warn "no hygiene skill bundled yet for $sys (planned)"
      ;;
  esac
done

# ── Step 4: Copy scripts (per system) ─────────────────────────────────
echo ""
echo "4. Installing scripts..."
do_step "mkdir -p '$SCRIPTS_DIR'"
for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      do_step "cp '$BUNDLE_DIR/scripts/asana_ops.py' '$SCRIPTS_DIR/asana_ops.py'"
      ok "script: asana_ops.py"
      ;;
    shortcut)
      do_step "cp '$BUNDLE_DIR/scripts/shortcut_ops.py' '$SCRIPTS_DIR/shortcut_ops.py'"
      ok "script: shortcut_ops.py"
      ;;
  esac
done

# ── Step 5: Install MCP servers + plugins ─────────────────────────────
echo ""
echo "5. Installing MCP servers + plugins..."
for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      # Plugin install is idempotent — second run reports "already installed"
      # and exits 0. Safe to re-run.
      do_step "claude plugin install asana"
      ok "asana plugin: installed (auth on first use inside Claude Code)"
      ;;
    linear)
      # MCP add is idempotent on the same name — overwrites silently.
      do_step "claude mcp add --transport http linear https://mcp.linear.app/mcp"
      ok "linear MCP: configured (auth on first use)"
      ;;
    jira)
      do_step "claude mcp add --transport sse atlassian-rovo https://mcp.atlassian.com/v1/sse"
      ok "atlassian-rovo MCP: configured (auth on first use)"
      ;;
    shortcut)
      say "shortcut: no official MCP — script-based only (token prompt next)"
      ;;
  esac
done

# ── Step 6: Token setup (per system that uses scripts) ────────────────
echo "6. Token setup"
echo "   Tokens for the script-based paths land in $ENV_FILE (chmod 600)."
echo ""

setup_token() {
  local var="$1"
  local where="$2"
  local current=""
  if [[ -f "$ENV_FILE" ]]; then
    current=$(grep -E "^${var}=" "$ENV_FILE" || true)
  fi
  if [[ -n "$current" ]]; then
    say "$var: already set in $ENV_FILE — skipping (rotate manually if needed)"
    return
  fi
  echo ""
  echo "   $var"
  echo "   Generate at: $where"
  if has_tty; then
    read -rp "   Paste token (or leave blank to skip): " token </dev/tty
  else
    warn "no terminal available — skipping (set ${var}=... in $ENV_FILE manually)"
    return
  fi
  if [[ -z "$token" ]]; then
    warn "skipped — set later by adding ${var}=... to $ENV_FILE"
    return
  fi
  do_step "touch '$ENV_FILE' && chmod 600 '$ENV_FILE'"
  do_step "printf '%s=%s\n' '$var' '$token' >> '$ENV_FILE'"
  ok "$var saved"
}

for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      # Two Asana auth surfaces:
      #   1. MCP plugin — OAuth via Anthropic's app, on first use inside Claude Code.
      #      Can't be triggered from the shell; the user grants consent in Claude Code.
      #   2. asana_ops.py script — PKCE OAuth, browser flow, can run NOW from this
      #      installer. Token stored in .asana-token.json next to the script.
      echo ""
      echo "   Asana auth has two surfaces:"
      echo "     • MCP plugin: granted in Claude Code on first Asana operation (browser OAuth)"
      echo "     • asana_ops.py script: PKCE OAuth (browser, captures localhost callback)"
      echo ""
      if [[ -f "$SCRIPTS_DIR/.asana-token.json" ]]; then
        say "asana_ops.py: token already present — skipping (delete to re-auth)"
      elif has_tty; then
        read -rp "   Auth asana_ops.py now? Opens a browser. [Y/n]: " ans </dev/tty
        ans="${ans:-Y}"
        if [[ "${ans^^}" == "Y" ]]; then
          if [[ $DRY_RUN -eq 1 ]]; then
            say "(dry-run) python3 '$SCRIPTS_DIR/asana_ops.py' --auth"
          else
            (cd "$SCRIPTS_DIR" && python3 ./asana_ops.py --auth) || \
              warn "asana_ops.py auth failed — re-run later: python3 $SCRIPTS_DIR/asana_ops.py --auth"
          fi
        else
          say "Skipped — run later: python3 $SCRIPTS_DIR/asana_ops.py --auth"
          say "  Or paste a PAT: append ASANA_PAT=<token> to $ENV_FILE"
        fi
      else
        warn "no terminal — auth later: python3 $SCRIPTS_DIR/asana_ops.py --auth"
      fi
      ;;
    shortcut)
      setup_token SHORTCUT_API_TOKEN "https://app.shortcut.com/settings/account/api-tokens"
      ;;
    linear|jira)
      say "$sys: MCP OAuth happens on first use inside Claude Code — nothing to set up here"
      ;;
  esac
done

# ── Step 7: PM operating-rules in user CLAUDE.md ──────────────────────
# These rules used to ship as separate "memory" files, but Claude Code's
# auto-memory system is per-project — files dropped at $CLAUDE_HOME/memory/
# don't load in any session. The user-global $CLAUDE_HOME/CLAUDE.md is
# the right surface for rules that should apply across every project.
echo ""
echo "7. PM operating mode in $USER_CLAUDE_MD"
PM_CLAUDE_TEMPLATE="$BUNDLE_DIR/PM-CLAUDE.md"

if [[ ! -f "$PM_CLAUDE_TEMPLATE" ]]; then
  warn "PM-CLAUDE.md template missing from bundle — skipping"
else
  if [[ -f "$USER_CLAUDE_MD" ]] && grep -q "Fraction PM operating mode" "$USER_CLAUDE_MD"; then
    say "PM section already present — skipping"
  else
    if [[ ! -f "$USER_CLAUDE_MD" ]]; then
      do_step "cp '$PM_CLAUDE_TEMPLATE' '$USER_CLAUDE_MD'"
      ok "created $USER_CLAUDE_MD"
    else
      do_step "{ echo ''; cat '$PM_CLAUDE_TEMPLATE'; } >> '$USER_CLAUDE_MD'"
      ok "appended PM section to $USER_CLAUDE_MD"
    fi
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo "============================"
echo "Install complete."
echo ""
echo "Next:"
for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      echo "  • Asana MCP plugin: first MCP operation in Claude Code will open the browser for OAuth"
      ;;
    linear)
      echo "  • Linear MCP: first MCP operation in Claude Code will prompt for OAuth"
      ;;
    jira)
      echo "  • Jira (Atlassian Rovo) MCP: first MCP operation in Claude Code will prompt for OAuth"
      ;;
    shortcut)
      echo "  • Shortcut: token in $ENV_FILE is used by the script — no further setup"
      ;;
  esac
done
echo "  • Open Claude Code and try: 'add a ticket about X to <project>'"
echo "  • Re-run anytime to update: curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash"
echo ""
