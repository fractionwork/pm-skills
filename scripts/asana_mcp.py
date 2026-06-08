#!/usr/bin/env python3
"""First-party Asana MCP server (stdio).

A thin, curated MCP surface over Asana that reuses scripts/asana_ops.py for
auth and REST. Built so guests/teammates get a native MCP experience with a
credential YOU control — the token only ever goes to Asana, never to
third-party code.

WHY THIS EXISTS (vs. a community PAT MCP server):
  - The official Asana plugin (mcp.asana.com/sse) is OAuth-only — no PAT.
  - Community PAT servers run third-party npm code holding the user's token.
  - This server: PAT *or* OAuth, your code, a curated tool set, and
    server-side project scoping so a credential that can see more is still
    fenced to the project(s) you allow.

AUTH (dual mode — decided per user by what's present, via asana_ops.get_token):
  - OAuth user:  run `python3 scripts/asana_ops.py --auth` once (writes a
                 token file); point ASANA_TOKEN_FILE at it. Auto-refreshes.
  - PAT user:    set ASANA_ACCESS_TOKEN (or ASANA_PAT) in the MCP config.

ENV:
  ASANA_ACCESS_TOKEN / ASANA_PAT   PAT (guest/service accounts)
  ASANA_TOKEN_FILE                 path to an OAuth token store (full users)
  ASANA_WORKSPACE                  pin the active workspace (gid). Multi-workspace
                                   accounts otherwise pick once via
                                   `asana_ops.py --pick-workspace/--set-workspace`
                                   (saved to ASANA_WORKSPACE_FILE). Without any of
                                   these the server refuses to start rather than
                                   guess the first workspace.
  ASANA_ALLOWED_PROJECTS           comma-separated project GIDs; when set,
                                   every project/task tool is fenced to these
  ASANA_READ_ONLY=1                disable all write tools

INSTALL: pip install -r scripts/requirements-mcp.txt
CONFIG examples are in docs/asana-best-practices.md → "First-party Asana MCP server".
"""
import contextlib
import io
import os
import sys
from datetime import datetime, timezone

# Reuse asana_ops for auth + REST. Add the script dir to the path so this works
# regardless of the server's working directory.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asana_ops as ops  # noqa: E402

from mcp.server.fastmcp import FastMCP  # noqa: E402

# asana_ops.log() prints every API call to stdout AND a log file. In an stdio
# MCP server stdout is the JSON-RPC channel, so silence it — protocol integrity
# over call tracing.
ops.log = lambda *a, **k: None

mcp = FastMCP("asana")

# Accept common truthy spellings (1/true/yes/on) so a Docker/k8s-style
# ASANA_READ_ONLY=true doesn't silently leave writes enabled.
READ_ONLY = os.environ.get("ASANA_READ_ONLY", "").strip().lower() in ("1", "true", "yes", "on")
ALLOWED = {g.strip() for g in os.environ.get("ASANA_ALLOWED_PROJECTS", "").split(",") if g.strip()}

TASK_FIELDS = ("name,notes,completed,assignee.name,permalink_url,"
               "memberships.section.name,memberships.project.gid,"
               "custom_fields.name,custom_fields.display_value")


# ── guards ───────────────────────────────────────────────────────────────
def _scope(project_gid: str) -> None:
    if ALLOWED and project_gid not in ALLOWED:
        raise ValueError(
            f"project {project_gid} is outside this server's allowed scope "
            f"(ASANA_ALLOWED_PROJECTS)")


def _writable() -> None:
    if READ_ONLY:
        raise ValueError("server is read-only (ASANA_READ_ONLY=1)")


def _task_projects(task_gid: str):
    """Return (task_data, set_of_project_gids) for a task."""
    with contextlib.redirect_stdout(sys.stderr):
        data = ops.api("GET", f"/tasks/{task_gid}",
                       params={"opt_fields": TASK_FIELDS})
    if not data:
        raise ValueError(f"task {task_gid} not found or not accessible")
    t = data["data"]
    pgids = {m.get("project", {}).get("gid") for m in t.get("memberships", [])
             if m.get("project")}
    return t, pgids


def _assert_task_in_scope(task_gid: str):
    t, pgids = _task_projects(task_gid)
    if ALLOWED and not (pgids & ALLOWED):
        raise ValueError(f"task {task_gid} is outside this server's allowed scope")
    return t


def _utc_minute() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%MZ")


# ── read tools ─────────────────────────────────────────────────────────────
@mcp.tool()
def list_my_tasks():
    """List the authenticated user's incomplete assigned tasks. When
    ASANA_ALLOWED_PROJECTS is set, results are fenced to those projects (a
    workspace-wide assignee query would otherwise leak task names from projects
    outside the allowed scope)."""
    with contextlib.redirect_stdout(sys.stderr):
        ws = ops.resolve_workspace()
        tasks = ops.paginate(
            "/tasks",
            params={"assignee": "me", "workspace": ws, "completed_since": "now"},
            opt_fields="name,permalink_url,memberships.section.name,memberships.project.gid")
    if ALLOWED:
        tasks = [t for t in tasks
                 if {m.get("project", {}).get("gid") for m in t.get("memberships", [])} & ALLOWED]
    return tasks


@mcp.tool()
def list_project_tasks(project_gid: str):
    """List incomplete tasks in a project (name, section, assignee, fields)."""
    _scope(project_gid)
    with contextlib.redirect_stdout(sys.stderr):
        return ops.paginate(f"/projects/{project_gid}/tasks", opt_fields=TASK_FIELDS)


@mcp.tool()
def get_task(task_gid: str):
    """Full detail for one task (scoped)."""
    return _assert_task_in_scope(task_gid)


@mcp.tool()
def search_tasks(project_gid: str, text: str):
    """Case-insensitive substring search over task names in a project (scoped)."""
    _scope(project_gid)
    q = text.lower()
    with contextlib.redirect_stdout(sys.stderr):
        tasks = ops.paginate(f"/projects/{project_gid}/tasks", opt_fields=TASK_FIELDS)
    return [t for t in tasks if q in (t.get("name") or "").lower()]


@mcp.tool()
def list_projects():
    """List projects this server can act on. When ASANA_ALLOWED_PROJECTS is set,
    only those; otherwise all non-archived projects in the workspace."""
    with contextlib.redirect_stdout(sys.stderr):
        if ALLOWED:
            out = []
            for g in sorted(ALLOWED):
                r = ops.api("GET", f"/projects/{g}", params={"opt_fields": "name,archived"})
                if r:
                    out.append(r["data"])
            return out
        ws = ops.resolve_workspace()
        return [p for p in ops.paginate(f"/workspaces/{ws}/projects",
                                        opt_fields="name,archived")
                if not p.get("archived")]


@mcp.tool()
def get_task_comments(task_gid: str):
    """List the comment stories on a task (scoped)."""
    _assert_task_in_scope(task_gid)
    with contextlib.redirect_stdout(sys.stderr):
        stories = ops.paginate(f"/tasks/{task_gid}/stories",
                               opt_fields="text,created_at,created_by.name,type")
    return [s for s in stories if s.get("type") == "comment"]


# ── curated write tools ────────────────────────────────────────────────────
@mcp.tool()
def run_hygiene(project_gid: str, dry_run: bool = True):
    """Run the DevHawk Asana hygiene audit/fix on a project and return the report.
    dry_run=True previews only; dry_run=False applies fixes (needs write mode)."""
    _scope(project_gid)
    if not dry_run:
        _writable()
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        ops.hygiene_audit(project_gid, dry_run=dry_run)
    return buf.getvalue()


@mcp.tool()
def add_comment(task_gid: str, body: str):
    """Add a plain-text comment to a task (scoped). Plain text avoids Asana's
    HTML allowlist 400s; use the add-comment skill for rich formatting."""
    _writable()
    _assert_task_in_scope(task_gid)
    with contextlib.redirect_stdout(sys.stderr):
        r = ops.api("POST", f"/tasks/{task_gid}/stories", {"text": body})
    return "ok" if r else "failed"


@mcp.tool()
def move_task_to_section(task_gid: str, section: str):
    """Move a task to a board section (scoped). `section` may be a section name
    (e.g. "WIP", "DONE" — matched case-insensitively within the task's project)
    or a numeric section GID. Returns the destination section."""
    _writable()
    t = _assert_task_in_scope(task_gid)
    # Pick the project to resolve sections in: an allowed one the task belongs to
    # (when fenced), else its first project membership.
    pgids = [m.get("project", {}).get("gid") for m in t.get("memberships", [])
             if m.get("project")]
    proj = next((g for g in pgids if not ALLOWED or g in ALLOWED), None)
    if not proj:
        raise ValueError(f"task {task_gid} has no project in scope")
    with contextlib.redirect_stdout(sys.stderr):
        if section.isdigit():
            sec_gid, sec_name = section, section
        else:
            secs = ops.paginate(f"/projects/{proj}/sections", opt_fields="name")
            match = next((s for s in secs
                          if (s.get("name") or "").strip().lower() == section.strip().lower()), None)
            if not match:
                names = ", ".join((s.get("name") or "?") for s in secs)
                raise ValueError(f"section {section!r} not found in project {proj}. Available: {names}")
            sec_gid, sec_name = match["gid"], match["name"]
        r = ops.api("POST", f"/sections/{sec_gid}/addTask", {"task": task_gid})
    return {"ok": bool(r), "task_gid": task_gid, "section": sec_name}


@mcp.tool()
def assign_task(task_gid: str, assignee: str):
    """Assign a task (scoped). `assignee` may be a user GID, an email address, or
    "me"; pass an empty string to unassign. The credential can only assign to
    users it can see in the workspace."""
    _writable()
    _assert_task_in_scope(task_gid)
    val = assignee.strip() or None  # "" → null → unassign
    with contextlib.redirect_stdout(sys.stderr):
        r = ops.api("PUT", f"/tasks/{task_gid}", {"assignee": val})
    return {"ok": bool(r), "task_gid": task_gid, "assignee": val or "(unassigned)"}


@mcp.tool()
def capture_inbox_idea(project_gid: str, title: str, description: str,
                       source: str):
    """Capture an unvalidated idea as a top-level INBOX card with the DevHawk
    add-card discipline: Source line + machine-parseable footer + the
    `devhawk:add-card` workspace tag. Flat-task only (never a subtask). Richer
    BACKLOG creation (full field set) should go through the add-card skill."""
    _writable()
    _scope(project_gid)
    notes = (f"{description.strip()}\n\nSource: {source.strip()}\n\n"
             f"---\nCreated-By: devhawk-asana-mcp@v1 · {_utc_minute()}")
    with contextlib.redirect_stdout(sys.stderr):
        created = ops.api("POST", "/tasks",
                          {"name": title, "notes": notes, "projects": [project_gid]})
        if not created:
            return {"ok": False, "error": "create failed"}
        gid = created["data"]["gid"]
        # The card now exists; section placement + audit tag are best-effort so a
        # later step's failure never loses the card or kills the tool. Report what
        # didn't apply rather than raising after a successful create.
        warnings = []
        try:
            secs = ops.paginate(f"/projects/{project_gid}/sections", opt_fields="name")
            inbox = next((s["gid"] for s in secs if (s.get("name") or "").upper() == "INBOX"), None)
            if inbox:
                ops.api("POST", f"/sections/{inbox}/addTask", {"task": gid})
            else:
                warnings.append("no INBOX section — left in default section")
        except Exception as e:  # noqa: BLE001 — best-effort, surfaced in result
            warnings.append(f"section placement skipped: {e}")
        try:
            tag = ops.ensure_audit_tag()  # Marker A (idempotent; creates if missing)
            if tag:
                ops.api("POST", f"/tasks/{gid}/addTag", {"tag": tag})
            else:
                warnings.append("audit tag unavailable — footer marker still present")
        except Exception as e:  # noqa: BLE001
            warnings.append(f"audit tag skipped: {e}")
    return {"ok": True, "task_gid": gid,
            "permalink": f"https://app.asana.com/0/{project_gid}/{gid}",
            "warnings": warnings}


def main():
    # A stdio MCP server MUST start serving promptly: Claude Code blocks its own
    # startup until the server completes the MCP handshake. So do NOT make network
    # calls here — get_token() can trigger an OAuth refresh and resolve_workspace()
    # hits the API, and a stalled request (corporate proxy, captive portal, slow
    # DNS) would hang Claude's startup rather than fail fast. Validate only what is
    # cheap and LOCAL; real auth/workspace errors surface on the first tool call
    # (and ops.* now carries HTTP timeouts so even those can't block forever).
    has_cred = (
        ops.TOKEN_FILE.exists()
        or os.environ.get("ASANA_PAT")
        or os.environ.get("ASANA_ACCESS_TOKEN")
    )
    if not has_cred:
        print("asana-mcp: no Asana credential found — run `asana_ops.py --auth` "
              "for OAuth, or set ASANA_PAT / ASANA_ACCESS_TOKEN", file=sys.stderr)
        sys.exit(1)
    mode = "read-only" if READ_ONLY else "read-write"
    scope = f"{len(ALLOWED)} project(s)" if ALLOWED else "workspace-wide"
    print(f"asana-mcp: starting ({mode}, scope={scope})", file=sys.stderr)
    mcp.run()


if __name__ == "__main__":
    main()
