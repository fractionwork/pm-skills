#!/usr/bin/env python3
"""ado_asana_sync.py — mirror Azure DevOps work items into an Asana board.

Scope: work items assigned to the configured people (Jeremy, Belle). Creates new
Asana cards, updates changed ones (fields + status/section), and mirrors ADO
comments one-way (ADO -> Asana). ADO is the source of truth; Asana is the mirror.

Reuses scripts/asana_ops.py for all Asana access (auth, api(), section/enum
resolution). Hits Azure DevOps via REST with PAT Basic auth. Correlation +
incremental watermark + per-item comment marker live in a local JSON state file.

Usage:
  ado_asana_sync.py --config @config.json        # seed people + project into state (first time)
  ado_asana_sync.py --dry-run [--since ISO] [--only ADO_ID]
  ado_asana_sync.py [--only ADO_ID]              # apply
Env: ADO_PAT (preferred) or --pat-file <chmod-600 path>; ADO_ORG_URL, ADO_PROJECT.
"""
import argparse
import base64
import fcntl
import html as _html
import json
import os
import re
import sys
from datetime import datetime, timedelta
from hashlib import sha1
from html.parser import HTMLParser
from pathlib import Path
from typing import NoReturn
from urllib.parse import quote

import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asana_ops  # type: ignore  # noqa: E402  (same-dir reuse)
import ado_auth  # type: ignore  # noqa: E402  (central per-org PAT store)

# ───────────────────────── config ─────────────────────────
# Org/project are per-consumer config (seeded via --config into the state file, or
# via env). No hardcoded org default — keeps the script seed-portable.
DEFAULT_ORG = os.environ.get("ADO_ORG_URL")
DEFAULT_PROJECT = os.environ.get("ADO_PROJECT")
API_VER = "7.1"
STATE_PATH = Path(os.environ.get("ADO_ASANA_STATE",
                                 str(Path.home() / ".claude" / ".ado_asana_state.json")))
LOCK_PATH = Path(str(STATE_PATH) + ".lock")

PRIORITY_FIELD = asana_ops.PRIORITY_FIELD_GID
TYPE_FIELD = asana_ops.TYPE_FIELD_GID
SP_FIELD = asana_ops.SP_FIELD_GID

# ADO state (lower-cased) -> Asana section name. Operator-overridable via config.
DEFAULT_STATE_SECTION = {
    "new": "INBOX", "proposed": "INBOX",
    "approved": "BACKLOG", "to do": "BACKLOG",
    "committed": "TODO",
    "active": "WIP", "in progress": "WIP", "doing": "WIP",
    "in review": "READY FOR REVIEW", "code review": "READY FOR REVIEW",
    "resolved": "READY FOR TESTING", "testing": "READY FOR TESTING",
    "done": "DONE", "closed": "DONE", "completed": "DONE", "removed": "DONE",
}
DONE_STATES = {"done", "closed", "completed", "removed"}

# ADO work-item type (lower-cased) -> Fraction Task Type option name.
TYPE_MAP = {
    "epic": "EPIC", "feature": "EPIC",
    "user story": "Story", "product backlog item": "Story", "story": "Story",
    "bug": "Bug", "task": "Chore", "issue": "Tech Debt", "impediment": "Tech Debt",
}
PRIORITY_MAP = {1: "P0", 2: "P1", 3: "P2", 4: "P3"}  # ADO Priority -> Fraction Priority prefix

ADO_FIELDS = [
    "System.Id", "System.Title", "System.State", "System.WorkItemType",
    "System.Description", "System.AssignedTo", "System.Tags", "System.ChangedDate",
    "System.AreaPath", "System.Reason", "Microsoft.VSTS.Common.AcceptanceCriteria",
    "Microsoft.VSTS.Common.Priority", "Microsoft.VSTS.Common.Severity",
    "Microsoft.VSTS.Scheduling.StoryPoints",
]


def die(msg) -> NoReturn:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


# ───────────────────────── state ─────────────────────────
def load_state():
    if STATE_PATH.exists():
        return json.loads(STATE_PATH.read_text())
    return {"last_changed_high_water": None, "people": {}, "asana_project_gid": None,
            "org_url": DEFAULT_ORG, "project": DEFAULT_PROJECT,
            "state_section": {}, "items": {}}


def save_state(state):
    STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STATE_PATH.write_text(json.dumps(state, indent=2))
    os.chmod(STATE_PATH, 0o600)


# ───────────────────────── ADO PAT + REST ─────────────────────────
def load_pat(org, pat_file=None):
    # env → --pat-file → central per-org store (~/.claude/.ado-credentials.json).
    return ado_auth.require_pat(org, pat_file)


def ado_session(pat):
    s = requests.Session()
    tok = base64.b64encode(f":{pat}".encode()).decode()
    s.headers.update({"Authorization": f"Basic {tok}", "Content-Type": "application/json"})
    return s


def _esc_wiql(v):
    return v.replace("'", "''")


def ado_wiql(s, base, project, emails, since=None):
    assigned = " OR ".join(f"[System.AssignedTo] = '{_esc_wiql(e)}'" for e in emails)
    q = (f"SELECT [System.Id] FROM WorkItems "
         f"WHERE [System.TeamProject] = '{_esc_wiql(project)}' AND ({assigned})")
    if since:
        q += f" AND [System.ChangedDate] >= '{since}'"
    q += " ORDER BY [System.ChangedDate] DESC"
    url = f"{base}/{quote(project)}/_apis/wit/wiql?api-version={API_VER}"
    r = s.post(url, json={"query": q}, timeout=30)
    if r.status_code >= 400:
        die(f"WIQL failed {r.status_code}: {r.text[:300]}")
    return [w["id"] for w in r.json().get("workItems", [])]


def ado_fetch_batch(s, base, ids):
    out = {}
    for i in range(0, len(ids), 200):
        chunk = ids[i:i + 200]
        url = f"{base}/_apis/wit/workitemsbatch?api-version={API_VER}"
        r = s.post(url, json={"ids": chunk, "fields": ADO_FIELDS}, timeout=60)
        if r.status_code >= 400:
            die(f"workitemsbatch failed {r.status_code}: {r.text[:300]}")
        for wi in r.json().get("value", []):
            out[wi["id"]] = wi.get("fields", {})
    return out


def ado_comments(s, base, project, wid):
    url = (f"{base}/{quote(project)}/_apis/wit/workItems/{wid}/comments"
           f"?api-version=7.1-preview.4")
    r = s.get(url, timeout=30)
    if r.status_code == 404:
        return []
    if r.status_code >= 400:
        print(f"  ! comments fetch failed for #{wid}: {r.status_code}", file=sys.stderr)
        return []
    return sorted(r.json().get("comments", []), key=lambda c: c.get("id", 0))


# ───────────────────────── HTML sanitizer (ADO -> Asana allowlist) ─────────────────────────
# Asana rich text supports a small tag set; we deliberately avoid <p> (use newlines)
# to sidestep allowlist ambiguity, keep inline + list + heading + link + code structure.
_MAP = {"b": "strong", "strong": "strong", "i": "em", "em": "em", "u": "em",
        "s": "s", "strike": "s", "del": "s", "code": "code", "pre": "pre",
        "blockquote": "blockquote", "h1": "h1", "h2": "h2", "h3": "h2",
        "ul": "ul", "ol": "ol", "li": "li", "a": "a"}
_BREAK = {"p", "div", "br", "tr", "h4", "h5", "h6"}


class _Sanitizer(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out, self.stack = [], []

    def handle_starttag(self, tag, attrs):
        tag = tag.lower()
        if tag == "br":
            self.out.append("\n")
            return
        mapped = _MAP.get(tag)
        if mapped == "a":
            href = dict(attrs).get("href", "")
            if href:
                self.out.append(f'<a href="{_html.escape(href, quote=True)}">')
                self.stack.append("a")
        elif mapped:
            self.out.append(f"<{mapped}>")
            self.stack.append(mapped)
        elif tag in _BREAK:
            self.out.append("\n")

    def handle_endtag(self, tag):
        tag = tag.lower()
        mapped = _MAP.get(tag)
        if mapped and self.stack and self.stack[-1] == mapped:
            self.out.append(f"</{self.stack.pop()}>")
        elif tag in _BREAK:
            self.out.append("\n")

    def handle_data(self, data):
        self.out.append(_html.escape(data))

    def result(self):
        while self.stack:
            self.out.append(f"</{self.stack.pop()}>")
        text = re.sub(r"\n{3,}", "\n\n", "".join(self.out)).strip()
        return text


def ado_html_to_asana(html):
    if not html:
        return ""
    p = _Sanitizer()
    p.feed(html)
    return p.result()


def html_to_text(html):
    """Flatten sanitized Asana HTML to plain text — the fallback when Asana rejects
    rich html_notes (its <pre>/nesting rules are stricter than its comment parser)."""
    return re.sub(r"\n{3,}", "\n\n", _html.unescape(re.sub(r"<[^>]+>", "", html))).strip()


def wrap_body(inner):
    return f"<body>{inner}</body>" if inner.strip() else "<body> </body>"


# ───────────────────────── field mapping ─────────────────────────
def _assignee_email(field_val):
    if isinstance(field_val, dict):
        return (field_val.get("uniqueName") or field_val.get("mail") or "").strip()
    return ""


def section_for_state(state_str, overrides):
    key = (state_str or "").strip().lower()
    return (overrides or {}).get(key) or DEFAULT_STATE_SECTION.get(key)


def build_footer(org, project, wid, tags):
    url = f"{org}/{quote(project)}/_workitems/edit/{wid}"
    tagline = f" · ADO-Tags: {tags}" if tags else ""
    return (f"\n———\n"
            f'<em>Source: Azure DevOps work item #{wid}</em> '
            f'<a href="{_html.escape(url, quote=True)}">{_html.escape(url)}</a>\n'
            f"<em>External-ID: ado:{wid}{tagline} · Mirrored-By: ado-asana-sync</em>")


def map_fields(f, org, project, overrides):
    wid = f["System.Id"]
    title = f.get("System.Title") or f"ADO #{wid}"
    state = f.get("System.State") or ""
    wtype = (f.get("System.WorkItemType") or "").strip().lower()
    desc = ado_html_to_asana(f.get("System.Description") or "")
    ac = ado_html_to_asana(f.get("Microsoft.VSTS.Common.AcceptanceCriteria") or "")
    tags = f.get("System.Tags") or ""
    body_inner = desc
    if ac:
        body_inner += f"\n<h2>Acceptance Criteria</h2>\n{ac}"
    tags_clean = ", ".join(t.strip() for t in tags.split(";") if t.strip())
    body_inner += build_footer(org, project, wid, tags_clean)
    pri = f.get("Microsoft.VSTS.Common.Priority")
    points = f.get("Microsoft.VSTS.Scheduling.StoryPoints")
    return {
        "name": title,
        "html_notes": wrap_body(body_inner),
        "desc_hash": sha1((desc + "||" + ac + "||" + tags).encode()).hexdigest()[:16],
        "state": state,
        "section": section_for_state(state, overrides),
        "type_name": TYPE_MAP.get(wtype),
        "priority_name": PRIORITY_MAP.get(int(pri)) if pri is not None else None,
        "points": points,
        "assignee_email": _assignee_email(f.get("System.AssignedTo")),
        "done": (state or "").strip().lower() in DONE_STATES,
    }


SNAPSHOT_KEYS = ["name", "desc_hash", "state", "type_name", "priority_name", "points", "assignee_email"]


def snapshot(mapped):
    return {k: mapped[k] for k in SNAPSHOT_KEYS}


# ───────────────────────── Asana helpers (via asana_ops) ─────────────────────────
_enum_cache = {}


def enum_gid(field_gid, name):
    if not name:
        return None
    key = (field_gid, name)
    if key not in _enum_cache:
        _enum_cache[key] = asana_ops.resolve_enum_option(field_gid, name)
    return _enum_cache[key]


def custom_fields_payload(mapped):
    cf = {}
    g = enum_gid(PRIORITY_FIELD, mapped["priority_name"])
    if g:
        cf[PRIORITY_FIELD] = g
    g = enum_gid(TYPE_FIELD, mapped["type_name"])
    if g:
        cf[TYPE_FIELD] = g
    if mapped["points"] is not None:
        cf[SP_FIELD] = mapped["points"]
    return cf


def asana_gid_for_email(email, people):
    for p in people.values():
        if (p.get("ado_email") or "").lower() == (email or "").lower() and p.get("asana_gid"):
            return p["asana_gid"]
    if not email:
        return None
    ws = asana_ops.resolve_workspace()
    for u in asana_ops.paginate(f"/workspaces/{ws}/users", opt_fields="email"):
        if (u.get("email") or "").lower() == email.lower():
            return u["gid"]
    return None


def build_recovery_index(project_gid):
    """Scan the project once, mapping ado_id -> task_gid from the External-ID footer
    in each task's notes. Used to re-find cards when the state file is missing/stale."""
    idx = {}
    for t in asana_ops.paginate(f"/projects/{project_gid}/tasks", opt_fields="notes"):
        m = re.search(r"External-ID:\s*ado:(\d+)", t.get("notes") or "")
        if m:
            idx[int(m.group(1))] = t["gid"]
    return idx


# ───────────────────────── orchestration ─────────────────────────
def to_wiql_date(value, overlap_days=0):
    """ADO WIQL compares [System.ChangedDate] with DATE precision — a time component
    is rejected. Return YYYY-MM-DD, minus an optional overlap day. Per-item ChangedDate
    + field-hash still skip same-day unchanged items, so granularity isn't lost."""
    v = value.strip()
    try:
        dt = datetime.fromisoformat(v.replace("Z", "+00:00"))
    except ValueError:
        dt = datetime.fromisoformat(v)  # already a bare date
    return (dt - timedelta(days=overlap_days)).strftime("%Y-%m-%d")


def sync(args):
    state = load_state()
    if args.config:
        cfg = _read_json(args.config)
        for k in ("people", "asana_project_gid", "org_url", "project", "state_section"):
            if k in cfg:
                if k in ("people", "state_section") and isinstance(cfg[k], dict):
                    state.setdefault(k, {}).update(cfg[k])
                else:
                    state[k] = cfg[k]
        save_state(state)
        print(f"config merged into {STATE_PATH}")

    org = state.get("org_url") or DEFAULT_ORG
    project = state.get("project") or DEFAULT_PROJECT
    project_gid = args.project or state.get("asana_project_gid")
    people = state.get("people") or {}
    overrides = state.get("state_section") or {}
    if not org or not project:
        die("no ADO org/project — set them in --config (org_url, project) or via ADO_ORG_URL/ADO_PROJECT")
    if not project_gid:
        die("no Asana project — pass --project <gid> or set asana_project_gid in --config")
    emails = [p["ado_email"] for p in people.values() if p.get("ado_email")]
    if not emails:
        die("no people configured — seed people via --config (label -> {ado_email, asana_gid})")

    pat = load_pat(org, args.pat_file)
    s = ado_session(pat)
    base = org.rstrip("/")

    # Which items? --only, else WIQL since watermark (with overlap), else full backfill.
    if args.only:
        ids = [int(args.only)]
    else:
        wm = args.since or state.get("last_changed_high_water")
        # User --since: respect their date as-is. Stored watermark: back off 1 day for safety.
        since = to_wiql_date(wm, overlap_days=0 if args.since else 1) if wm else None
        ids = ado_wiql(s, base, project, emails, since)
    if not ids:
        print("No matching work items. Up to date.")
        return

    fields = ado_fetch_batch(s, base, ids)
    # Lazy recovery index only if some items lack a state record.
    recovery = None
    items_state = state.setdefault("items", {})

    planned = []  # (wid, mapped, asana_gid_or_None, changed_keys, section_move, new_comments)
    max_changed = state.get("last_changed_high_water")

    for wid in ids:
        f = fields.get(wid)
        if not f:
            continue
        changed_date = f.get("System.ChangedDate")
        if changed_date and (max_changed is None or changed_date > max_changed):
            max_changed = changed_date
        mapped = map_fields(f, org, project, overrides)
        rec = items_state.get(str(wid))
        asana_gid = rec.get("asana_gid") if rec else None
        if asana_gid is None:
            if recovery is None:
                recovery = build_recovery_index(project_gid)
            asana_gid = recovery.get(wid)

        # changed fields (vs stored snapshot)
        changed_keys = []
        if asana_gid and rec:
            old = rec.get("mapped", {})
            new = snapshot(mapped)
            changed_keys = [k for k in SNAPSHOT_KEYS if old.get(k) != new.get(k)]
        # section move?
        cur_section = rec.get("section") if rec else None
        section_move = mapped["section"] and mapped["section"] != cur_section
        # new comments
        last_cid = rec.get("last_synced_comment_id", 0) if rec else 0
        comments = ado_comments(s, base, project, wid)
        new_comments = [c for c in comments if c.get("id", 0) > last_cid]

        if asana_gid is None or changed_keys or section_move or new_comments:
            planned.append((wid, mapped, asana_gid, changed_keys, section_move, new_comments, comments))

    # ── report ──
    creates = [p for p in planned if p[2] is None]
    updates = [p for p in planned if p[2] is not None]
    print(f"\n{'DRY RUN — ' if args.dry_run else ''}Plan: {len(creates)} create, "
          f"{len(updates)} update, "
          f"{sum(len(p[5]) for p in planned)} comment(s) across {len(planned)} item(s)\n")
    for wid, mapped, gid, ck, sm, nc, _ in planned:
        if gid is None:
            print(f"  CREATE  #{wid}  {mapped['name'][:60]!r}  → {mapped['section']}  "
                  f"[{mapped['type_name']}/{mapped['priority_name']}/{mapped['assignee_email']}]"
                  f"{'  +' + str(len(nc)) + ' comment(s)' if nc else ''}")
        else:
            bits = list(ck)
            if sm:
                bits.append(f"section→{mapped['section']}")
            if nc:
                bits.append(f"+{len(nc)} comment(s)")
            print(f"  UPDATE  #{wid}  [{', '.join(bits) or 'no-op'}]")
    if args.dry_run:
        print("\n(dry run — no Asana writes)")
        return
    if not planned:
        print("Nothing to apply.")
        _advance(state, max_changed, args)
        return

    bulk = len(planned) >= 6 or not state.get("last_changed_high_water")
    if bulk:
        print("(bulk batch / first run — keeping output terse; notifications minimized by batch)\n")

    # ── apply ──
    for wid, mapped, gid, ck, sm, nc, comments in planned:
        try:
            if gid is None:
                gid = _create(project_gid, mapped, people)
                if not gid:
                    print(f"  ✗ create failed for #{wid}")
                    continue
                print(f"  ✓ created #{wid} → {gid}")
            else:
                _update(gid, mapped, ck)
                if sm:
                    _move(project_gid, gid, mapped["section"])
                if ck or sm:
                    print(f"  ✓ updated #{wid}")
            # comments (one-way ADO→Asana)
            posted_max = 0
            for c in nc:
                _post_comment(gid, c)
                posted_max = max(posted_max, c.get("id", 0))
            # complete if a DONE state
            if mapped["done"]:
                asana_ops.api("PUT", f"/tasks/{gid}", {"completed": True})
            # persist
            items_state[str(wid)] = {
                "asana_gid": gid,
                "last_changed_date": fields[wid].get("System.ChangedDate"),
                "last_synced_comment_id": max(posted_max,
                                              (items_state.get(str(wid), {}) or {}).get("last_synced_comment_id", 0)),
                "section": mapped["section"] or (items_state.get(str(wid), {}) or {}).get("section"),
                "mapped": snapshot(mapped),
            }
            save_state(state)  # checkpoint after each item (resumable)
        except Exception as e:  # noqa: BLE001 — never let one item abort the batch
            print(f"  ✗ #{wid}: {e}", file=sys.stderr)

    _advance(state, max_changed, args)
    print(f"\nDone. Watermark: {state['last_changed_high_water']}")


def _advance(state, max_changed, args):
    if not args.only and max_changed:
        state["last_changed_high_water"] = max_changed
    save_state(state)


def _create(project_gid, mapped, people):
    payload = {"name": mapped["name"], "projects": [project_gid],
               "html_notes": mapped["html_notes"]}
    cf = custom_fields_payload(mapped)
    if cf:
        payload["custom_fields"] = cf
    ag = asana_gid_for_email(mapped["assignee_email"], people)
    if ag:
        payload["assignee"] = ag
    created = asana_ops.api("POST", "/tasks", payload)
    if (not created or not isinstance(created.get("data"), dict)) and "html_notes" in payload:
        # Asana rejected the rich body (strict html_notes rules, e.g. <pre>) — retry as plain text.
        print("  ↩ retrying create with plain-text notes (rich body rejected)")
        payload.pop("html_notes")
        payload["notes"] = html_to_text(mapped["html_notes"])
        created = asana_ops.api("POST", "/tasks", payload)
    if not created or not isinstance(created.get("data"), dict):
        return None
    gid = created["data"]["gid"]
    if mapped["section"]:
        _move(project_gid, gid, mapped["section"])
    return gid


def _update(gid, mapped, changed_keys):
    payload = {}
    if "name" in changed_keys:
        payload["name"] = mapped["name"]
    if "desc_hash" in changed_keys:
        payload["html_notes"] = mapped["html_notes"]
    cf = {}
    if "priority_name" in changed_keys:
        g = enum_gid(PRIORITY_FIELD, mapped["priority_name"])
        if g:
            cf[PRIORITY_FIELD] = g
    if "type_name" in changed_keys:
        g = enum_gid(TYPE_FIELD, mapped["type_name"])
        if g:
            cf[TYPE_FIELD] = g
    if "points" in changed_keys and mapped["points"] is not None:
        cf[SP_FIELD] = mapped["points"]
    if cf:
        payload["custom_fields"] = cf
    if "assignee_email" in changed_keys:
        payload["assignee"] = asana_gid_for_email(mapped["assignee_email"], {}) or None
    if payload:
        asana_ops.api("PUT", f"/tasks/{gid}", payload)


def _move(project_gid, gid, section_name):
    try:
        sec = asana_ops._resolve_section_gid(project_gid, section_name)
        asana_ops.api("POST", f"/sections/{sec}/addTask", {"task": gid})
    except ValueError as e:
        print(f"  ! section move skipped: {e}", file=sys.stderr)


def _post_comment(gid, c):
    author = ((c.get("createdBy") or {}).get("displayName")) or "ADO user"
    date = (c.get("createdDate") or "")[:10]
    body = ado_html_to_asana(c.get("text") or "")
    html = f"<body><em>ADO comment by {_html.escape(author)} on {date}</em>\n{body}</body>"
    asana_ops.api("POST", f"/tasks/{gid}/stories", {"html_text": html})


def _read_json(arg):
    raw = Path(arg[1:]).read_text() if arg.startswith("@") else arg
    return json.loads(raw)


def main():
    ap = argparse.ArgumentParser(description="Mirror Azure DevOps work items into Asana.")
    ap.add_argument("--dry-run", action="store_true", help="Show the plan; write nothing.")
    ap.add_argument("--since", metavar="ISO", help="Override the change watermark (e.g. 2026-06-01T00:00:00Z). No value + no stored watermark = full backfill.")
    ap.add_argument("--only", metavar="ADO_ID", help="Sync a single work item id (ignores the watermark; doesn't advance it).")
    ap.add_argument("--project", metavar="ASANA_GID", help="Target Asana project gid (else from state).")
    ap.add_argument("--config", metavar="JSON|@file", help="Merge config into state: {people:{label:{ado_email,asana_gid}}, asana_project_gid, org_url, project, state_section}.")
    ap.add_argument("--pat-file", metavar="PATH", help="Read the ADO PAT from a chmod-600 file (else ADO_PAT env).")
    args = ap.parse_args()
    # Single-run lock — cron + session-start triggers must not race the state file.
    LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
    lock_f = open(LOCK_PATH, "w")
    try:
        fcntl.flock(lock_f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("another ado-asana-sync run is in progress — skipping")
        return
    try:
        sync(args)
    finally:
        fcntl.flock(lock_f, fcntl.LOCK_UN)
        lock_f.close()


if __name__ == "__main__":
    main()
