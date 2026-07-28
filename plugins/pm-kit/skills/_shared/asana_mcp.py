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

# The SDK renamed its high-level server class in 2.0: mcp.server.fastmcp.FastMCP
# became mcp.server.MCPServer, and the old module was removed rather than
# deprecated — so a machine that upgraded got ModuleNotFoundError at import, and
# because a server that dies during the handshake registers nothing, the only
# symptom was the Asana tools silently not existing.
#
# Both classes cover the surface used here: a name in the constructor, a bare
# @tool() decorator, and run() defaulting to stdio. Supporting both means a venv
# does not have to move in lockstep with the plugin. The two names are disjoint
# across majors, so this cannot pick the wrong one.
try:
    from mcp.server import MCPServer as _McpServer  # noqa: E402  (mcp >= 2.0)
except ImportError:
    from mcp.server.fastmcp import FastMCP as _McpServer  # noqa: E402  (mcp 1.x)

# asana_ops.log() prints every API call to stdout AND a log file. In an stdio
# MCP server stdout is the JSON-RPC channel, so silence it — protocol integrity
# over call tracing.
ops.log = lambda *a, **k: None

mcp = _McpServer("asana")

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


# ── operating-rule enforcement ─────────────────────────────────────────────
# Rules 1 and 3 (see _shared/operating-rules.md) used to live only as prose in
# the user's CLAUDE.md. Prose is advisory: a direct tool call made with no skill
# loaded never saw it, which is exactly the path that produced an unauditable
# batch of card edits. These two guards move the rules into code, so they hold
# regardless of what the caller has read.

# Rule 3: how many writes in one server lifetime constitute a "bulk operation".
# 5 matches the documented threshold — at or below it the skill offers the user
# the choice; above it we mute by default and say so.
BULK_THRESHOLD = int(os.environ.get("ASANA_BULK_THRESHOLD", "5"))
_write_count = 0


def _require_source(source: str, action: str) -> str:
    """Rule 1 — every write records why it happened.

    Returns the normalized source line. Raising here rather than defaulting is
    deliberate: a silent default would produce attribution that looks real and
    isn't, which is worse than no attribution at all.
    """
    s = (source or "").strip()
    if not s:
        raise ValueError(
            f"{action} requires a `source` — what prompted this change. "
            "Use one of: 'Fireflies transcript YYYY-MM-DD \"<meeting>\" — <quote>', "
            "'Outlook email YYYY-MM-DD from <sender> — subject \"<subject>\"', "
            "'Slack #<channel> YYYY-MM-DD — thread by @<author> re: <topic>', "
            "'codebase — <path>:<line>', or 'user request — <what was asked>'. "
            "See operating-rules.md Rule 1.")
    return s if s.lower().startswith("source:") else f"Source: {s}"


def _bulk_silent() -> bool:
    """Rule 3 — mute notifications once a run crosses the bulk threshold.

    Counts writes for the life of this server process. The first few writes
    notify normally (a real assignment should reach someone); past the
    threshold we are plainly in a batch and each additional notification is
    just another simultaneous email.
    """
    global _write_count
    _write_count += 1
    return _write_count > BULK_THRESHOLD


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


def _record_attribution(task_gid: str, note: str) -> bool:
    """Post the Rule-1 audit comment for a state change. Best-effort.

    Never raises: the state change has already happened by the time this runs,
    so failing here must surface as a partial result rather than an exception
    that makes the caller think the whole operation failed and retry it.
    """
    try:
        with contextlib.redirect_stdout(sys.stderr):
            return bool(ops.api("POST", f"/tasks/{task_gid}/stories", {"text": note}))
    except Exception as e:  # noqa: BLE001 — deliberately broad, see docstring
        print(f"asana-mcp: attribution comment failed for {task_gid}: {e}",
              file=sys.stderr)
        return False


@mcp.tool()
def add_comment(task_gid: str, body: str):
    """Add a plain-text comment to a task (scoped). Plain text avoids Asana's
    HTML allowlist 400s; use the add-comment skill for rich formatting.

    Takes no `source`: a comment IS the audit trail Rule 1 asks for, so
    requiring attribution to leave attribution would just be circular."""
    _writable()
    _assert_task_in_scope(task_gid)
    params = {"silent": "true"} if _bulk_silent() else None
    with contextlib.redirect_stdout(sys.stderr):
        r = ops.api("POST", f"/tasks/{task_gid}/stories", {"text": body},
                    params=params)
    return "ok" if r else "failed"


@mcp.tool()
def move_task_to_section(task_gid: str, section: str, source: str):
    """Move a task to a board section (scoped). `section` may be a section name
    (e.g. "WIP", "DONE" — matched case-insensitively within the task's project)
    or a numeric section GID. Returns the destination section.

    `source` is required (operating-rules Rule 1) — say what prompted the move,
    e.g. 'Fireflies transcript 2026-07-14 "Sprint review" — agreed to ship' or
    'user request — asked to move to DONE'. It is posted to the card as a
    comment, so the status change carries its own audit trail."""
    _writable()
    source = _require_source(source, "move_task_to_section")
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
        silent = {"silent": "true"} if _bulk_silent() else None
        r = ops.api("POST", f"/sections/{sec_gid}/addTask", {"task": task_gid},
                    params=silent)
    attributed = _record_attribution(
        task_gid, f"Moved to {sec_name}.\n{source}") if r else False
    return {"ok": bool(r), "task_gid": task_gid, "section": sec_name,
            "attributed": attributed, "notifications_muted": bool(silent)}


@mcp.tool()
def assign_task(task_gid: str, assignee: str, source: str):
    """Assign a task (scoped). `assignee` may be a user GID, an email address, or
    "me"; pass an empty string to unassign. The credential can only assign to
    users it can see in the workspace.

    `source` is required (operating-rules Rule 1) — say what prompted the
    assignment. It is posted to the card as a comment."""
    _writable()
    source = _require_source(source, "assign_task")
    _assert_task_in_scope(task_gid)
    val = assignee.strip() or None  # "" → null → unassign
    with contextlib.redirect_stdout(sys.stderr):
        silent = {"silent": "true"} if _bulk_silent() else None
        r = ops.api("PUT", f"/tasks/{task_gid}", {"assignee": val}, params=silent)
    who = val or "(unassigned)"
    attributed = _record_attribution(
        task_gid, f"Assignee set to {who}.\n{source}") if r else False
    return {"ok": bool(r), "task_gid": task_gid, "assignee": who,
            "attributed": attributed, "notifications_muted": bool(silent)}


@mcp.tool()
def complete_task(task_gid: str, source: str):
    """Mark a task complete (scoped).

    `source` is required (operating-rules Rule 1) — say what closed it, e.g.
    'PR #123 merged'. It is posted to the card as a comment.

    This used to be omitted from the MCP on purpose, to keep the surface small:
    `card-done` reached for `asana_ops.py --complete-task` instead. That worked
    while both shipped in one install. As separate plugins it does not — a
    sibling plugin's files are unreachable, because ${CLAUDE_PLUGIN_ROOT} is
    content-hash addressed per plugin. Completion is a legitimate board
    operation with a legitimate caller, so it belongs on the tool surface."""
    _writable()
    source = _require_source(source, "complete_task")
    _assert_task_in_scope(task_gid)
    with contextlib.redirect_stdout(sys.stderr):
        silent = {"silent": "true"} if _bulk_silent() else None
        r = ops.api("PUT", f"/tasks/{task_gid}", {"completed": True}, params=silent)
    attributed = _record_attribution(task_gid, f"Completed.\n{source}") if r else False
    return {"ok": bool(r), "task_gid": task_gid, "completed": bool(r),
            "attributed": attributed, "notifications_muted": bool(silent)}


@mcp.tool()
def capture_inbox_idea(project_gid: str, title: str, description: str,
                       source: str):
    """Capture an unvalidated idea as a top-level INBOX card with the DevHawk
    add-card discipline: Source line + machine-parseable footer + the
    `devhawk:add-card` workspace tag. Flat-task only (never a subtask). Richer
    BACKLOG creation (full field set) should go through the add-card skill.

    `source` is required and validated (operating-rules Rule 1) — an empty one
    used to produce a card whose Source line read "Source:" and nothing else."""
    _writable()
    source = _require_source(source, "capture_inbox_idea")
    _scope(project_gid)
    notes = (f"{description.strip()}\n\n{source}\n\n"
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
