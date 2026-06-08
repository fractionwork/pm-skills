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

# `claude mcp add <name>` refuses with exit 1 if <name> already exists — it does
# NOT overwrite. Under `set -e` that aborts the installer on any re-run, and it
# silently blocks re-registering a server to swap its env (e.g. OAuth → PAT).
# Remove first so every add below is genuinely idempotent. No-op if absent.
# (`claude mcp remove` with no scope removes from whichever scope it exists in,
# so this also clears any stale local-scope entry from an older installer.)
mcp_reset() { do_step "claude mcp remove '$1' >/dev/null 2>&1 || true"; }

# The official `mcp` SDK requires Python >= 3.10. Stock macOS and older Xcode
# Command Line Tools ship python3 = 3.9, where EVERY pip method fails with "no
# matching distribution" — the #1 cause of "could not install deps" on a Mac.
# Echo the newest >=3.10 interpreter on PATH (absolute path), or nothing.
find_py() {
  local c p
  for c in python3.13 python3.12 python3.11 python3.10 python3; do
    command -v "$c" >/dev/null 2>&1 || continue
    if "$c" -c 'import sys; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      command -v "$c"
      return 0
    fi
  done
  return 1
}

# Install the MCP server's Python deps and choose the interpreter Claude Code
# will launch it with (MCP_PYTHON). A dedicated venv is the primary path: it
# sidesteps PEP 668 "externally-managed-environment" errors — Homebrew and
# Debian/Ubuntu system Python refuse `pip install` — AND guarantees the exact
# interpreter we register has the deps. Falls back to user-site installs, then
# warns (registration still happens so the server is at least visible in /mcp).
MCP_PYTHON="python3"
install_mcp_deps() {
  local req="$SCRIPTS_DIR/requirements-mcp.txt"
  local venv="$SCRIPTS_DIR/.venv"
  local py
  py="$(find_py || true)"
  if [[ -z "$py" ]]; then
    MCP_PYTHON="python3"
    warn "the Asana MCP needs Python >= 3.10, but no such interpreter was found."
    warn "    macOS:  brew install python@3.12     (then re-run this installer)"
    warn "    Linux:  install python3.10+ via your package manager, then re-run"
    warn "  The asana MCP is registered but won't start until Python >= 3.10 + deps exist."
    return
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    say "(dry-run) $py -m venv '$venv' && '$venv/bin/pip' install -r '$req'"
    MCP_PYTHON="$venv/bin/python"
    return
  fi
  # Drop any stale/broken venv from a prior run (e.g. one built with old Python).
  rm -rf "$venv" 2>/dev/null || true
  if "$py" -m venv "$venv" >/dev/null 2>&1 && "$venv/bin/pip" install -q -r "$req" >/dev/null 2>&1; then
    MCP_PYTHON="$venv/bin/python"
    ok "MCP deps installed in venv ($("$py" --version 2>&1))"
    return
  fi
  # venv path failed — show the REAL error (don't swallow it), then try user-site.
  warn "venv install failed; underlying error:"
  { "$py" -m venv "$venv" && "$venv/bin/pip" install -r "$req"; } 2>&1 | tail -8 | sed 's/^/    /' || true
  if "$py" -m pip install --user -q -r "$req" >/dev/null 2>&1 \
     || "$py" -m pip install --user --break-system-packages -q -r "$req" >/dev/null 2>&1; then
    MCP_PYTHON="$py"
    ok "MCP deps installed (user site)"
  else
    MCP_PYTHON="$py"
    warn "could not install MCP deps automatically (see error above)."
    warn "    Manual: $py -m venv '$venv' && '$venv/bin/pip' install -r '$req'"
    warn "  The asana MCP is registered but won't start until deps exist."
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
      # First-party MCP server + its deps manifest. asana_mcp.py imports
      # asana_ops.py (above) for auth/REST, so they live side by side.
      do_step "cp '$BUNDLE_DIR/scripts/asana_mcp.py' '$SCRIPTS_DIR/asana_mcp.py'"
      ok "script: asana_mcp.py"
      do_step "cp '$BUNDLE_DIR/scripts/requirements-mcp.txt' '$SCRIPTS_DIR/requirements-mcp.txt'"
      ok "file: requirements-mcp.txt"
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
      # First-party MCP server (scripts/asana_mcp.py) is the preferred Asana
      # surface — it supports BOTH OAuth (full users) and PAT (guests), and
      # exposes curated writes (hygiene/comment/assign/move/capture). The
      # official `asana` plugin offers an overlapping Asana tool surface, so
      # disable it if present for one unambiguous surface (best-effort, no-op
      # otherwise).
      do_step "claude plugin disable asana 2>/dev/null || true"
      install_mcp_deps
      # Register at USER scope so the server appears in /mcp across every project.
      # The default `local` scope keys to the install CWD — a temp clone dir on
      # the curl-pipe path — so a local-scoped server vanishes when that dir is
      # cleaned up. mcp_reset keeps re-runs idempotent. Default wiring is OAuth
      # (ASANA_TOKEN_FILE = where Step 6's --auth writes the token store);
      # ASANA_WORKSPACE_FILE honors a saved "pick once" choice regardless of CWD.
      mcp_reset asana
      do_step "claude mcp add asana --scope user -e ASANA_TOKEN_FILE='$SCRIPTS_DIR/.asana-token.json' -e ASANA_WORKSPACE_FILE='$SCRIPTS_DIR/.asana-workspace.json' -- '$MCP_PYTHON' '$SCRIPTS_DIR/asana_mcp.py'"
      ok "asana MCP: first-party server registered at user scope (auth in step 6)"
      ;;
    linear)
      mcp_reset linear
      do_step "claude mcp add --scope user --transport http linear https://mcp.linear.app/mcp"
      ok "linear MCP: configured (auth on first use)"
      ;;
    jira)
      mcp_reset atlassian-rovo
      do_step "claude mcp add --scope user --transport sse atlassian-rovo https://mcp.atlassian.com/v1/sse"
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
      # One Asana auth, shared by the asana_ops.py CLI AND the first-party MCP
      # (registered in step 5) — the MCP reads the same token store via
      # ASANA_TOKEN_FILE, so authing here lights up both surfaces.
      #   • Full user → OAuth: asana_ops.py --auth (PKCE browser flow) writes
      #     .asana-token.json next to the script. No MCP re-registration needed.
      #   • Guest/service account → PAT: paste it; we save it for the script
      #     AND re-register the MCP with it baked in (ASANA_ACCESS_TOKEN).
      echo ""
      echo "   Asana auth — pick one:"
      echo "     • Full user: OAuth browser login (recommended)"
      echo "     • Guest/service account: paste a Personal Access Token (PAT)"
      echo ""
      if [[ -f "$SCRIPTS_DIR/.asana-token.json" ]]; then
        say "asana: OAuth token already present — skipping (delete .asana-token.json to re-auth)"
      elif has_tty; then
        read -rp "   Auth via OAuth now? Opens a browser. [Y/n] (n = paste a PAT): " ans </dev/tty
        ans="${ans:-Y}"
        # Pattern match instead of `${ans^^}` — macOS ships bash 3.2 by default
        # (GPLv3 keeps Apple from updating it), and `^^` is bash 4+ only. Without
        # this, the prompt always took the "skip" branch on Mac, leaving every
        # macOS user un-auth'd against Asana with no clear error trail.
        if [[ "$ans" == [Yy] ]]; then
          if [[ $DRY_RUN -eq 1 ]]; then
            say "(dry-run) python3 '$SCRIPTS_DIR/asana_ops.py' --auth"
          else
            (cd "$SCRIPTS_DIR" && python3 ./asana_ops.py --auth) || \
              warn "OAuth failed — re-run later: python3 $SCRIPTS_DIR/asana_ops.py --auth"
          fi
        else
          # Guest path: capture a PAT, persist it for the script, and re-register
          # the MCP with the PAT baked in, replacing the OAuth-wired entry from
          # step 5. mcp_reset drops that entry first so the env swap takes effect
          # (claude mcp add won't overwrite an existing name).
          read -rp "   Paste your Asana PAT (or leave blank to skip): " pat </dev/tty
          if [[ -n "$pat" ]]; then
            do_step "touch '$ENV_FILE' && chmod 600 '$ENV_FILE'"
            do_step "printf 'ASANA_PAT=%s\n' '$pat' >> '$ENV_FILE'"
            ok "ASANA_PAT saved to $ENV_FILE (script path)"
            mcp_reset asana
            do_step "claude mcp add asana --scope user -e ASANA_ACCESS_TOKEN='$pat' -e ASANA_WORKSPACE_FILE='$SCRIPTS_DIR/.asana-workspace.json' -- '$MCP_PYTHON' '$SCRIPTS_DIR/asana_mcp.py'"
            ok "asana MCP: re-registered with your PAT"
            say "Tip: fence a guest to one project — ask Claude 'list my Asana projects',"
            say "  then re-add with -e ASANA_ALLOWED_PROJECTS=<gid> (and -e ASANA_READ_ONLY=1 for read-only)."
          else
            warn "skipped — run later: python3 $SCRIPTS_DIR/asana_ops.py --auth (OAuth), or add ASANA_PAT=... to $ENV_FILE"
          fi
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
#
# The PM section is wrapped in <!-- BEGIN/END: fraction-pm-skills -->
# markers so re-runs replace JUST that section — anything the user added
# above or below the markers is preserved untouched.
echo ""
echo "7. PM operating mode in $USER_CLAUDE_MD"
PM_CLAUDE_TEMPLATE="$BUNDLE_DIR/PM-CLAUDE.md"
BEGIN_MARK="<!-- BEGIN: fraction-pm-skills"
END_MARK="<!-- END: fraction-pm-skills -->"

if [[ ! -f "$PM_CLAUDE_TEMPLATE" ]]; then
  warn "PM-CLAUDE.md template missing from bundle — skipping"
elif [[ ! -f "$USER_CLAUDE_MD" ]]; then
  do_step "cp '$PM_CLAUDE_TEMPLATE' '$USER_CLAUDE_MD'"
  ok "created $USER_CLAUDE_MD"
elif grep -qF "$BEGIN_MARK" "$USER_CLAUDE_MD" && grep -qF "$END_MARK" "$USER_CLAUDE_MD"; then
  # Markers present — replace content between them (idempotent update path).
  if [[ $DRY_RUN -eq 1 ]]; then
    say "(dry-run) replace PM section between markers in $USER_CLAUDE_MD"
  else
    awk -v new_file="$PM_CLAUDE_TEMPLATE" '
      BEGIN { skip = 0 }
      /<!-- BEGIN: fraction-pm-skills/ {
        while ((getline line < new_file) > 0) print line
        close(new_file)
        skip = 1
        next
      }
      /<!-- END: fraction-pm-skills -->/ {
        if (skip) { skip = 0; next }
      }
      !skip { print }
    ' "$USER_CLAUDE_MD" > "$USER_CLAUDE_MD.tmp" && mv "$USER_CLAUDE_MD.tmp" "$USER_CLAUDE_MD"
    ok "updated PM section in $USER_CLAUDE_MD (content between markers replaced)"
  fi
elif grep -qF "Fraction PM operating mode" "$USER_CLAUDE_MD"; then
  # Legacy install: PM content is present but lacks markers. Replace the
  # whole block so future updates can use the marker path. We don't know
  # exactly where it starts/ends without markers — safest: append a fresh
  # marked block and tell the user to manually delete the un-marked old one.
  do_step "{ echo ''; cat '$PM_CLAUDE_TEMPLATE'; } >> '$USER_CLAUDE_MD'"
  warn "found legacy un-marked PM section in $USER_CLAUDE_MD"
  warn "  appended fresh marked block — manually delete the old un-marked section"
else
  do_step "{ echo ''; cat '$PM_CLAUDE_TEMPLATE'; } >> '$USER_CLAUDE_MD'"
  ok "appended PM section to $USER_CLAUDE_MD"
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
      echo "  • Asana: first-party MCP registered as 'asana'. If you skipped auth above,"
      echo "    run: python3 $SCRIPTS_DIR/asana_ops.py --auth (OAuth) or add ASANA_PAT=... to $ENV_FILE"
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
