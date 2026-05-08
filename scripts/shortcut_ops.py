#!/usr/bin/env python3
"""
Shortcut workspace operations — custom field creation, bulk updates,
and hygiene checks that the Shortcut MCP may not cover.

Auth: SHORTCUT_API_TOKEN env var (generate at Shortcut → Settings → API Tokens).

Usage:
  export SHORTCUT_API_TOKEN="..."
  python3 scripts/shortcut_ops.py --setup          # Create standard custom fields
  python3 scripts/shortcut_ops.py --audit <project> # Audit a project
  python3 scripts/shortcut_ops.py --audit <project> --fix  # Fix gaps
"""

import argparse
import json
import os
import re
import sys
import time
from datetime import datetime
from pathlib import Path

import requests

# ── Config ──
BASE = "https://api.app.shortcut.com/api/v3"
TOKEN = os.environ.get("SHORTCUT_API_TOKEN", "")
HEADERS = {"Shortcut-Token": TOKEN, "Content-Type": "application/json"}
LOG_FILE = Path("shortcut_ops.log")

CALLS = 0
ERRORS = 0


def log(method, path, status, detail=""):
    global CALLS
    CALLS += 1
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"{ts} {method:6s} {path} → {status} {detail}"
    print(f"  {line}")
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


def api(method, path, data=None, params=None):
    url = f"{BASE}{path}"
    resp = requests.request(method, url, headers=HEADERS, json=data, params=params)

    if resp.status_code == 429:
        retry = int(resp.headers.get("Retry-After", 30))
        print(f"  ⏳ Rate limited, waiting {retry}s...")
        time.sleep(retry)
        return api(method, path, data, params)

    detail = ""
    try:
        body = resp.json()
        if isinstance(body, dict):
            detail = body.get("id", "")
    except Exception:
        body = {}

    log(method, path, resp.status_code, str(detail))

    if resp.status_code >= 400:
        global ERRORS
        ERRORS += 1
        print(f"  ✗ {resp.status_code}: {resp.text[:200]}")
        return None

    return body


# ═══════════════════════════════════════════════════════
# Setup — create standard custom fields
# ═══════════════════════════════════════════════════════

def setup_custom_fields():
    """Create the Priority custom field if it doesn't exist."""
    print("\n═══ Setup: Standard Custom Fields ═══\n")

    # Check existing custom fields
    existing = api("GET", "/custom-fields")
    if existing:
        for cf in existing:
            if cf.get("name") == "Priority":
                print(f"  Priority field already exists: {cf['id']}")
                print(f"  Values: {[v['value'] for v in cf.get('values', [])]}")
                return cf

    # Create Priority field
    print("  Creating Priority custom field...")
    result = api("POST", "/custom-fields", {
        "name": "Priority",
        "description": "Task priority level",
        "field_type": "enum",
        "values": [
            {"value": "P0 — Critical", "color_key": "red", "position": 0},
            {"value": "P1 — High", "color_key": "orange", "position": 1},
            {"value": "P2 — Medium", "color_key": "yellow", "position": 2},
            {"value": "P3 — Low", "color_key": "gray", "position": 3},
        ],
    })

    if result:
        print(f"  Created: {result.get('id')}")
    return result


# ═══════════════════════════════════════════════════════
# Audit — check a project against best practices
# ═══════════════════════════════════════════════════════

_VAGUE_VERBS = {"fix", "update", "tweak", "change", "adjust", "modify", "edit", "improve"}
_VAGUE_PREFIX_RE = re.compile(r"^\[[A-Z]+-\d+\]\s*")
_VAGUE_MARKER_RE = re.compile(r"\b(misc|todo|tbd)\b", re.IGNORECASE)


def _is_vague_title(name):
    """Flag titles that are short + start with a generic verb, or contain TBD/TODO/misc.

    Strips a leading [KEY-N] tracker prefix before evaluating length so
    migrated stories aren't penalized for the prefix's word count.
    """
    if _VAGUE_MARKER_RE.search(name):
        return True
    body = _VAGUE_PREFIX_RE.sub("", name).strip()
    words = body.split()
    if not words:
        return True
    return len(words) <= 4 and words[0].lower() in _VAGUE_VERBS


def _print_offenders(items, indent="     ", max_show=20):
    """Print story name + app_url for each offender, capped at max_show."""
    for s in items[:max_show]:
        print(f"{indent}• {s.get('name', '<no name>')}")
        if s.get("app_url"):
            print(f"{indent}  {s['app_url']}")
    if len(items) > max_show:
        print(f"{indent}... and {len(items) - max_show} more")


def audit_project(project_name, fix=False):
    """Audit a Shortcut project against best practices."""
    print(f"\n═══ Audit: {project_name} ═══\n")

    # Find the project
    projects = api("GET", "/projects")
    if not projects:
        print("  ✗ Could not list projects")
        return

    project = None
    for p in projects:
        if p.get("name", "").lower() == project_name.lower():
            project = p
            break

    if not project:
        print(f"  ✗ Project '{project_name}' not found")
        print(f"  Available: {[p['name'] for p in projects]}")
        return

    pid = project["id"]
    print(f"  Project: {project['name']} (ID: {pid})")

    # Get workflow states. Identify Inbox state(s) (case-insensitive name match,
    # type=unstarted) so field-strict checks can skip them — same model as
    # asana_ops.py's LIGHT_VALIDATION_SECTIONS for "INBOX".
    workflows = api("GET", "/workflows")
    states = {}
    inbox_state_ids = set()
    if workflows:
        for wf in workflows:
            for s in wf.get("states", []):
                states[s["id"]] = {"name": s["name"], "type": s["type"]}
                if s["type"] == "unstarted" and s.get("name", "").strip().lower() == "inbox":
                    inbox_state_ids.add(s["id"])

    # Get stories in this project
    stories = api("GET", f"/projects/{pid}/stories")
    if stories is None:
        stories = []

    print(f"  Stories: {len(stories)}")

    # 1. Priority custom field exists?
    custom_fields = api("GET", "/custom-fields") or []
    priority_field = next((cf for cf in custom_fields if cf["name"] == "Priority"), None)
    if priority_field:
        print(f"  ✅ Priority custom field exists")
    else:
        print(f"  ❌ Priority custom field MISSING — run --setup")

    incomplete = [s for s in stories if not s.get("completed")]

    # Inbox-vs-strict split. Field-strict checks skip Inbox stories (estimate /
    # owner / story_type / Priority / iteration are deferred until the
    # promotion conversation). Title / description / source-attribution checks
    # still apply to Inbox.
    inbox = [s for s in incomplete if s.get("workflow_state_id") in inbox_state_ids]
    strict = [s for s in incomplete if s.get("workflow_state_id") not in inbox_state_ids]

    if inbox:
        print(f"  Inbox: {len(inbox)} story(ies) awaiting stakeholder discussion")
        # Stale Inbox: stories sitting in Inbox >30 days
        from datetime import datetime, timezone
        STALE_DAYS = 30
        now = datetime.now(timezone.utc)
        stale = []
        for s in inbox:
            ts = s.get("updated_at") or s.get("created_at")
            if not ts:
                continue
            try:
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                if (now - dt).days >= STALE_DAYS:
                    stale.append(s)
            except (ValueError, AttributeError):
                pass
        if stale:
            print(f"  Stale Inbox (>{STALE_DAYS}d no activity): {len(stale)}")
            _print_offenders(stale)

    # 2. Stories without estimate — strict only
    no_estimate = [s for s in strict if not s.get("estimate")]
    print(f"  No estimate (excl. Inbox): {len(no_estimate)} of {len(strict)}")
    _print_offenders(no_estimate)

    # 3. Stories without owner — strict only
    no_owner = [s for s in strict if not s.get("owner_ids")]
    print(f"  No owner (excl. Inbox): {len(no_owner)} of {len(strict)}")
    _print_offenders(no_owner)

    # 4. Stories without story_type — strict only
    no_type = [s for s in strict if not s.get("story_type")]
    print(f"  No story type (excl. Inbox): {len(no_type)} of {len(strict)}")
    _print_offenders(no_type)

    # 5. Stories without epic — strict only (Inbox stories may not have an epic yet)
    no_epic = [s for s in strict if not s.get("epic_id")]
    print(f"  No epic (excl. Inbox): {len(no_epic)} of {len(strict)}")
    _print_offenders(no_epic)

    # 6. Stories without Priority — strict only
    if priority_field:
        pfid = priority_field["id"]
        no_priority = []
        for s in strict:
            cf_values = {cf["field_id"]: cf.get("value") for cf in s.get("custom_fields", [])}
            if pfid not in cf_values or not cf_values[pfid]:
                no_priority.append(s)
        print(f"  No Priority (excl. Inbox): {len(no_priority)} of {len(strict)}")
        _print_offenders(no_priority)

    # 7. Vague titles — applies to ALL stages including Inbox
    vague = [s for s in incomplete if _is_vague_title(s.get("name", ""))]
    print(f"  Vague titles: {len(vague)}")
    _print_offenders(vague)

    # 8. Empty descriptions — applies to ALL stages including Inbox
    no_desc = [s for s in incomplete if not (s.get("description") or "").strip()]
    print(f"  Empty descriptions: {len(no_desc)}")
    _print_offenders(no_desc)

    # 9. Stories not in any Iteration (equivalent of Asana Sprint) — strict only
    no_iter = [s for s in strict if not s.get("iteration_id")]
    print(f"  No Iteration (excl. Inbox): {len(no_iter)} of {len(strict)}")
    _print_offenders(no_iter)

    print(f"\n  API calls: {CALLS} | Errors: {ERRORS}")


# ═══════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════

def main():
    parser = argparse.ArgumentParser(description="Shortcut workspace operations")
    parser.add_argument("--setup", action="store_true", help="Create standard custom fields")
    parser.add_argument("--audit", metavar="PROJECT", help="Audit a project by name")
    parser.add_argument("--fix", action="store_true", help="Fix gaps found during audit")
    args = parser.parse_args()

    if not TOKEN:
        print("Error: SHORTCUT_API_TOKEN not set")
        print("Generate at: Shortcut → Settings → API Tokens")
        sys.exit(1)

    # Verify auth
    me = api("GET", "/member")
    if not me:
        print("Auth failed. Check SHORTCUT_API_TOKEN.")
        sys.exit(1)
    print(f"User: {me.get('profile', {}).get('name', 'unknown')}")

    if args.setup:
        setup_custom_fields()
    elif args.audit:
        audit_project(args.audit, fix=args.fix)
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
