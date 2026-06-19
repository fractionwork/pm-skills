#!/usr/bin/env bash
# Fraction DevHawk Skills — installer
#
# Installs Fraction's operator skills, scripts, agents, and MCP servers into
# the user's ~/.claude/ directories so Claude Code can run them. One installer,
# role-aware profiles:
#
#   --profile pm        Board management only (add-card, add-comment, card-done,
#                       asana-hygiene, shortcut-hygiene, asana-bootstrap).
#   --profile engineer  Everything: PM + PR/workflow + build/test + ops +
#                       bootstrap/migrate/adopt. (alias: --profile full)
#
# Operator skills are stack-agnostic and live at the USER level — update them
# by re-running this installer. The stack-specific substrate they act on
# (docs, scaffold, git hooks, CI, project scripts) lives INSIDE each project
# repo and is pulled there via the `update-seed` skill, not by this installer.
# Idempotent — safe to re-run after updates.
#
# Usage:
#   bash install.sh                          # interactive (prompts for profile + systems)
#   bash install.sh --profile engineer       # full engineer profile
#   bash install.sh --profile pm --systems=asana,shortcut
#   bash install.sh --profile pm --systems=asana,ado    # mirror Azure DevOps → Asana
#   bash install.sh --dry-run                # show what would change, do nothing
#   bash install.sh --migrate-config         # normalize legacy ~/.claude symlinks
#                                            # into the resolved config dir (backed up)
#
#   # Curl one-liner (auto-clones the repo into a tmp dir):
#   curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash
#   curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash -s -- --profile engineer

set -euo pipefail

REPO_URL="${PM_SKILLS_REPO_URL:-https://github.com/fractionwork/pm-skills.git}"
REPO_BRANCH="${PM_SKILLS_REPO_BRANCH:-main}"

# /dev/tty probe — wrapped in a subshell because bash sometimes prints
# redirect-failure errors to the original stderr even when 2>/dev/null
# is on the same line. The subshell's stderr is fully captured.
has_tty() { (exec </dev/tty) 2>/dev/null; }

# ── Self-fetch path ────────────────────────────────────────────────────
# When invoked via `curl ... | bash`, BASH_SOURCE is empty / the script
# isn't on disk, and the bundle files (skills/, scripts/, agents/) aren't
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
  echo "→ Fetching devhawk-skills..."
  if ! git clone --depth=1 --branch "$REPO_BRANCH" --quiet "$REPO_URL" "$TMP/pm-skills"; then
    echo "✗ Failed to clone $REPO_URL" >&2
    exit 1
  fi
  cd "$TMP/pm-skills"
  # Re-exec with stdin redirected to the terminal — when piped via curl,
  # the original stdin is the curl output (EOF by now), so any later
  # `read` prompt would return immediately and abort the install.
  if has_tty; then
    exec bash install.sh "$@" </dev/tty
  else
    exec bash install.sh "$@"
  fi
fi

DRY_RUN=0
MIGRATE_CONFIG=0
SYSTEMS_ARG=""
PROFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --migrate-config) MIGRATE_CONFIG=1 ;;
    --systems=*) SYSTEMS_ARG="${1#--systems=}" ;;
    --systems) shift; SYSTEMS_ARG="${1:-}" ;;
    --profile=*) PROFILE="${1#--profile=}" ;;
    --profile) shift; PROFILE="${1:-}" ;;
    -h|--help)
      sed -n '1,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 1
      ;;
  esac
  shift
done

BUNDLE_DIR="$SCRIPT_PATH"
# Resolve where Claude Code keeps its config. Precedence:
#   1. CLAUDE_HOME      — explicit installer override (used by tests / advanced users)
#   2. CLAUDE_CONFIG_DIR — Claude Code's OWN config-dir override; if a dev relocated
#      their config here, `claude mcp add --scope user` writes there too, so we MUST
#      install skills/agents/settings/.env to the same place or the install splits
#      across two dirs and Claude never sees half of it.
#   3. $HOME/.claude    — the default.
# CLAUDE_CONFIG_DIR may hold a comma/colon-separated list; Claude Code treats the
# first entry as the primary (writable) dir, so we do the same.
if [[ -n "${CLAUDE_HOME:-}" ]]; then
  CLAUDE_HOME_SOURCE="CLAUDE_HOME"
elif [[ -n "${CLAUDE_CONFIG_DIR:-}" ]]; then
  CLAUDE_HOME="${CLAUDE_CONFIG_DIR%%[,:]*}"
  CLAUDE_HOME_SOURCE="CLAUDE_CONFIG_DIR"
else
  CLAUDE_HOME="$HOME/.claude"
  CLAUDE_HOME_SOURCE="default"
fi
SKILLS_DIR="$CLAUDE_HOME/skills"
SCRIPTS_DIR="$CLAUDE_HOME/scripts"
AGENTS_DIR="$CLAUDE_HOME/agents"
ENV_FILE="$CLAUDE_HOME/.env"
USER_CLAUDE_MD="$CLAUDE_HOME/CLAUDE.md"
SETTINGS_FILE="$CLAUDE_HOME/settings.json"

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
mcp_reset() { do_step "claude mcp remove '$1' >/dev/null 2>&1 || true"; }

# ── Legacy symlink reconciliation ───────────────────────────────────────
# Installs predating CLAUDE_CONFIG_DIR support wrote into ~/.claude even when
# Claude Code read from a custom dir. Some users bridged that by symlinking the
# config dir's entries (skills/, scripts/, …) back to ~/.claude. Now that we
# install straight into the resolved dir, those symlinks are redundant and keep
# the real content indirected through ~/.claude. Detect them and — only when
# asked (--migrate-config or an interactive yes) — dereference each into a real
# file/dir in place, backing up first. The install that follows then refreshes
# the seed files. Install works fine through the symlinks if left alone, so this
# is pure hygiene and never runs unprompted.
reconcile_config() {
  local targets=(skills scripts agents CLAUDE.md settings.json .env)
  local found=() t

  # Whole config dir is a symlink (often → ~/.claude): no real split, the
  # install writes through it. Report and leave it — restructuring a user's
  # entire config dir is not ours to do.
  if [[ -L "$CLAUDE_HOME" ]]; then
    warn "config dir is a symlink: $CLAUDE_HOME → $(readlink "$CLAUDE_HOME")"
    say  "    no split (install writes through it) — leaving as-is"
    return 0
  fi

  for t in "${targets[@]}"; do
    [[ -L "$CLAUDE_HOME/$t" ]] && found+=("$t")
  done
  [[ ${#found[@]} -eq 0 ]] && return 0

  warn "Found ${#found[@]} legacy workaround symlink(s) under $CLAUDE_HOME:"
  for t in "${found[@]}"; do
    say "    $t → $(readlink "$CLAUDE_HOME/$t")"
  done

  if [[ $DRY_RUN -eq 1 ]]; then
    say "    (dry-run) --migrate-config would dereference these into real files/dirs (backed up)"
    return 0
  fi

  local act=$MIGRATE_CONFIG
  if [[ $act -eq 0 ]] && has_tty; then
    printf "  Normalize into real files/dirs now (originals backed up)? [y/N] "
    local ans=""; read -r ans </dev/tty || ans=""
    [[ "$ans" =~ ^[Yy] ]] && act=1
  fi
  if [[ $act -eq 0 ]]; then
    say "    leaving symlinks in place (install still works through them)"
    say "    to clean up later: re-run with --migrate-config"
    return 0
  fi

  local bak="$CLAUDE_HOME/.backup/$(date +%Y%m%d-%H%M%S)-config-migrate"
  mkdir -p "$bak"
  for t in "${found[@]}"; do
    local p="$CLAUDE_HOME/$t" link_tgt
    link_tgt="$(readlink "$p")"
    if [[ -d "$p" ]]; then
      # dir target: snapshot contents through the link, then replace the link
      # with a real dir holding those contents (user extras survive; the seed
      # install overwrites the seed-managed files afterward).
      mkdir -p "$bak/$t"
      cp -R "$p/." "$bak/$t/" 2>/dev/null || true
      rm -f "$p"; mkdir -p "$p"
      cp -R "$bak/$t/." "$p/" 2>/dev/null || true
    elif [[ -f "$p" ]]; then
      cp "$p" "$bak/$t"
      rm -f "$p"; cp "$bak/$t" "$p"
    else
      rm -f "$p"   # dangling link — nothing to preserve
    fi
    ok  "normalized $t (was → $link_tgt; backup: $bak/$t)"
    say "    orphaned source remains at $link_tgt — delete if nothing else uses it"
  done
}

# The official `mcp` SDK requires Python >= 3.10. Stock macOS and older Xcode
# Command Line Tools ship python3 = 3.9, where EVERY pip method fails. Echo the
# newest >=3.10 interpreter on PATH (absolute path), or nothing.
find_py() {
  local c
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
# sidesteps PEP 668 "externally-managed-environment" errors AND guarantees the
# exact interpreter we register has the deps. Falls back to user-site, then warns.
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
  rm -rf "$venv" 2>/dev/null || true
  if "$py" -m venv "$venv" >/dev/null 2>&1 && "$venv/bin/pip" install -q -r "$req" >/dev/null 2>&1; then
    MCP_PYTHON="$venv/bin/python"
    ok "MCP deps installed in venv ($("$py" --version 2>&1))"
    return
  fi
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

# Skills matching a profile: prints skill dir-names (one per line) whose
# `profiles:` frontmatter contains $1, or all skills when $1 == full.
# Reads frontmatter with python3 (a hard prereq below) for reliable parsing.
skills_for_profile() {
  local profile="$1"
  python3 - "$profile" "$BUNDLE_DIR/skills" <<'PY'
import os, re, sys
profile, root = sys.argv[1], sys.argv[2]
for name in sorted(os.listdir(root)):
    sk = os.path.join(root, name, "SKILL.md")
    if not os.path.isfile(sk):
        continue
    with open(sk, encoding="utf-8") as f:
        text = f.read()
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    fm = m.group(1) if m else ""
    pm = re.search(r"^profiles:\s*\[([^\]]*)\]", fm, re.M)
    profs = [p.strip() for p in (pm.group(1).split(",") if pm else []) if p.strip()]
    if profile == "full" or profile in profs:
        print(name)
PY
}

echo ""
echo "Fraction DevHawk Skills installer"
echo "================================="
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
  err "python3 not found — required by the installer and by asana_ops.py / shortcut_ops.py"
  exit 1
fi
ok "python3: $(python3 --version 2>&1)"

MCP_PY_PRECHECK="$(find_py || true)"
if [[ -n "$MCP_PY_PRECHECK" ]]; then
  ok "python (Asana MCP):   $("$MCP_PY_PRECHECK" --version 2>&1)  [$MCP_PY_PRECHECK]"
else
  warn "no Python >= 3.10 found — the Asana MCP needs it (the CLI scripts run fine on 3.9)."
  warn "    macOS: brew install python@3.12   then re-run this installer."
fi

# requests must import under the DEFAULT python3 (the CLI scripts run there).
if python3 -c 'import requests' 2>/dev/null; then
  ok "python 'requests': present"
elif [[ $DRY_RUN -eq 1 ]]; then
  say "(dry-run) python3 -m pip install --user requests  (|| --break-system-packages)"
elif python3 -m pip install --user -q requests >/dev/null 2>&1 \
  || python3 -m pip install --break-system-packages -q requests >/dev/null 2>&1; then
  ok "python 'requests': installed for $(command -v python3)"
else
  warn "could not install 'requests' for $(command -v python3) — the asana/shortcut"
  warn "  CLI scripts will fail with ModuleNotFoundError. Install it manually:"
  warn "    python3 -m pip install --user requests    (or --break-system-packages)"
fi

reconcile_config
do_step "mkdir -p '$CLAUDE_HOME' '$SKILLS_DIR' '$SCRIPTS_DIR'"
if [[ "$CLAUDE_HOME_SOURCE" == "CLAUDE_CONFIG_DIR" ]]; then
  ok "Claude home ready: $CLAUDE_HOME  (from CLAUDE_CONFIG_DIR)"
else
  ok "Claude home ready: $CLAUDE_HOME"
fi

# ── Step 2: Profile selection ────────────────────────────────────────
echo ""
echo "2. Which skill profile?"
if [[ -z "$PROFILE" ]]; then
  if has_tty; then
    echo "     1) pm        — board management only"
    echo "     2) engineer  — everything (PM + PR/workflow + build + ops)"
    echo ""
    read -rp "  > [1] " pc </dev/tty
    case "${pc:-1}" in
      1|pm) PROFILE="pm" ;;
      2|engineer|full) PROFILE="engineer" ;;
      *) warn "unrecognized '$pc' — defaulting to pm"; PROFILE="pm" ;;
    esac
  else
    # Non-interactive with no --profile: default to pm (preserves the bare
    # curl-pipe one-liner's historical PM behavior).
    PROFILE="pm"
  fi
fi
case "$PROFILE" in
  pm|engineer|full) ;;
  *) err "unknown profile '$PROFILE' (expected: pm | engineer | full)"; exit 1 ;;
esac
ok "Profile: $PROFILE"

# Resolve the skill set for this profile up front.
# (read loop, not `mapfile` — macOS ships bash 3.2, which has no mapfile/readarray.)
PROFILE_SKILLS=()
while IFS= read -r _skill; do
  [[ -n "$_skill" ]] && PROFILE_SKILLS+=("$_skill")
done < <(skills_for_profile "$PROFILE")
if [[ ${#PROFILE_SKILLS[@]} -eq 0 ]]; then
  err "no skills matched profile '$PROFILE' — is the bundle complete?"
  exit 1
fi
ENGINEER=0
[[ "$PROFILE" == "engineer" || "$PROFILE" == "full" ]] && ENGINEER=1

# ── Step 3: System selection ─────────────────────────────────────────
echo ""
echo "3. Which PM systems do you use? (drives MCP + script install)"

if [[ -n "$SYSTEMS_ARG" ]]; then
  IFS=',' read -ra SYSTEMS <<< "$SYSTEMS_ARG"
else
  echo "   Choose all that apply (space-separated, e.g. '1 5'):"
  echo "     1) Asana   2) Shortcut   3) Linear   4) Jira   5) Azure DevOps"
  echo "   (Azure DevOps mirrors into Asana — pick 1 + 5 to sync ADO → an Asana board.)"
  echo ""
  if has_tty; then
    read -rp "  > " choice </dev/tty
  else
    err "Interactive prompt needed but no terminal available."
    err "  Run with --systems=asana,ado (or similar) to skip."
    exit 1
  fi
  SYSTEMS=()
  for c in $choice; do
    case "$c" in
      1) SYSTEMS+=(asana) ;;
      2) SYSTEMS+=(shortcut) ;;
      3) SYSTEMS+=(linear) ;;
      4) SYSTEMS+=(jira) ;;
      5) SYSTEMS+=(ado) ;;
      *) warn "ignoring unknown choice: $c" ;;
    esac
  done
fi

# Normalize --systems aliases (azure/azure-devops/devops → ado).
for i in "${!SYSTEMS[@]}"; do
  case "${SYSTEMS[$i]}" in
    azure|azure-devops|azuredevops|devops) SYSTEMS[$i]=ado ;;
  esac
done

# ADO mirrors INTO Asana via asana_ops.py — it needs the Asana script path even
# if the user didn't pick Asana explicitly. Pull asana in as a dependency.
ADO_NEEDS_ASANA=0
if printf '%s\n' "${SYSTEMS[@]}" | grep -qx ado && ! printf '%s\n' "${SYSTEMS[@]}" | grep -qx asana; then
  ADO_NEEDS_ASANA=1
fi

if [[ ${#SYSTEMS[@]} -eq 0 ]]; then
  err "No PM systems selected — nothing to install."
  exit 1
fi
ok "Selected systems: ${SYSTEMS[*]}"

# ── Step 4: Install skills (filtered by profile) ─────────────────────
echo ""
echo "4. Installing skills ($PROFILE profile, ${#PROFILE_SKILLS[@]} skills)..."
do_step "mkdir -p '$SKILLS_DIR'"
for skill in "${PROFILE_SKILLS[@]}"; do
  do_step "rm -rf '$SKILLS_DIR/$skill'"
  do_step "cp -R '$BUNDLE_DIR/skills/$skill' '$SKILLS_DIR/'"
  ok "skill: $skill"
done

# ── Step 5: Install scripts + agents ─────────────────────────────────
echo ""
echo "5. Installing scripts + agents..."
do_step "mkdir -p '$SCRIPTS_DIR'"

# check-skill-deps.mjs powers the SessionStart dependency check (step 8).
if [[ -f "$BUNDLE_DIR/scripts/check-skill-deps.mjs" ]]; then
  do_step "cp '$BUNDLE_DIR/scripts/check-skill-deps.mjs' '$SCRIPTS_DIR/check-skill-deps.mjs'"
  ok "script: check-skill-deps.mjs"
fi

for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      do_step "cp '$BUNDLE_DIR/scripts/asana_ops.py' '$SCRIPTS_DIR/asana_ops.py'"
      ok "script: asana_ops.py"
      do_step "cp '$BUNDLE_DIR/scripts/asana_mcp.py' '$SCRIPTS_DIR/asana_mcp.py'"
      ok "script: asana_mcp.py"
      do_step "cp '$BUNDLE_DIR/scripts/requirements-mcp.txt' '$SCRIPTS_DIR/requirements-mcp.txt'"
      ok "file: requirements-mcp.txt"
      ;;
    shortcut)
      do_step "cp '$BUNDLE_DIR/scripts/shortcut_ops.py' '$SCRIPTS_DIR/shortcut_ops.py'"
      ok "script: shortcut_ops.py"
      ;;
    ado)
      do_step "cp '$BUNDLE_DIR/scripts/ado_auth.py' '$SCRIPTS_DIR/ado_auth.py'"
      ok "script: ado_auth.py"
      do_step "cp '$BUNDLE_DIR/scripts/ado_asana_sync.py' '$SCRIPTS_DIR/ado_asana_sync.py'"
      ok "script: ado_asana_sync.py"
      ;;
  esac
done

# ADO syncs into Asana via asana_ops.py — ensure it's present even when the
# user picked ADO without Asana.
if [[ $ADO_NEEDS_ASANA -eq 1 ]]; then
  do_step "cp '$BUNDLE_DIR/scripts/asana_ops.py' '$SCRIPTS_DIR/asana_ops.py'"
  ok "script: asana_ops.py (required by ado_asana_sync.py)"
fi

if [[ $ENGINEER -eq 1 ]]; then
  if [[ -f "$BUNDLE_DIR/scripts/pr-watch-state.mjs" ]]; then
    do_step "cp '$BUNDLE_DIR/scripts/pr-watch-state.mjs' '$SCRIPTS_DIR/pr-watch-state.mjs'"
    ok "script: pr-watch-state.mjs"
  fi
  if [[ -d "$BUNDLE_DIR/agents" ]]; then
    do_step "mkdir -p '$AGENTS_DIR'"
    for a in "$BUNDLE_DIR"/agents/*.md; do
      [[ -e "$a" ]] || continue
      do_step "cp '$a' '$AGENTS_DIR/$(basename "$a")'"
      ok "agent: $(basename "$a" .md)"
    done
  fi
fi

# ── Step 6: Install MCP servers ──────────────────────────────────────
echo ""
echo "6. Installing MCP servers..."
for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      do_step "claude plugin disable asana 2>/dev/null || true"
      install_mcp_deps
      mcp_reset asana
      do_step "claude mcp add asana --scope user -e ASANA_TOKEN_FILE='$SCRIPTS_DIR/.asana-token.json' -e ASANA_WORKSPACE_FILE='$SCRIPTS_DIR/.asana-workspace.json' -- '$MCP_PYTHON' '$SCRIPTS_DIR/asana_mcp.py'"
      ok "asana MCP: first-party server registered at user scope (auth in step 7)"
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

# ── Step 7: Token setup ───────────────────────────────────────────────
echo ""
echo "7. Token setup"
echo "   Tokens for the script-based paths land in $ENV_FILE (chmod 600)."

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

# ADO PATs are org-scoped and stored in ~/.claude/.ado-credentials.json (chmod
# 600) via ado_auth.py — NOT in .env. The PAT is read from stdin (never argv)
# and never echoed. One PAT per org URL serves every project + skill.
setup_ado_pat() {
  local auth="$SCRIPTS_DIR/ado_auth.py"
  echo ""
  echo "   Azure DevOps PAT (minimal scope: Work Items → Read)"
  echo "   Create at: https://dev.azure.com/<org>/_usersSettings/tokens"
  if ! has_tty; then
    warn "no terminal — store later: echo -n '<PAT>' | python3 $auth --set-pat https://dev.azure.com/<org>"
    return
  fi
  local org=""
  read -rp "   ADO org URL (e.g. https://dev.azure.com/<org>, blank to skip): " org </dev/tty
  if [[ -z "$org" ]]; then
    warn "skipped — store later: echo -n '<PAT>' | python3 $auth --set-pat <org-url>"
    return
  fi
  if python3 "$auth" --list 2>/dev/null | grep -q "^${org%/}	"; then
    say "ADO PAT for ${org%/} already stored — skipping (rotate: python3 $auth --set-pat ${org%/})"
    return
  fi
  local pat=""
  read -rsp "   Paste PAT (hidden, blank to skip): " pat </dev/tty; echo ""
  if [[ -z "$pat" ]]; then
    warn "skipped — store later: echo -n '<PAT>' | python3 $auth --set-pat ${org%/}"
    return
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    say "(dry-run) echo -n <PAT> | python3 '$auth' --set-pat '${org%/}' --scope 'Work Items: Read' --note installer"
    return
  fi
  if printf '%s' "$pat" | python3 "$auth" --set-pat "${org%/}" --scope "Work Items: Read" --note "installer" >/dev/null; then
    ok "ADO PAT stored for ${org%/} (~/.claude/.ado-credentials.json, chmod 600)"
  else
    warn "failed to store PAT — retry: echo -n '<PAT>' | python3 $auth --set-pat ${org%/}"
  fi
}

for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
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
        if [[ "$ans" == [Yy] ]]; then
          if [[ $DRY_RUN -eq 1 ]]; then
            say "(dry-run) python3 '$SCRIPTS_DIR/asana_ops.py' --auth"
          else
            (cd "$SCRIPTS_DIR" && python3 ./asana_ops.py --auth) || \
              warn "OAuth failed — re-run later: python3 $SCRIPTS_DIR/asana_ops.py --auth"
          fi
        else
          read -rp "   Paste your Asana PAT (or leave blank to skip): " pat </dev/tty
          if [[ -n "$pat" ]]; then
            do_step "touch '$ENV_FILE' && chmod 600 '$ENV_FILE'"
            do_step "printf 'ASANA_PAT=%s\n' '$pat' >> '$ENV_FILE'"
            ok "ASANA_PAT saved to $ENV_FILE (script path)"
            mcp_reset asana
            do_step "claude mcp add asana --scope user -e ASANA_ACCESS_TOKEN='$pat' -e ASANA_WORKSPACE_FILE='$SCRIPTS_DIR/.asana-workspace.json' -- '$MCP_PYTHON' '$SCRIPTS_DIR/asana_mcp.py'"
            ok "asana MCP: re-registered with your PAT"
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
    ado)
      setup_ado_pat
      ;;
    linear|jira)
      say "$sys: MCP OAuth happens on first use inside Claude Code — nothing to set up here"
      ;;
  esac
done

# ── Step 8: Operating-rules + skill index in user CLAUDE.md ──────────
# The block is wrapped in <!-- BEGIN/END: fraction-pm-skills --> markers
# (name kept for backward-compat with existing user CLAUDE.md files) so
# re-runs replace JUST that section. The skill index is GENERATED from each
# installed skill's frontmatter — never hand-maintained.
echo ""
echo "8. Operating mode in $USER_CLAUDE_MD"
RULES_TEMPLATE="$BUNDLE_DIR/templates/operating-rules.md"
BEGIN_MARK="<!-- BEGIN: fraction-pm-skills"
END_MARK="<!-- END: fraction-pm-skills -->"

if [[ ! -f "$RULES_TEMPLATE" ]]; then
  warn "operating-rules template missing from bundle — skipping CLAUDE.md update"
else
  # Generate the skill-index markdown from the installed skills' frontmatter.
  SKILL_INDEX="$(python3 - "$SKILLS_DIR" "${PROFILE_SKILLS[@]}" <<'PY'
import os, re, sys
skills_dir = sys.argv[1]
for name in sys.argv[2:]:
    sk = os.path.join(skills_dir, name, "SKILL.md")
    if not os.path.isfile(sk):
        continue
    with open(sk, encoding="utf-8") as f:
        text = f.read()
    m = re.match(r"^---\n(.*?)\n---", text, re.S)
    fm = m.group(1) if m else ""
    dm = re.search(r"^description:\s*(.*?)(?=^\w[\w-]*:|\Z)", fm, re.S | re.M)
    desc = dm.group(1) if dm else ""
    desc = desc.lstrip(">|").strip()
    desc = re.sub(r"\s+", " ", desc)
    # First sentence (up to ". "), capped so the index stays scannable.
    first = re.split(r"(?<=\.)\s", desc, 1)[0] if desc else ""
    if len(first) > 200:
        first = first[:197].rstrip() + "..."
    print(f"- **`{name}`** — {first}")
PY
)"

  BLOCK_FILE="$(mktemp)"
  {
    echo "$BEGIN_MARK (managed by the devhawk-skills installer; content between these markers is overwritten on each install/update) -->"
    echo "# Fraction operating mode (${PROFILE} profile)"
    echo ""
    echo "This Claude Code instance is configured with Fraction's **${PROFILE}** skill"
    echo "profile. Skills load automatically via their frontmatter \`description\` —"
    echo "invoke by name or just describe what you want."
    echo ""
    echo "## Available skills (${PROFILE} profile)"
    echo ""
    echo "$SKILL_INDEX"
    echo ""
    cat "$RULES_TEMPLATE"
    echo "$END_MARK"
  } > "$BLOCK_FILE"

  if [[ $DRY_RUN -eq 1 ]]; then
    say "(dry-run) write ${#PROFILE_SKILLS[@]}-skill index + operating rules between markers in $USER_CLAUDE_MD"
  elif [[ ! -f "$USER_CLAUDE_MD" ]]; then
    cp "$BLOCK_FILE" "$USER_CLAUDE_MD"
    ok "created $USER_CLAUDE_MD"
  elif grep -qF "$BEGIN_MARK" "$USER_CLAUDE_MD" && grep -qF "$END_MARK" "$USER_CLAUDE_MD"; then
    # Anchor the marker match to column 0 — the real markers start the line,
    # while the operating-rules prose *mentions* the marker text mid-line.
    # An unanchored match would re-trigger injection on that prose and
    # duplicate the block on every re-run.
    awk -v new_file="$BLOCK_FILE" '
      /^<!-- BEGIN: fraction-pm-skills/ {
        while ((getline line < new_file) > 0) print line
        close(new_file); skip = 1; next
      }
      /^<!-- END: fraction-pm-skills -->/ { if (skip) { skip = 0; next } }
      !skip { print }
    ' "$USER_CLAUDE_MD" > "$USER_CLAUDE_MD.tmp" && mv "$USER_CLAUDE_MD.tmp" "$USER_CLAUDE_MD"
    ok "updated operating-mode section in $USER_CLAUDE_MD (content between markers replaced)"
  else
    { echo ""; cat "$BLOCK_FILE"; } >> "$USER_CLAUDE_MD"
    ok "appended operating-mode section to $USER_CLAUDE_MD"
  fi
  rm -f "$BLOCK_FILE"
fi

# ── Step 9: SessionStart dependency-check hook (user scope) ──────────
# Skills now live at the user level, so the dependency check runs here too.
# Registered in ~/.claude/settings.json via python3 (jq-free, safe merge).
# node-guarded so PM-only users without node aren't blocked.
echo ""
echo "9. Dependency-check hook"
DEPS_SCRIPT="$SCRIPTS_DIR/check-skill-deps.mjs"
if [[ ! -f "$BUNDLE_DIR/scripts/check-skill-deps.mjs" ]]; then
  say "check-skill-deps.mjs not in bundle — skipping hook"
elif [[ $DRY_RUN -eq 1 ]]; then
  say "(dry-run) register SessionStart hook → node $DEPS_SCRIPT --on-session-start --skills-dir $SKILLS_DIR"
else
  HOOK_CMD="command -v node >/dev/null 2>&1 && node '$DEPS_SCRIPT' --on-session-start --skills-dir '$SKILLS_DIR' || true"
  python3 - "$SETTINGS_FILE" "$HOOK_CMD" <<'PY'
import json, os, sys
path, cmd = sys.argv[1], sys.argv[2]
data = {}
if os.path.isfile(path):
    try:
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
hooks = data.setdefault("hooks", {})
ss = hooks.setdefault("SessionStart", [])
def has_cmd(entries):
    for e in entries:
        for h in e.get("hooks", []):
            if "check-skill-deps.mjs" in h.get("command", ""):
                return True
    return False
if not has_cmd(ss):
    ss.append({"hooks": [{"type": "command", "command": cmd}]})
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("registered")
else:
    print("present")
PY
  ok "SessionStart dependency-check hook ensured in $SETTINGS_FILE"
fi

# ── Done ──────────────────────────────────────────────────────────────
echo ""
echo "================================="
echo "Install complete — profile: $PROFILE"
echo ""
echo "Next:"
for sys in "${SYSTEMS[@]}"; do
  case "$sys" in
    asana)
      echo "  • Asana: first-party MCP registered as 'asana'. If you skipped auth above,"
      echo "    run: python3 $SCRIPTS_DIR/asana_ops.py --auth (OAuth) or add ASANA_PAT=... to $ENV_FILE"
      ;;
    linear)  echo "  • Linear MCP: first MCP operation in Claude Code will prompt for OAuth" ;;
    jira)    echo "  • Jira (Atlassian Rovo) MCP: first MCP operation will prompt for OAuth" ;;
    shortcut) echo "  • Shortcut: token in $ENV_FILE is used by the script — no further setup" ;;
    ado)
      echo "  • Azure DevOps: PAT stored per-org in ~/.claude/.ado-credentials.json. Configure"
      echo "    the mirror (org/project/people/board) with the 'ado-asana-sync' skill, then"
      echo "    dry-run: python3 $SCRIPTS_DIR/ado_asana_sync.py --dry-run"
      ;;
  esac
done
if [[ $ENGINEER -eq 1 ]]; then
  echo "  • Engineer profile: workflow skills (create-pr, pr-review, next-task, …) read"
  echo "    project substrate (docs, scripts, scaffold) from each repo. Pull it with the"
  echo "    'update-seed' skill inside a seeded project ('sync from seed')."
fi
echo "  • Restart Claude Code so it loads the new skills, agents, and MCP servers."
echo "  • Re-run anytime to update: curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash -s -- --profile $PROFILE"
echo ""
