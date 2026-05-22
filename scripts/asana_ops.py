#!/usr/bin/env python3
"""
Asana workspace operations — cleanup, hygiene, and admin tasks that
Asana MCP can't do (archive, custom fields, portfolios, sections).

Auth: PKCE OAuth (recommended) or PAT fallback.

Usage:
  # First-time auth (opens browser, stores token locally):
  python3 scripts/asana_ops.py --auth

  # Run cleanup tracks:
  python3 scripts/asana_ops.py --track A --dry-run
  python3 scripts/asana_ops.py --track A
  python3 scripts/asana_ops.py --track all --dry-run

Tracks: A (archive), B (portfolios), C (custom fields),
        D (Paryani fixes), E (PronovosSample cleanup)
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.parse
import webbrowser
from datetime import datetime
from pathlib import Path

import requests

# ── Config ──
BASE = "https://app.asana.com/api/1.0"
# Fraction DevHawk OAuth app — hardcoded like GitHub CLI does.
# Client ID is public by design; client secret is required by Asana's
# token exchange but is not truly secret in a CLI (source is readable).
# Security comes from the user's browser consent + PKCE verifier.
ASANA_CLIENT_ID = "1214192066020436"
ASANA_CLIENT_SECRET = "e2039abfba03f82ac88c79cd7568bbcc"
ASANA_AUTH_URL = "https://app.asana.com/-/oauth_authorize"
ASANA_TOKEN_URL = "https://app.asana.com/-/oauth_token"
CALLBACK_PORT = 8372
TOKEN_FILE = Path(".asana-token.json")
LOG_FILE = Path("asana_cleanup.log")
REPORT_FILE = Path("asana_cleanup_report.md")

# Rate limiting
CALLS = 0
ERRORS = 0
START_TIME = None


# ═══════════════════════════════════════════════════════
# PKCE OAuth flow
# ═══════════════════════════════════════════════════════

def get_client_id():
    """Get client ID — hardcoded for the Fraction DevHawk app."""
    return os.environ.get("ASANA_CLIENT_ID", ASANA_CLIENT_ID)


def generate_pkce():
    """Generate PKCE code_verifier and code_challenge (S256)."""
    verifier = secrets.token_urlsafe(96)[:128]
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


def oauth_auth():
    """Run PKCE OAuth flow: open browser, catch callback, exchange for tokens."""
    client_id = get_client_id()
    if not client_id:
        print("Error: ASANA_CLIENT_ID not set.")
        print("Set it in .env.local or as an env var.")
        print("Get it from: https://app.asana.com/0/my-apps → Fraction DevHawk → Client ID")
        sys.exit(1)

    verifier, challenge = generate_pkce()
    state = secrets.token_urlsafe(32)

    # Omit scope parameter to get legacy full-access token.
    # Asana's granular scopes don't cover section creation, addMembers,
    # or addCustomFieldSetting — those need full access.

    # Build authorization URL
    params = {
        "client_id": client_id,
        "redirect_uri": f"http://localhost:{CALLBACK_PORT}/callback",
        "response_type": "code",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    auth_url = f"{ASANA_AUTH_URL}?{urllib.parse.urlencode(params)}"

    # Capture the authorization code via local HTTP server
    auth_code = [None]
    auth_error = [None]

    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if qs.get("state", [None])[0] != state:
                auth_error[0] = "State mismatch"
            elif qs.get("error"):
                auth_error[0] = qs["error"][0]
            else:
                auth_code[0] = qs.get("code", [None])[0]

            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            if auth_code[0]:
                self.wfile.write(b"<h2>Authenticated! You can close this tab.</h2>")
            else:
                self.wfile.write(f"<h2>Error: {auth_error[0]}</h2>".encode())

        def log_message(self, *args):
            pass  # suppress server logs

    server = http.server.HTTPServer(("localhost", CALLBACK_PORT), CallbackHandler)
    server_thread = threading.Thread(target=server.handle_request)
    server_thread.start()

    print(f"Opening browser for Asana authorization...")
    print(f"If the browser doesn't open, visit:\n  {auth_url}\n")
    webbrowser.open(auth_url)

    server_thread.join(timeout=120)
    server.server_close()

    if auth_error[0]:
        print(f"Auth error: {auth_error[0]}")
        sys.exit(1)
    if not auth_code[0]:
        print("Timed out waiting for authorization.")
        sys.exit(1)

    # Exchange code for tokens
    token_data = {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "client_secret": ASANA_CLIENT_SECRET,
        "redirect_uri": f"http://localhost:{CALLBACK_PORT}/callback",
        "code": auth_code[0],
        "code_verifier": verifier,
    }
    resp = requests.post(ASANA_TOKEN_URL, data=token_data)
    if resp.status_code != 200:
        print(f"Token exchange failed: {resp.status_code} {resp.text}")
        sys.exit(1)

    tokens = resp.json()
    tokens["obtained_at"] = time.time()
    TOKEN_FILE.write_text(json.dumps(tokens, indent=2))
    print(f"Authenticated as Asana user. Token saved to {TOKEN_FILE}")
    print("This file is gitignored. Re-run --auth to re-authenticate.")
    return tokens["access_token"]


def refresh_token():
    """Refresh an expired OAuth token."""
    if not TOKEN_FILE.exists():
        return None
    tokens = json.loads(TOKEN_FILE.read_text())
    client_id = get_client_id()
    if not client_id or not tokens.get("refresh_token"):
        return None

    resp = requests.post(ASANA_TOKEN_URL, data={
        "grant_type": "refresh_token",
        "client_id": client_id,
        "client_secret": ASANA_CLIENT_SECRET,
        "refresh_token": tokens["refresh_token"],
    })
    if resp.status_code != 200:
        print(f"Token refresh failed: {resp.status_code}. Re-run --auth.")
        return None

    new_tokens = resp.json()
    new_tokens["obtained_at"] = time.time()
    # Preserve refresh_token if not returned in refresh response
    if "refresh_token" not in new_tokens:
        new_tokens["refresh_token"] = tokens["refresh_token"]
    TOKEN_FILE.write_text(json.dumps(new_tokens, indent=2))
    return new_tokens["access_token"]


def get_token():
    """Get a valid access token. Priority: token file → PAT env var."""
    # Try stored OAuth token
    if TOKEN_FILE.exists():
        tokens = json.loads(TOKEN_FILE.read_text())
        expires_in = tokens.get("expires_in", 3600)
        obtained_at = tokens.get("obtained_at", 0)
        if time.time() - obtained_at < expires_in - 60:
            return tokens["access_token"]
        # Try refresh
        refreshed = refresh_token()
        if refreshed:
            return refreshed
        print("OAuth token expired and refresh failed. Re-run --auth or set ASANA_PAT.")

    # Fallback to PAT
    pat = os.environ.get("ASANA_PAT", "")
    if pat:
        return pat

    print("No auth available. Run: python3 scripts/asana_ops.py --auth")
    sys.exit(1)


# ── Logging ──
def log(method, url, status, gid=""):
    global CALLS
    CALLS += 1
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"{ts} {method:6s} {url} → {status} {gid}"
    print(f"  {line}")
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


# ── API helpers ──
def api(method, path, data=None, params=None, dry_run=False):
    url = f"{BASE}{path}"
    if dry_run and method != "GET":
        log(method, path, "DRY-RUN")
        return {"data": {"gid": "dry-run"}}

    token = get_token()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    resp = requests.request(method, url, headers=headers,
                            json={"data": data} if data else None, params=params)

    # Rate limit handling
    if resp.status_code == 429:
        retry = int(resp.headers.get("Retry-After", 30))
        print(f"  ⏳ Rate limited, waiting {retry}s...")
        time.sleep(retry)
        return api(method, path, data, params, dry_run)

    gid = ""
    try:
        body = resp.json()
        gid = body.get("data", {}).get("gid", "") if isinstance(body.get("data"), dict) else ""
    except Exception:
        body = {}

    log(method, path, resp.status_code, gid)

    if resp.status_code >= 400:
        global ERRORS
        ERRORS += 1
        print(f"  ✗ {resp.status_code}: {resp.text[:200]}")
        return None

    return body


def paginate(path, params=None, opt_fields=None):
    """Fetch all pages of a list endpoint."""
    all_items = []
    p = dict(params or {})
    p["limit"] = 100
    if opt_fields:
        p["opt_fields"] = opt_fields
    while True:
        resp = api("GET", path, params=p)
        if not resp:
            break
        all_items.extend(resp.get("data", []))
        np = resp.get("next_page")
        if not np or not np.get("offset"):
            break
        p["offset"] = np["offset"]
    return all_items


# ═══════════════════════════════════════════════════════
# Hygiene audit + fix
# ═══════════════════════════════════════════════════════

REQUIRED_FIELDS = {
    "1214202045134883": "Fraction Priority",
    "1214202179972377": "Fraction Task Type",
    "1208941031000919": "Story Points",
    "1204575864766299": "Task Progress",
    "1214267151463854": "Release",
    "1205043346485340": "Sprint",
}
REQUIRED_ADMINS = {
    "1206452951803612": "Jeremy King",
    "1204497823875018": "Alyssia Maluda",
}
STANDARD_SECTIONS = [
    "INBOX", "BACKLOG", "TODO", "WIP", "READY FOR REVIEW",
    "READY FOR TESTING", "READY FOR RELEASE", "DONE",
]
# Sections where we relax field requirements (Priority/Type/Points/Release).
# INBOX items haven't been discussed with stakeholders yet, so demanding
# estimates and types is the wrong order of operations. See
# docs/asana-best-practices.md for the per-section field requirement table.
LIGHT_VALIDATION_SECTIONS = {"INBOX"}
# Days before an unmoved INBOX item is flagged as stale.
INBOX_STALE_DAYS = 30
P2_OPTION = "1214202045134886"
STORY_OPTION = "1214202179972379"
DISCUSSION_OPTION = "1214202179972383"
EPIC_OPTION = "1214202179972378"
SPRINT_FIELD_GID = "1205043346485340"  # workspace-level multi_enum
SP_FIELD_GID = "1208941031000919"
PRIORITY_FIELD_GID = "1214202045134883"
TYPE_FIELD_GID = "1214202179972377"


def auto_estimate(project_gid):
    """Auto-estimate story points based on description complexity."""
    print(f"\n═══ Auto-Estimate: {project_gid} ═══\n")

    def estimate_sp(name, notes):
        text = (name + " " + (notes or "")).lower()
        words = len(text.split())
        complex_kw = ["integrate", "migration", "architecture", "pipeline", "api",
                       "automate", "dashboard", "multiple", "system", "workflow",
                       "end-to-end", "security", "scrape", "ingest"]
        simple_kw = ["fix", "chore", "remove", "rename", "typo", "cleanup", "variable"]
        score = sum(1 for k in complex_kw if k in text) - sum(1 for k in simple_kw if k in text)
        if words < 20 and score <= 0: return 1
        if words < 50 and score <= 0: return 2
        if words < 100 or score <= 1: return 3
        if words < 200 or score <= 2: return 5
        return 8

    tasks = paginate(f"/projects/{project_gid}/tasks",
                     opt_fields="name,completed,notes,custom_fields.gid,custom_fields.number_value")
    incomplete = [t for t in tasks if not t.get("completed") and not t["name"].startswith("EPIC:")]
    estimated = 0
    for task in incomplete:
        has_sp = any(cf.get("gid") == SP_FIELD_GID and cf.get("number_value")
                     for cf in task.get("custom_fields", []))
        if has_sp:
            continue
        sp = estimate_sp(task["name"], task.get("notes", ""))
        api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {SP_FIELD_GID: sp}})
        estimated += 1
        if estimated % 50 == 0:
            print(f"  ... {estimated}")

    print(f"  Estimated: {estimated} tasks")


_VAGUE_VERBS = {"fix", "update", "tweak", "change", "adjust", "modify", "edit", "improve"}
_VAGUE_PREFIX_RE = re.compile(r"^\[[A-Z]+-\d+\]\s*")
_VAGUE_MARKER_RE = re.compile(r"\b(misc|todo|tbd)\b", re.IGNORECASE)


def _is_vague_title(name):
    """Flag titles that are short + start with a generic verb, or contain TBD/TODO/misc.

    Strips a leading [KEY-N] tracker prefix before evaluating length so
    migrated tasks aren't penalized for the prefix's word count.
    """
    if _VAGUE_MARKER_RE.search(name):
        return True
    body = _VAGUE_PREFIX_RE.sub("", name).strip()
    words = body.split()
    if not words:
        return True
    return len(words) <= 4 and words[0].lower() in _VAGUE_VERBS


def _print_offenders(items, indent="     ", max_show=20):
    """Print task name + permalink for each offender, capped at max_show."""
    for t in items[:max_show]:
        print(f"{indent}• {t['name']}")
        if t.get("permalink_url"):
            print(f"{indent}  {t['permalink_url']}")
    if len(items) > max_show:
        print(f"{indent}... and {len(items) - max_show} more")


def hygiene_audit(project_gid, dry_run=False):
    """Full hygiene audit + fix against Asana best practices."""
    print(f"\n═══ Hygiene Audit: {project_gid} ═══\n")
    fixes = 0

    # 1. Admins
    print("1. Required Admins")
    resp = api("GET", f"/projects/{project_gid}/members", params={"opt_fields": "name"})
    if resp:
        member_gids = {m["gid"] for m in resp.get("data", [])}
        for gid, name in REQUIRED_ADMINS.items():
            if gid in member_gids:
                print(f"   ✅ {name}")
            else:
                print(f"   ❌ {name} — adding...")
                api("POST", f"/projects/{project_gid}/addMembers",
                    {"members": [gid]}, dry_run=dry_run)
                fixes += 1

    # 2. Custom fields
    print("\n2. Custom Fields")
    resp = api("GET", f"/projects/{project_gid}",
               params={"opt_fields": "custom_field_settings.custom_field.gid"})
    attached = set()
    if resp and isinstance(resp.get("data"), dict):
        for cfs in resp["data"].get("custom_field_settings", []):
            attached.add(cfs.get("custom_field", {}).get("gid", ""))
    for gid, name in REQUIRED_FIELDS.items():
        if gid in attached:
            print(f"   ✅ {name}")
        else:
            print(f"   ❌ {name} — attaching...")
            api("POST", f"/projects/{project_gid}/addCustomFieldSetting",
                {"custom_field": gid, "is_important": True}, dry_run=dry_run)
            fixes += 1

    # 3. Sections
    print("\n3. Sections")
    resp = api("GET", f"/projects/{project_gid}/sections", params={"opt_fields": "name"})
    existing_sections = {s["name"] for s in resp.get("data", [])} if resp else set()
    for sname in STANDARD_SECTIONS:
        if sname in existing_sections:
            print(f"   ✅ {sname}")
        else:
            print(f"   ❌ {sname} — creating...")
            api("POST", f"/projects/{project_gid}/sections",
                {"name": sname}, dry_run=dry_run)
            fixes += 1
    extra_sections = existing_sections - set(STANDARD_SECTIONS)
    if extra_sections:
        print(f"   Non-standard sections: {len(extra_sections)}")
        for sname in sorted(extra_sections):
            print(f"     • {sname}")

    # 4. Metadata
    print("\n4. Metadata")
    resp = api("GET", f"/projects/{project_gid}",
               params={"opt_fields": "start_on,due_on,notes"})
    if resp and isinstance(resp.get("data"), dict):
        d = resp["data"]
        print(f"   start_on: {d.get('start_on') or '❌ MISSING'}")
        print(f"   due_on: {d.get('due_on') or '❌ MISSING'}")
        print(f"   notes: {'✅' if d.get('notes') else '❌ EMPTY'}")

    # 5. Task hygiene
    print("\n5. Task Hygiene")
    tasks = paginate(f"/projects/{project_gid}/tasks",
                     opt_fields="name,completed,assignee.gid,notes,parent.gid,parent.name,custom_fields.gid,custom_fields.enum_value.gid,custom_fields.number_value,memberships.section.gid,memberships.section.name,modified_at,permalink_url")
    incomplete = [t for t in tasks if not t.get("completed")]

    # Section helpers — INBOX gets light validation (Priority/Type/Points/Release
    # are intentionally not required pre-stakeholder discussion).
    def section_name(t):
        for m in t.get("memberships", []):
            sec = m.get("section") or {}
            if sec.get("name"):
                return sec["name"]
        return None
    incomplete_strict = [t for t in incomplete if section_name(t) not in LIGHT_VALIDATION_SECTIONS]
    inbox_tasks = [t for t in incomplete if section_name(t) == "INBOX"]

    # Orphans
    orphans = [t for t in tasks if not any(
        m.get("section", {}).get("gid") for m in t.get("memberships", []))]
    print(f"   Orphaned: {len(orphans)}")
    _print_offenders(orphans)

    # INBOX summary (always shown so the funnel is visible)
    if inbox_tasks:
        print(f"   INBOX: {len(inbox_tasks)} item(s) awaiting stakeholder discussion")
        # Stale INBOX — flag items unmoved for >INBOX_STALE_DAYS
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        stale = []
        for t in inbox_tasks:
            ma = t.get("modified_at")
            if not ma:
                continue
            try:
                # Asana returns ISO 8601 with Z suffix
                dt = datetime.fromisoformat(ma.replace("Z", "+00:00"))
                if (now - dt).days >= INBOX_STALE_DAYS:
                    stale.append(t)
            except (ValueError, AttributeError):
                pass
        if stale:
            print(f"   Stale INBOX (>{INBOX_STALE_DAYS}d no activity): {len(stale)}")
            _print_offenders(stale)

    # No assignee — TODO+ only (BACKLOG and INBOX intentionally unassigned)
    no_assignee = [t for t in incomplete_strict
                   if section_name(t) not in (None, "BACKLOG") and not t.get("assignee")]
    print(f"   No assignee (TODO+ only): {len(no_assignee)}")
    _print_offenders(no_assignee)

    # No priority — strict sections only (BACKLOG and below)
    no_priority = [t for t in incomplete_strict if not any(
        cf.get("gid") == PRIORITY_FIELD_GID and cf.get("enum_value")
        for cf in t.get("custom_fields", []))]
    print(f"   No Priority (excl. INBOX): {len(no_priority)}")
    if no_priority and not dry_run:
        print(f"   → Setting {len(no_priority)} to P2 (Medium)...")
        for task in no_priority:
            # EPICs are aggregate containers; child stories carry Priority.
            # Mirror the same EPIC skip used in the no_type loop below.
            if task["name"].startswith("EPIC:"):
                continue
            api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {PRIORITY_FIELD_GID: P2_OPTION}})
            fixes += 1

    # No type — strict sections only
    no_type = [t for t in incomplete_strict if not any(
        cf.get("gid") == TYPE_FIELD_GID and cf.get("enum_value")
        for cf in t.get("custom_fields", []))]
    print(f"   No Task Type (excl. INBOX): {len(no_type)}")
    if no_type and not dry_run:
        print(f"   → Setting {len(no_type)} types...")
        meta_kw = ["BREAK OUT", "DISCUSS", "REFINE", "BREAKOUT"]
        for task in no_type:
            if task["name"].startswith("EPIC:"):
                option = EPIC_OPTION
            elif any(k in task["name"].upper() for k in meta_kw):
                option = DISCUSSION_OPTION
            else:
                option = STORY_OPTION
            api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {TYPE_FIELD_GID: option}})
            fixes += 1

    # No story points — strict sections only
    no_sp = [t for t in incomplete_strict if not any(
        cf.get("gid") == SP_FIELD_GID and cf.get("number_value")
        for cf in t.get("custom_fields", [])) and not t["name"].startswith("EPIC:")]
    print(f"   No Story Points (excl. INBOX): {len(no_sp)}")
    if no_sp and not dry_run:
        print(f"   → Auto-estimating...")
        auto_estimate(project_gid)
        fixes += len(no_sp)

    # No Release — strict sections only (INBOX is pre-release classification)
    no_release = [t for t in incomplete_strict if not any(
        cf.get("gid") == RELEASE_FIELD_GID and cf.get("enum_value")
        for cf in t.get("custom_fields", []))]
    print(f"   No Release (excl. INBOX): {len(no_release)}")
    if no_release and not dry_run:
        print(f"   → Auto-detecting phase (epic name → task prefix → Phase 1 fallback)...")
        # Build parent→phase map from EPICs with "(Phase N)" in name
        phase_pattern = re.compile(r"\(Phase\s+(\d+)\)", re.IGNORECASE)
        epic_phase = {}
        for task in tasks:
            m = phase_pattern.search(task.get("name", ""))
            if m:
                epic_phase[task["gid"]] = f"Phase {m.group(1)}"
        # Also detect from task prefixes: SCRUM-* = Phase 1, PHAS-* = Phase 2
        scrum_re = re.compile(r"^\[SCRUM-")
        phas_re = re.compile(r"^\[PHAS-")
        fallback_count = 0
        for task in no_release:
            phase = None
            if task["name"].startswith("EPIC:"):
                m = phase_pattern.search(task["name"])
                if m:
                    phase = f"Phase {m.group(1)}"
            else:
                parent = task.get("parent")
                if parent and parent.get("gid") in epic_phase:
                    phase = epic_phase[parent["gid"]]
                elif scrum_re.match(task["name"]):
                    phase = "Phase 1"
                elif phas_re.match(task["name"]):
                    phase = "Phase 2"
            # Greenfield fallback — no signal in name, prefix, or parent
            if not phase:
                phase = "Phase 1"
                fallback_count += 1
            opt_gid = RELEASE_OPTIONS.get(phase)
            if opt_gid:
                api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {RELEASE_FIELD_GID: opt_gid}})
                fixes += 1
        if fallback_count:
            print(f"   ⚠ {fallback_count} task(s) defaulted to Phase 1 (no signal in name, prefix, or parent epic). Review if your project has multiple phases.")

    # Title quality
    vague = [t for t in incomplete if _is_vague_title(t["name"])]
    print(f"   Vague titles: {len(vague)}")
    _print_offenders(vague)

    # Empty descriptions
    no_desc = [t for t in incomplete if not (t.get("notes") or "").strip()]
    print(f"   Empty descriptions: {len(no_desc)}")
    _print_offenders(no_desc)

    # No parent EPIC (structural — surface for triage, don't auto-fix).
    # INBOX exempt: items here may not yet have an Epic (parent only required at promotion).
    no_epic_parent = []
    for t in incomplete_strict:
        if t["name"].startswith("EPIC:"):
            continue
        parent = t.get("parent")
        if not parent or not parent.get("name", "").startswith("EPIC:"):
            no_epic_parent.append(t)
    print(f"   No parent EPIC (excl. INBOX): {len(no_epic_parent)}")
    _print_offenders(no_epic_parent)

    print(f"\n   Total fixes applied: {fixes}")


# ═══════════════════════════════════════════════════════
# Create new phase in an existing project
# ═══════════════════════════════════════════════════════


def create_new_phase(project_gid, phase_name, dry_run=False):
    """Create a new phase (set of Epics) in an existing project.

    A phase is a named group of Epics within a single project. The project
    stays the same — new Epics are added with the phase name as a suffix.
    Example: 'EPIC: Rate Shopping (Phase 3)'

    This is how teams add new release phases without creating new projects.
    """
    print(f"\n═══ New Phase: {phase_name} ═══\n")
    print(f"  Project: {project_gid}")

    # Verify project exists
    resp = api("GET", f"/projects/{project_gid}", params={"opt_fields": "name"})
    if not resp:
        print("  ✗ Project not found")
        return
    print(f"  Project name: {resp['data']['name']}")

    # Ensure standard fields + sections exist (idempotent)
    print("\n  Verifying best practices...")

    # Check sections
    sr = api("GET", f"/projects/{project_gid}/sections", params={"opt_fields": "name"})
    existing_sections = {s["name"] for s in sr.get("data", [])} if sr else set()
    section_gids = {}
    if sr:
        section_gids = {s["name"]: s["gid"] for s in sr.get("data", [])}
    for sname in STANDARD_SECTIONS:
        if sname not in existing_sections:
            print(f"    Creating section: {sname}")
            r = api("POST", f"/projects/{project_gid}/sections",
                    {"name": sname}, dry_run=dry_run)
            if r:
                section_gids[sname] = r["data"]["gid"]

    # Check fields
    fr = api("GET", f"/projects/{project_gid}",
             params={"opt_fields": "custom_field_settings.custom_field.gid"})
    attached = set()
    if fr and isinstance(fr.get("data"), dict):
        for cfs in fr["data"].get("custom_field_settings", []):
            attached.add(cfs.get("custom_field", {}).get("gid", ""))
    for gid, name in REQUIRED_FIELDS.items():
        if gid not in attached:
            print(f"    Attaching field: {name}")
            api("POST", f"/projects/{project_gid}/addCustomFieldSetting",
                {"custom_field": gid, "is_important": True}, dry_run=dry_run)

    # Post status update
    print(f"\n  Posting status update for {phase_name}...")
    api("POST", f"/projects/{project_gid}/project_statuses", {
        "color": "blue",
        "title": f"{phase_name} started",
        "text": f"New phase '{phase_name}' created. Epics and stories will be added as discovery and planning complete.",
    }, dry_run=dry_run)

    # Ensure Release enum option exists for this phase
    release_opt_gid = RELEASE_OPTIONS.get(phase_name)
    if not release_opt_gid:
        print(f"\n  Creating Release option: {phase_name}")
        resp = api("POST", f"/custom_fields/{RELEASE_FIELD_GID}/enum_options",
                   {"name": phase_name, "insert_before": None}, dry_run=dry_run)
        if resp:
            release_opt_gid = resp["data"]["gid"]
            RELEASE_OPTIONS[phase_name] = release_opt_gid
            print(f"    Created: {phase_name} → {release_opt_gid}")

    todo_gid = section_gids.get("TODO", "")
    print(f"\n  Phase '{phase_name}' ready.")
    print(f"  Add Epics with: 'EPIC: [Name] ({phase_name})'")
    print(f"  TODO section: {todo_gid}")
    if release_opt_gid:
        print(f"  Release option GID: {release_opt_gid} — set on new tasks")
    print(f"\n  Next: create Epics and stories via MCP or asana_ops.py")


# ═══════════════════════════════════════════════════════
# Track A — Archive dead/test projects
# ═══════════════════════════════════════════════════════

ARCHIVE_CONFIRMED = [
    ("Fraction - Portal", "1206623088461710"),
    ("MASTER TEST BOARD DevHawk", "1211276876230056"),
    ("Jeff DevHawk Demo", "1211972929444363"),
    ("Zahra DevHawk Demo", "1211982990827115"),
    ("Ralph DevHawk Demo", "1211982994767467"),
    ("Austin LOCAL TEST BOARD 2", "1211994870269362"),
    ("PG LOCAL BOARD 6", "1212058118049327"),
    ("Duplicate of Austin LOCAL TEST BOARD 3", "1212542434688427"),
    ("oilygears: My Test Project", "1210773240343338"),
]

ARCHIVE_BORDERLINE = [
    ("oilygears: My Big Startup MVP", "1210775136581806", "1 task; might be active demo"),
    ("Dev Wrangler Test Project", "1210986197362617", "100 tasks, 0 completed, all overdue"),
    ("e-claim: ClickClaims", "1210916454584965", "390 tasks, 0 completed, untouched since Oct 2025"),
]


def add_subtasks_to_project(parent_gid, dry_run=False):
    """Add a parent task's direct subtasks to all of the parent's projects.

    Asana gotcha: POST /tasks with `parent` parents the subtask but does NOT
    add it to the parent's projects. Custom fields are project-scoped, so
    setting Priority / Type / Story Points / etc. on an unprojected subtask
    returns 400 ("Custom field with ID X is not on given object"). This
    function is the recovery tool — idempotent, safe to re-run.
    """
    parent = api("GET", f"/tasks/{parent_gid}",
                 params={"opt_fields": "name,projects.gid,projects.name"})
    if not parent:
        return
    parent_data = parent["data"]
    parent_projects = parent_data.get("projects", [])
    if not parent_projects:
        print(f"  ✗ Parent '{parent_data['name']}' has no projects — nothing to do")
        return
    project_gids = {p["gid"]: p["name"] for p in parent_projects}

    subtasks = paginate(f"/tasks/{parent_gid}/subtasks",
                        opt_fields="name,projects.gid")
    print(f"  Parent: {parent_data['name']}")
    print(f"  Parent projects: {', '.join(project_gids.values())}")
    print(f"  Subtasks: {len(subtasks)}")

    added = skipped = 0
    for st in subtasks:
        already = {p["gid"] for p in st.get("projects", [])}
        missing = set(project_gids) - already
        name = st["name"][:60]
        if not missing:
            print(f"    · {name} (already on project)")
            skipped += 1
            continue
        for proj_gid in missing:
            print(f"    + {name} → adding to {project_gids[proj_gid]}")
            api("POST", f"/tasks/{st['gid']}/addProject",
                {"project": proj_gid}, dry_run=dry_run)
        added += 1

    print(f"  Done. {added} added, {skipped} skipped.")


def track_a(dry_run=False, borderline_approved=None):
    print("\n═══ Track A: Archive dead/test projects ═══\n")
    archived = 0

    for name, gid in ARCHIVE_CONFIRMED:
        print(f"  Archiving: {name} ({gid})")
        resp = api("PUT", f"/projects/{gid}", {"archived": True}, dry_run=dry_run)
        if resp:
            archived += 1

    if borderline_approved:
        for name, gid, _ in ARCHIVE_BORDERLINE:
            if gid in borderline_approved:
                print(f"  Archiving (borderline, approved): {name} ({gid})")
                resp = api("PUT", f"/projects/{gid}", {"archived": True}, dry_run=dry_run)
                if resp:
                    archived += 1
            else:
                print(f"  Skipping (not approved): {name}")
    else:
        for name, gid, concern in ARCHIVE_BORDERLINE:
            print(f"  ⚠ Borderline: {name} — {concern}")

    print(f"\n  Total: {archived} archived")
    return archived


# ═══════════════════════════════════════════════════════
# Track B — Create portfolios
# ═══════════════════════════════════════════════════════

CLIENT_PROJECTS = [
    ("PronovosSample", "1213919587797344"),
    ("Paryani Construction", "1214053869901394"),
    ("DeSpir Logistics", "1213743150606707"),
    ("ART - OpenbooQ", "1212346777720881"),
    ("ZyraTalk", "1207620940997924"),
    ("Sully.ai July 2025", "1210833319085956"),
    ("Best of LLC", "1210277198835217"),
    ("Belfry", "1207126324035067"),
    ("Tekmir", "1206272502413754"),
    ("Tauxbe", "1206754197860593"),
    ("SignatureFD", "1208741495486540"),
    ("RevelMG Project", "1212048192376279"),
    ("ELEVAT3 Phase 2", "1214059647960513"),
    ("Lucosky Brookman", "1212048413885035"),
]

INTERNAL_PROJECTS = [
    ("Fraction - DevHawk", "1211037415421037"),
    ("Internal PM", "1209000870646737"),
    ("Internal Architects", "1209426632996311"),
    ("Alyssia Backlog", "1210990145302970"),
    ("2026 Fraction + DH Marketing", "1211008924995548"),
    ("Content Calendar", "1207974249460835"),
]

JEREMY_GID = "1206452951803612"


def create_index_project(ws_gid, name, color, projects, dry_run=False):
    """Fallback: create a meta-project that lists links to other projects (free on all plans)."""
    print(f"  Creating index project: {name}")
    notes_lines = [f"Index of projects in this group:\n"]
    for proj_name, proj_gid in projects:
        notes_lines.append(f"• {proj_name} — https://app.asana.com/0/{proj_gid}")

    resp = api("POST", "/projects", {
        "name": f"📋 {name}",
        "workspace": ws_gid,
        "notes": "\n".join(notes_lines),
        "color": color,
        "owner": JEREMY_GID,
    }, dry_run=dry_run)

    gid = resp["data"]["gid"] if resp else "dry-run"
    return gid


def track_b(ws_gid, dry_run=False):
    print("\n═══ Track B: Create portfolios (or index projects) ═══\n")
    results = {}

    # Try portfolio creation first. If it fails (402/403 = plan doesn't support),
    # fall back to index projects (free on all plans).
    use_portfolios = True

    # Probe: try creating the first portfolio
    test_resp = api("POST", "/portfolios", {
        "name": "Active Client Engagements", "workspace": ws_gid,
        "color": "dark-blue", "owner": JEREMY_GID,
    }, dry_run=dry_run)

    if not test_resp and not dry_run:
        print("  ⚠ Portfolio creation failed — plan may not support portfolios.")
        print("  Falling back to index projects (free on all plans).\n")
        use_portfolios = False

    if use_portfolios:
        # First portfolio already created by the probe
        pgid = test_resp["data"]["gid"] if test_resp else "dry-run"
        results["Active Client Engagements"] = pgid
        for proj_name, proj_gid in CLIENT_PROJECTS:
            print(f"    Adding: {proj_name}")
            api("POST", f"/portfolios/{pgid}/addItem", {"item": proj_gid}, dry_run=dry_run)

        # Second portfolio
        print(f"  Creating portfolio: Fraction Internal")
        resp = api("POST", "/portfolios", {
            "name": "Fraction Internal", "workspace": ws_gid,
            "color": "dark-green", "owner": JEREMY_GID,
        }, dry_run=dry_run)
        pgid = resp["data"]["gid"] if resp else "dry-run"
        results["Fraction Internal"] = pgid
        for proj_name, proj_gid in INTERNAL_PROJECTS:
            print(f"    Adding: {proj_name}")
            api("POST", f"/portfolios/{pgid}/addItem", {"item": proj_gid}, dry_run=dry_run)

        results["_type"] = "portfolios"
    else:
        # Fallback: index projects
        results["Active Client Engagements"] = create_index_project(
            ws_gid, "Active Client Engagements", "dark-blue", CLIENT_PROJECTS, dry_run)
        results["Fraction Internal"] = create_index_project(
            ws_gid, "Fraction Internal", "dark-green", INTERNAL_PROJECTS, dry_run)
        results["_type"] = "index_projects"

    return results


# ═══════════════════════════════════════════════════════
# Track C — Standardize custom fields
# ═══════════════════════════════════════════════════════

EXISTING_FIELDS = {
    "Story Points": "1208941031000919",
    "Release": "1214267151463854",
    "Task Progress": "1204575864766299",
}
RELEASE_FIELD_GID = "1214267151463854"

# Audit tag: stamped on every card created by the `add-card` skill so
# skill-created vs manually-created cards are distinguishable in saved
# views + machine-parseable for audit scripts.
ADD_CARD_AUDIT_TAG_NAME = "devhawk:add-card"


def ensure_audit_tag(dry_run=False):
    """Idempotent: ensure the workspace-level audit tag exists. Returns its gid.

    Asana tags are workspace-scoped (not project-scoped), so this is a one-shot
    per workspace. Safe to re-run — finds the existing tag and prints its gid
    without creating a duplicate.
    """
    me = api("GET", "/users/me", params={"opt_fields": "workspaces.gid"})
    if not me:
        print("Auth failed. Run --auth or set ASANA_PAT.", file=sys.stderr)
        sys.exit(1)
    ws_gid = me["data"]["workspaces"][0]["gid"]

    # Look for an existing tag with the canonical name. The workspace tags
    # endpoint paginates; we accept up to a few hundred tags before giving up.
    for tag in paginate(f"/workspaces/{ws_gid}/tags", opt_fields="name"):
        if tag.get("name") == ADD_CARD_AUDIT_TAG_NAME:
            print(tag["gid"])
            return tag["gid"]

    if dry_run:
        print(f"DRY RUN: would create tag '{ADD_CARD_AUDIT_TAG_NAME}' in workspace {ws_gid}", file=sys.stderr)
        return None

    resp = api("POST", f"/workspaces/{ws_gid}/tags", {"name": ADD_CARD_AUDIT_TAG_NAME})
    if not resp:
        print(f"FAILED to create tag '{ADD_CARD_AUDIT_TAG_NAME}'", file=sys.stderr)
        sys.exit(1)
    tag_gid = resp["data"]["gid"]
    print(tag_gid)
    return tag_gid
RELEASE_OPTIONS = {
    "Phase 1": "1214267151463855",
    "Phase 2": "1214267151463856",
    "Phase 3": "1214267151463857",
    "Phase 4": "1214267151463858",
}


def track_c(ws_gid, dry_run=False):
    print("\n═══ Track C: Standardize custom fields ═══\n")
    new_fields = {}

    print("  Creating field: Fraction Priority")
    resp = api("POST", "/custom_fields", {
        "workspace": ws_gid, "name": "Fraction Priority",
        "resource_subtype": "enum",
        "enum_options": [
            {"name": "P0 — Critical", "color": "red"},
            {"name": "P1 — High", "color": "orange"},
            {"name": "P2 — Medium", "color": "yellow"},
            {"name": "P3 — Low", "color": "cool-gray"},
        ],
    }, dry_run=dry_run)
    priority_gid = resp["data"]["gid"] if resp else "dry-run"
    new_fields["Fraction Priority"] = priority_gid
    priority_options = {}
    if resp and isinstance(resp.get("data"), dict) and resp["data"].get("enum_options"):
        for opt in resp["data"]["enum_options"]:
            priority_options[opt["name"]] = opt["gid"]
    new_fields["priority_options"] = priority_options

    print("  Creating field: Fraction Task Type")
    resp = api("POST", "/custom_fields", {
        "workspace": ws_gid, "name": "Fraction Task Type",
        "resource_subtype": "enum",
        "enum_options": [
            {"name": "EPIC", "color": "purple"},
            {"name": "Story", "color": "blue"},
            {"name": "Bug", "color": "red"},
            {"name": "Chore", "color": "cool-gray"},
            {"name": "Tech Debt", "color": "orange"},
            {"name": "Discussion", "color": "aqua"},
            {"name": "Milestone", "color": "green"},
            {"name": "Spike", "color": "yellow"},
        ],
    }, dry_run=dry_run)
    type_gid = resp["data"]["gid"] if resp else "dry-run"
    new_fields["Fraction Task Type"] = type_gid
    type_options = {}
    if resp and isinstance(resp.get("data"), dict) and resp["data"].get("enum_options"):
        for opt in resp["data"]["enum_options"]:
            type_options[opt["name"]] = opt["gid"]
    new_fields["type_options"] = type_options

    all_fields = {
        "Fraction Priority": priority_gid,
        "Fraction Task Type": type_gid,
        **EXISTING_FIELDS,
    }

    for proj_name, proj_gid in CLIENT_PROJECTS:
        existing = set()
        resp = api("GET", f"/projects/{proj_gid}",
                   params={"opt_fields": "custom_field_settings.custom_field.gid"})
        if resp and isinstance(resp.get("data"), dict):
            for cfs in resp["data"].get("custom_field_settings", []):
                existing.add(cfs.get("custom_field", {}).get("gid", ""))

        for fname, fgid in all_fields.items():
            if fgid in existing:
                print(f"    {proj_name}: {fname} already attached")
                continue
            print(f"    {proj_name}: attaching {fname}")
            api("POST", f"/projects/{proj_gid}/addCustomFieldSetting",
                {"custom_field": fgid, "is_important": True}, dry_run=dry_run)

    return new_fields


# ═══════════════════════════════════════════════════════
# Track D — Fix Paryani Construction
# ═══════════════════════════════════════════════════════

PARYANI_GID = "1214053869901394"
PARYANI_SECTIONS = {
    "PM Onboarding Tasks": "1214053869948957",
    "TODO": "1214053869948965",
    "WIP": "1214053869948967",
    "READY FOR REVIEW": "1214053869949005",
    "READY FOR TESTING": "1214053869948969",
    "READY FOR RELEASE": "1214136370216994",
    "DONE": "1214053869948971",
}

USER_MAP = {
    "austin": "1208216523594274",
    "austin brock": "1208216523594274",
    "jeremy": "1206452951803612",
    "jeremy king": "1206452951803612",
    "andrew": "1210024510759633",
    "andrew c halliburton": "1210024510759633",
    "andrew halliburton": "1210024510759633",
}


def track_d(new_fields=None, dry_run=False):
    print("\n═══ Track D: Fix Paryani Construction ═══\n")
    stats = {"sections_placed": 0, "owners_reassigned": 0, "fields_set": 0, "skipped": []}

    print("  D.1: Setting project metadata...")
    api("PUT", f"/projects/{PARYANI_GID}", {
        "start_on": "2026-04-14", "due_on": "2026-05-15",
        "html_notes": "<body><strong>Paryani Construction — Subcontract Generation Tool</strong><br><br>Rebuild of a previously-prototyped contracts tool. Delivers an 8-step subcontract wizard with AI-assisted quote extraction, gold-standard scope library, BoldSign e-signature, and Acumatica commitment write-back.<br><br><strong>Stack:</strong> Next.js 16, Drizzle, PG 16, Better Auth, BullMQ, DO App Platform.<br><br><strong>Repo:</strong> https://github.com/ParyaniConstructionTechnology/ContractsTool<br><br><strong>Team:</strong> Andrew Halliburton (PM), Austin Brock (eng), Jeremy King (architect).<br><br><strong>MVP target:</strong> 2026-05-15.</body>",
    }, dry_run=dry_run)

    print("  D.2: Posting status update...")
    api("POST", f"/projects/{PARYANI_GID}/project_statuses", {
        "color": "yellow",
        "title": "Discovery complete, backlog structured, execution starting",
        "text": "Week 1 closed with full EPIC-and-Story backlog. PR #1 shipped Tier 0 security hardening. 22 meta/planning tasks closed. Yellow: (a) only 1 feature task shipped in week 1, (b) MVP target May 15 requires sustained velocity, (c) e-sign vendor decision still needs validation.",
    }, dry_run=dry_run)

    print("  Fetching all Paryani tasks...")
    tasks = paginate(f"/projects/{PARYANI_GID}/tasks",
                     opt_fields="name,completed,assignee.gid,assignee.name,notes,memberships.section.gid,custom_fields.gid,custom_fields.number_value,custom_fields.enum_value.gid")
    print(f"  Found {len(tasks)} tasks")

    # D.3 — Section placement
    print("  D.3: Placing orphaned tasks...")
    for task in tasks:
        has_section = any(m.get("section", {}).get("gid") for m in task.get("memberships", []))
        if has_section:
            continue
        section = PARYANI_SECTIONS["DONE"] if task.get("completed") else PARYANI_SECTIONS["TODO"]
        print(f"    → {task.get('name', '')[:50]} → {'DONE' if task.get('completed') else 'TODO'}")
        api("POST", f"/sections/{section}/addTask", {"task": task["gid"]}, dry_run=dry_run)
        stats["sections_placed"] += 1

    # D.4 — Owner reassignment
    print("  D.4: Reassigning owners...")
    owner_pattern = re.compile(r"Owner \(suggested\):\s*(.+)", re.IGNORECASE)
    for task in tasks:
        match = owner_pattern.search(task.get("notes", ""))
        if not match:
            continue
        first_name = re.split(r"\s*\+\s*", match.group(1).strip())[0]
        first_name = re.sub(r"\s*\(.*\)", "", first_name).strip().lower()
        target_gid = USER_MAP.get(first_name)
        if not target_gid:
            stats["skipped"].append(f"{task['name'][:40]}: unknown '{match.group(1).strip()}'")
            continue
        current = task.get("assignee") or {}
        if current.get("gid") == target_gid:
            continue
        print(f"    {task['name'][:50]} → {first_name}")
        api("PUT", f"/tasks/{task['gid']}", {"assignee": target_gid}, dry_run=dry_run)
        stats["owners_reassigned"] += 1

    # D.5 — Attach custom fields
    print("  D.5: Attaching custom fields...")
    all_fields = {}
    if new_fields:
        all_fields["Fraction Priority"] = new_fields.get("Fraction Priority", "")
        all_fields["Fraction Task Type"] = new_fields.get("Fraction Task Type", "")
    all_fields.update(EXISTING_FIELDS)

    existing = set()
    resp = api("GET", f"/projects/{PARYANI_GID}",
               params={"opt_fields": "custom_field_settings.custom_field.gid"})
    if resp and isinstance(resp.get("data"), dict):
        for cfs in resp["data"].get("custom_field_settings", []):
            existing.add(cfs.get("custom_field", {}).get("gid", ""))

    for fname, fgid in all_fields.items():
        if not fgid or fgid == "dry-run":
            continue
        if fgid in existing:
            print(f"    {fname}: already attached")
            continue
        print(f"    Attaching: {fname}")
        api("POST", f"/projects/{PARYANI_GID}/addCustomFieldSetting",
            {"custom_field": fgid, "is_important": True}, dry_run=dry_run)

    # D.6 — Populate field values
    print("  D.6: Populating field values...")
    priority_pattern = re.compile(r"Priority:\s*P(\d)", re.IGNORECASE)
    sp_pattern = re.compile(r"(?:Story Points|Total Story Points):\s*(\d+)", re.IGNORECASE)
    priority_options = (new_fields or {}).get("priority_options", {})
    type_options = (new_fields or {}).get("type_options", {})
    priority_map = {str(i): priority_options.get(f"P{i} — {['Critical','High','Medium','Low'][i]}", "")
                    for i in range(4)}

    for task in tasks:
        name = task.get("name", "")
        notes = task.get("notes", "")
        updates = {}

        pm = priority_pattern.search(notes)
        if pm and new_fields and new_fields.get("Fraction Priority"):
            opt_gid = priority_map.get(pm.group(1))
            if opt_gid:
                updates[new_fields["Fraction Priority"]] = opt_gid

        if new_fields and new_fields.get("Fraction Task Type"):
            if re.match(r"^(EPIC:|Epic:|\[E\d)", name):
                opt = type_options.get("EPIC", "")
                if opt:
                    updates[new_fields["Fraction Task Type"]] = opt
            elif re.search(r"\bBUG\b", name, re.IGNORECASE):
                opt = type_options.get("Bug", "")
                if opt:
                    updates[new_fields["Fraction Task Type"]] = opt
            elif re.search(r"\bDISCUSS\b", name, re.IGNORECASE):
                opt = type_options.get("Discussion", "")
                if opt:
                    updates[new_fields["Fraction Task Type"]] = opt

        spm = sp_pattern.search(notes)
        if spm:
            updates[EXISTING_FIELDS["Story Points"]] = int(spm.group(1))

        if updates:
            print(f"    {name[:50]}: {len(updates)} fields")
            api("PUT", f"/tasks/{task['gid']}", {"custom_fields": updates}, dry_run=dry_run)
            stats["fields_set"] += 1

    print(f"\n  Sections: {stats['sections_placed']} | Owners: {stats['owners_reassigned']} | Fields: {stats['fields_set']}")
    if stats["skipped"]:
        print(f"  Skipped ({len(stats['skipped'])}):")
        for s in stats["skipped"]:
            print(f"    · {s}")
    return stats


# ═══════════════════════════════════════════════════════
# Track E — Clean PronovosSample
# ═══════════════════════════════════════════════════════

PRONOVOS_GID = "1213919587797344"


def track_e(new_fields=None, dry_run=False):
    print("\n═══ Track E: Clean PronovosSample ═══\n")
    sp_prefix = re.compile(r"^\[SP:\s*(\d+)\]\s*")
    tasks = paginate(f"/projects/{PRONOVOS_GID}/tasks", opt_fields="name")
    cleaned = 0

    for task in tasks:
        m = sp_prefix.match(task.get("name", ""))
        if not m:
            continue
        points = int(m.group(1))
        new_name = sp_prefix.sub("", task["name"]).strip()
        updates = {"name": new_name, "custom_fields": {EXISTING_FIELDS["Story Points"]: points}}
        print(f"    {task['name'][:60]} → {new_name[:40]} (SP={points})")
        api("PUT", f"/tasks/{task['gid']}", updates, dry_run=dry_run)
        cleaned += 1

    print(f"\n  Cleaned: {cleaned} tasks")
    return cleaned


# ═══════════════════════════════════════════════════════
# Report
# ═══════════════════════════════════════════════════════

def write_report(results):
    elapsed = time.time() - (START_TIME or time.time())
    lines = [
        "# Asana Cleanup Report",
        f"\n**Date:** {datetime.now().strftime('%Y-%m-%d %H:%M')}",
        f"**API calls:** {CALLS} | **Errors:** {ERRORS} | **Elapsed:** {elapsed:.0f}s\n",
    ]

    if "track_a" in results:
        lines.append(f"## Track A: Archived {results['track_a']} projects\n")

    if "track_b" in results:
        btype = results["track_b"].get("_type", "portfolios")
        lines.append(f"## Track B: {'Portfolios' if btype == 'portfolios' else 'Index Projects (portfolio fallback)'}")
        for name, gid in results["track_b"].items():
            if name.startswith("_"):
                continue
            lines.append(f"- **{name}**: `{gid}` — https://app.asana.com/0/{gid}")

    if "track_c" in results:
        nf = results["track_c"]
        lines.append("## Track C: Custom fields")
        lines.append(f"- **Fraction Priority**: `{nf.get('Fraction Priority', 'n/a')}`")
        lines.append(f"- **Fraction Task Type**: `{nf.get('Fraction Task Type', 'n/a')}`")
        if nf.get("priority_options"):
            for n, g in nf["priority_options"].items():
                lines.append(f"  - {n}: `{g}`")
        if nf.get("type_options"):
            for n, g in nf["type_options"].items():
                lines.append(f"  - {n}: `{g}`")
        lines.append("")

    if "track_d" in results:
        d = results["track_d"]
        lines.append("## Track D: Paryani Construction")
        lines.append(f"- Sections placed: {d.get('sections_placed', 0)}")
        lines.append(f"- Owners reassigned: {d.get('owners_reassigned', 0)}")
        lines.append(f"- Fields populated: {d.get('fields_set', 0)}")
        if d.get("skipped"):
            for s in d["skipped"]:
                lines.append(f"  - ⚠ {s}")
        lines.append("")

    if "track_e" in results:
        lines.append(f"## Track E: PronovosSample — {results['track_e']} tasks cleaned\n")

    report = "\n".join(lines)
    REPORT_FILE.write_text(report)
    print(f"\n{'='*60}")
    print(report)
    print(f"Report: {REPORT_FILE}")


# ═══════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════

def main():
    global START_TIME
    START_TIME = time.time()

    parser = argparse.ArgumentParser(description="Asana workspace operations")
    parser.add_argument("--auth", action="store_true", help="Run PKCE OAuth flow")
    parser.add_argument("--token", action="store_true", help="Print current access token to stdout (for use by other tools). Auto-auths if missing.")
    parser.add_argument("--hygiene", metavar="PROJECT_GID", help="Run full hygiene audit + fix on a project")
    parser.add_argument("--estimate", metavar="PROJECT_GID", help="Auto-estimate story points on unestimated tasks")
    parser.add_argument("--move-section", nargs=2, metavar=("TASK_GID", "SECTION_GID"), help="Move a task to a section")
    parser.add_argument("--new-phase", nargs=2, metavar=("PROJECT_GID", "PHASE_NAME"), help="Create a new phase (Epic group) in an existing project")
    parser.add_argument("--add-release-option", metavar="PHASE_NAME", help="Add a new enum option to the Release custom field (e.g. 'Phase 5')")
    parser.add_argument("--add-sprint-option", metavar="SPRINT_NAME", help="Add a new enum option to the Sprint custom field (convention: 'Sprint M/D-M/D')")
    parser.add_argument("--add-subtasks-to-project", metavar="TASK_GID", help="Add all direct subtasks of TASK_GID to the parent's projects (recovery for the 'parent doesn't auto-project subtasks' Asana gotcha)")
    parser.add_argument("--post-comment", nargs="+", metavar="TASK_GID", help="Post a comment on a task. Pass HTML as the second arg, or '-' to read HTML from stdin. Example: --post-comment 1234 '<body><p>hello</p></body>' or echo '<body>...</body>' | --post-comment 1234 -")
    parser.add_argument("--ensure-audit-tag", action="store_true", help=f"Idempotent: ensure the workspace-level '{ADD_CARD_AUDIT_TAG_NAME}' tag exists; prints its gid. Used by the add-card skill to stamp skill-created cards.")
    parser.add_argument("--track", choices=["A", "B", "C", "D", "E", "all"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--borderline", nargs="*", help="GIDs of borderline projects (Track A)")
    args = parser.parse_args()

    if args.auth:
        oauth_auth()
        return

    if args.token:
        # Print token to stdout for use by curl/other tools.
        # Auto-auth if no token exists.
        if not TOKEN_FILE.exists():
            import sys as _sys
            print("No token found — launching OAuth...", file=_sys.stderr)
            oauth_auth()
        token = get_token()
        print(token)
        return

    if args.move_section:
        task_gid, section_gid = args.move_section
        resp = api("POST", f"/sections/{section_gid}/addTask", {"task": task_gid})
        print("OK" if resp else "FAILED")
        return

    if args.add_release_option:
        resp = api("POST", f"/custom_fields/{RELEASE_FIELD_GID}/enum_options",
                   {"name": args.add_release_option, "insert_before": None})
        if resp:
            print(f"Created: {args.add_release_option} → {resp['data']['gid']}")
        else:
            print("FAILED")
        return

    if args.add_sprint_option:
        resp = api("POST", f"/custom_fields/{SPRINT_FIELD_GID}/enum_options",
                   {"name": args.add_sprint_option, "insert_before": None})
        if resp:
            print(f"Created: {args.add_sprint_option} → {resp['data']['gid']}")
        else:
            print("FAILED")
        return

    if args.new_phase:
        create_new_phase(args.new_phase[0], args.new_phase[1], args.dry_run)
        return

    if args.add_subtasks_to_project:
        add_subtasks_to_project(args.add_subtasks_to_project, args.dry_run)
        return

    if args.post_comment:
        if len(args.post_comment) < 2:
            print("Error: --post-comment requires TASK_GID and HTML (or '-' for stdin)")
            sys.exit(1)
        task_gid = args.post_comment[0]
        html_arg = args.post_comment[1]
        html = sys.stdin.read() if html_arg == "-" else html_arg
        if not html.strip().startswith("<body>") or not html.strip().endswith("</body>"):
            print("Error: HTML must be wrapped in <body>...</body>", file=sys.stderr)
            sys.exit(1)
        resp = api("POST", f"/tasks/{task_gid}/stories", {"html_text": html})
        if resp and isinstance(resp.get("data"), dict):
            story_gid = resp["data"].get("gid", "")
            print(f"OK gid={story_gid}")
        else:
            print("FAILED")
            sys.exit(1)
        return

    if args.ensure_audit_tag:
        ensure_audit_tag(args.dry_run)
        return

    if args.hygiene:
        hygiene_audit(args.hygiene, args.dry_run)
        return

    if args.estimate:
        auto_estimate(args.estimate)
        return

    if not args.track:
        parser.print_help()
        return

    # Verify auth works
    me = api("GET", "/users/me", params={"opt_fields": "name,workspaces.gid"})
    if not me:
        print("Auth failed. Run --auth or set ASANA_PAT.")
        sys.exit(1)
    ws_gid = me["data"]["workspaces"][0]["gid"]
    print(f"User: {me['data']['name']} | Workspace: {ws_gid}")
    print(f"Mode: {'DRY RUN' if args.dry_run else 'LIVE'}\n")

    results = {}
    tracks = ["A", "B", "C", "D"] if args.track == "all" else [args.track]

    if "A" in tracks:
        results["track_a"] = track_a(args.dry_run, set(args.borderline or []))

    new_fields = None
    if "C" in tracks:
        new_fields = track_c(ws_gid, args.dry_run)
        results["track_c"] = new_fields

    if "B" in tracks:
        results["track_b"] = track_b(ws_gid, args.dry_run)

    if "D" in tracks:
        results["track_d"] = track_d(new_fields, args.dry_run)

    if "E" in tracks:
        results["track_e"] = track_e(new_fields, args.dry_run)

    write_report(results)


if __name__ == "__main__":
    main()
