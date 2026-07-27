# Shortcut best practices

Standard structure for Shortcut projects created by the DevHawk bootstrap skill and maintained by the `shortcut-hygiene` skill.

## Standard custom fields

Create these workspace-level custom fields once. Shortcut's built-in `story_type` and `estimate` cover Task Type and Story Points — no custom field needed for those.

| Field | Type | Values |
|---|---|---|
| Priority | enum | P0 — Critical, P1 — High, P2 — Medium, P3 — Low |

## Built-in fields (no custom field needed)

| Concept | Shortcut built-in | Notes |
|---|---|---|
| Task Type | `story_type` | `feature`, `bug`, `chore` |
| Story Points | `estimate` | Fibonacci: 1, 2, 3, 5, 8, 13 |
| Status/Progress | Workflow State | Board columns |
| Release | Iteration | Sprint/cycle grouping |

## Standard workflow states

Shortcut workflow states are workspace-level (shared across projects). Modeled after the Asana INBOX → DONE flow (see `${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana-conventions.md`):

| State | Type | Maps to |
|---|---|---|
| Inbox | `unstarted` | INBOX — raw requirements not yet discussed with stakeholders. Some will graduate to Unscheduled; some will be rejected. |
| Unscheduled | `unstarted` | BACKLOG — validated, unrefined, unassigned. Stakeholder buy-in confirmed but not yet ready to work. |
| Ready for Development | `unstarted` | TODO — refined and ready to start (active iteration only) |
| In Development | `started` | WIP |
| Ready for Review | `started` | Review |
| Ready for Deploy | `started` | Ready for Release |
| Completed | `done` | Done |

If the workspace doesn't have an "Inbox" state, add it as the first `unstarted` state — that's the structural prerequisite for the pre-backlog flow. If the workspace uses different names elsewhere, skills map by state type (`unstarted`, `started`, `done`) rather than exact name.

### Flow stages: Inbox → Unscheduled → Ready for Development

| Stage | What it is | What it isn't |
|---|---|---|
| **Inbox** | An idea, request, or observation captured before any stakeholder conversation. Source of truth: where it came from. | Committed work. Items here may never ship — that's the point. |
| **Unscheduled** | Validated work the team will eventually do. Stakeholders agree it's real. | Not yet committed to an iteration. Owner unassigned. |
| **Ready for Development** | Pulled into the active iteration. Estimated, owned, ready to start. | Not yet WIP. |

### Promotion gate: Inbox → Unscheduled

Moving a story out of Inbox requires a **stakeholder discussion comment** on the story recording the conversation that validated it. Format:

```
Stakeholder discussion YYYY-MM-DD with @<person> — accepted as scoped. <one-line outcome>
```

Hygiene flags any story that left Inbox without a discussion record. If stakeholders rejected the item, archive/close it (don't move to Unscheduled); the discussion comment + closed status is the audit trail.

### Per-state field requirements

Hygiene checks scale with stage. Inbox is intentionally light — demanding an estimate before the team has discussed the idea is the wrong order of operations.

| Field | Inbox | Unscheduled | Ready for Dev+ |
|---|---|---|---|
| Title (not vague) | required | required | required |
| Description (1-2 sentences) | required | required | required |
| **Source attribution** | **required** | required | required |
| Priority custom field | optional | required | required |
| `story_type` (feature/bug/chore) | optional | required | required |
| `estimate` | optional | required (auto-estimated) | required |
| Release (label / custom field) | optional | required | required |
| Iteration | none | none | active iteration |
| Epic (`epic_id`) | optional | required (or "epic pending") | required |
| Owner (`owner_ids`) | unassigned | unassigned | assigned |

### Stale Inbox

Stories that sit in Inbox >30 days with no activity are flagged by hygiene as **stale** — promote, reject, or explicitly defer. Inbox-as-graveyard defeats the point.

## Story structure

- **Epics** group related stories across projects
- **Stories** are the work unit — use `story_type`: `feature`, `bug`, or `chore`
- **Tasks** are sub-items of stories (checklist items, acceptance criteria)
- **Iterations** group stories into sprints/releases
- Every story should have: owner, estimate, Priority custom field, workflow state

## Project organization

- One Shortcut Project per product/engagement
- Epics span stories within the project
- Iterations for time-boxed releases
- Labels for cross-cutting concerns (not for priority — use the custom field)

## Key differences from Asana

- No per-project roles — workspace owners manage everything (no orphaned-admin problem)
- Workflow states are workspace-level, not per-project sections
- `story_type` is built-in (feature/bug/chore) — no custom "Task Type" field
- `estimate` is built-in — no custom "Story Points" field
- API auth is a simple token — no OAuth needed
- Rate limit: 200 req/min (vs Asana's 150)
- No portfolios — Projects serve that role

## MCP capabilities

The `shortcut-mcp` server (`pip install shortcut-mcp`) supports:
- View/create/search stories, epics, objectives
- Filter by workflow state, owner, dates
- Advanced query syntax

Operations that may need direct REST API (`${CLAUDE_PLUGIN_ROOT}/skills/_shared/shortcut_ops.py`):
- Custom field creation
- Bulk story updates
- Workspace-level configuration
- Archive operations

## Auth

```bash
# Generate token: Shortcut → Settings → API Tokens
export SHORTCUT_API_TOKEN="..."
```

Header: `Shortcut-Token: <token>`
Base URL: `https://api.app.shortcut.com/api/v3`
