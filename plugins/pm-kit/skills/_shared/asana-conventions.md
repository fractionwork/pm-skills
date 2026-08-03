# Asana best practices

Standard structure for Asana projects created by the DevHawk bootstrap skill and maintained by the `asana-hygiene` skill.

## Required admins

Every project must have **at least 2 Admins**, so a project is never orphaned when someone
leaves. That is the rule; *who* those admins are is workspace configuration, not part of this
kit — they live under `requiredAdmins` in `~/.devhawk/pm/workspace.json` (see
`workspace.example.json` for the shape).

`asana-hygiene` reads that list and flags any project where a named admin is missing or is not
in the Admin role. With no list configured it reports the count only, rather than asserting
somebody else's team.

## Standard custom fields (8)

Every active project gets these 8 fields attached. All are workspace-level fields created once.

| Field | Type | Options |
|---|---|---|
| Fraction Priority | enum | P0 — Critical (red), P1 — High (orange), P2 — Medium (yellow), P3 — Low (cool-gray) |
| Fraction Task Type | enum | EPIC (purple — a *definition* card, never a parent; see "Task structure"), Story (blue), Bug (red), Chore (cool-gray), Tech Debt (orange), Discussion (aqua), Milestone (green), Spike (yellow) |
| Story Points | number | — |
| Release | enum | Phase 1 (blue), Phase 2 (green), Phase 3 (orange), Phase 4 (purple) — add more via `asana_ops.py --add-release-option` |
| Sprint | multi_enum | `Sprint M/D-M/D` per iteration — add via `asana_ops.py --add-sprint-option` |
| Task Progress | enum | Not Started, In Progress, Blocked, In Review, Done |
| Theme | text | The largest grouping a task belongs to (the project's theme/arc). **Free string**, per-project — themes differ between projects, so this is text rather than a shared workspace enum. One Theme per task. |
| Feature | text | The EPIC / feature this task supports. **Free string** (epics proliferate — no enum). The flat-model replacement for parent-EPIC nesting. |

## Standard workspace tags

Workspace-scoped tags (one set, shared across all projects). Currently one:

| Tag | Purpose | Setup |
|---|---|---|
| `devhawk:add-card` | Audit marker — every card created by the `add-card` skill carries this tag so skill-created vs manually-created cards are filterable in saved views. Paired with a `Created-By: devhawk-add-card@v<n>` line in the description for machine-readable audits. | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --ensure-audit-tag` (idempotent, prints tag gid). One-shot per workspace. |

The audit tag is **not** project-attached at the field-settings level — Asana tags are workspace-global and any task can carry any tag. The `--ensure-audit-tag` flag exists because the Asana MCP can attach existing tags but cannot create new ones; running this once per workspace lets the MCP path do all subsequent per-card stamping.

## Standard sections

Board-view projects use these columns in order:

| Section | Purpose |
|---|---|
| PM Onboarding Tasks | Setup, access, kickoff items |
| INBOX | Raw requirements not yet discussed with stakeholders. Some will graduate to BACKLOG; some will be rejected. |
| BACKLOG | Validated, unrefined, unassigned tasks — stakeholder buy-in confirmed but not yet ready to work. |
| TODO | Refined and ready to start (active sprint only) |
| WIP | Actively being worked on — **including a PR still in draft** |
| READY FOR REVIEW | PR created **and out of draft**, awaiting a reviewer |
| READY FOR TESTING | Code merged, needs QA |
| READY FOR RELEASE | Tested, awaiting deploy |
| DONE | Shipped |

Not all projects need all sections. At minimum: INBOX, BACKLOG, TODO, WIP, REVIEW, DONE.

**A draft PR keeps its card in WIP.** The distinction that matters is *who is
blocked* — a draft waits on the author, a ready PR waits on a reviewer. Parking
drafts in READY FOR REVIEW makes the column useless for anyone scanning for work
to pick up; one project accumulated six cards there behind draft PRs before it
was noticed. Move the card forward when the PR comes out of draft, not when it
is opened.

**Verify against the deployed branch, not the merged one.** READY FOR RELEASE
means the work is in the environment that section maps to — check that the merge
commit is actually on that branch (`git branch -r --contains <sha>`), not merely
that a PR says "Merged". A monorepo where `dev` auto-deploys and `main` is
production will happily show a PR as merged while the work is nowhere near the
customer.

### Flow stages: INBOX → BACKLOG → TODO

| Stage | What it is | What it isn't |
|---|---|---|
| **INBOX** | An idea, request, or observation captured before any stakeholder conversation. Source of truth: where it came from. | Committed work. Items here may never ship — that's the point. |
| **BACKLOG** | Validated work the team will eventually do. Stakeholders agree it's real. | Not yet committed to a sprint. Owner unassigned. |
| **TODO** | Pulled into the active sprint. Estimated, owned, ready to start. | Not yet WIP. |

### Promotion gate: INBOX → BACKLOG

Moving a task out of INBOX requires a **stakeholder discussion comment** on the card recording the conversation that validated it. Format:

```
Stakeholder discussion YYYY-MM-DD with @<person> — accepted as scoped. <one-line outcome>
```

This extends the Step 7 source-attribution rule into a workflow gate: hygiene flags any item that left INBOX without a discussion record. If stakeholders rejected the item, close it (don't move to BACKLOG); the discussion comment + closed status is the audit trail.

### Section-aware field requirements

Hygiene checks scale with stage. INBOX is intentionally light — demanding Story Points before the team has even discussed the idea is the wrong order of operations.

| Field | INBOX | BACKLOG | TODO+ |
|---|---|---|---|
| Title (not vague) | required | required | required |
| Description (1-2 sentences) | required | required | required |
| **Source attribution** | **required** | required | required |
| Fraction Priority | optional | required | required |
| Fraction Task Type | optional | required | required |
| Story Points | optional | required (auto-estimated) | required |
| Release | optional | required | required |
| Sprint | none | none | active sprint |
| Feature (epic) | optional | required (or "Feature pending") | required |
| Theme | optional | required | required |
| Owner | unassigned | unassigned | assigned |

### Stale INBOX

Items that sit in INBOX >30 days with no activity are flagged by hygiene as **stale** — promote, reject, or explicitly defer. INBOX that becomes a graveyard defeats the point.

## Project metadata

Every project should have:
- `start_on` — project start date
- `due_on` — target completion date
- `html_notes` — rich description including: product name, one-liner, stack, repo link, team members, client contact, key dates
- At least one status update posted at project start

## Release tracking

The Release enum field tags every task with its phase/release. This enables filtering and searching by release in Asana's board and list views.

- **Auto-populated by hygiene:** detects phase from task prefixes (SCRUM-* = Phase 1, PHAS-* = Phase 2) and from an EPIC definition card's own "(Phase N)" suffix. (The old "child inherits from parent epic" path is gone — there are no parent epics in the flat model. Set Release on the Feature's definition card; hygiene can propagate it to tasks sharing that Feature.)
- **Set during bootstrap:** new projects default to "Phase 1" for all initial tasks
- **New phases:** `create_new_phase` auto-creates a new enum option and tags tasks
- **Manual override:** builders can set Release directly on any task
- **Add options:** `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --add-release-option "Phase 5"`

Current enum options: Phase 1 (blue), Phase 2 (green), Phase 3 (orange), Phase 4 (purple). Add more as needed.

## Sprint tracking

The Sprint **multi_enum** field tags tasks with their time-boxed iteration. Multi-select means a task carrying over from one sprint to the next can hold both tags — useful for velocity reporting on continuing work.

- **Naming convention**: `Sprint M/D-M/D` (e.g. `Sprint 4/7-4/14`). Dates are unambiguous; year is omitted to match the existing convention. The Jira label "Sprint 0" / "Sprint 1" is dropped on migration since dates uniquely identify the sprint.
- **Open a new sprint**: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --add-sprint-option "Sprint 4/14-4/21"`
- **Closed sprints stay**: don't delete past options — historical filtering matters.
- **Active-sprint view**: saved Asana view filtered `Sprint = Sprint M/D-M/D`, board layout by Section.
- **Sprint vs Release**: Release is a phase/launch arc (months); Sprint is an iteration (1-2 weeks). Orthogonal — every task can have both.
- **TODO column = active sprint only**: items not in the active sprint live in BACKLOG. Hygiene can enforce this.

## Task structure

**Flat-task policy — every workflow task is top-level.** Asana cannot move a subtask between board sections: a subtask is frozen wherever its parent sits and can never flow INBOX → … → DONE. So subtasks MUST NOT represent workflow items. The EPIC hierarchy is carried by *data* (two custom fields), not *structure* (parent/child nesting):

- **Theme** (text) — the largest grouping this task belongs to (the project's theme/arc). Free string, per-project.
- **Feature** (text) — the EPIC / feature this task supports.

Taxonomy: **Theme ▸ Feature (EPIC) ▸ Task** — all flat, all freely movable between sections.

Rules:
- **No subtasks for workflow items.** Any subtask is a hygiene violation → elevate it to top-level (see "Subtask elevation"), copying the parent's Feature + Theme onto it.
- **EPIC cards are kept but are never parents.** An `EPIC`-typed card (`Fraction Task Type = EPIC`) is an optional top-level *definition* card that documents the feature (scope, acceptance criteria) and carries `Feature = <its own name>`. It groups with its tasks via the shared Feature value — it does not nest them.
- **Story Points aggregate by grouping on Feature**, not by subtask roll-up (there are no subtasks to roll up). Use an Asana report grouped by Feature, summing Story Points.
- Priority on all tasks (BACKLOG+); Release on all tasks; Theme + Feature on all tasks (BACKLOG+).
- Every task in a section (no orphans — invisible on board view).
- Owner assigned (not all tasks to the PM).

### Subtask elevation

Promoting a subtask to a top-level task is **non-destructive** — the task keeps its gid, comments, attachments, and field values. Two API calls, in this exact order:

1. **Add to project + section** (subtasks aren't project members; they're board-invisible until added):
   `POST /tasks/{gid}/addProject` → `{ "project": "<projectGid>", "section": "<sectionGid>" }`
2. **Detach from the parent** (else it lingers in a confusing dual state — both subtask and top-level):
   `POST /tasks/{gid}/setParent` → `{ "parent": null }`

Order is load-bearing: reverse it and the task briefly belongs to nothing. After both calls, set `Feature` (and `Theme`) from the former parent, then assert `parent == null`. Section routing: completed children → DONE; open children → the parent's section if it's an active flow section, else BACKLOG. Tooling: `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --elevate-subtasks <PROJECT_GID>` (idempotent; also fixes the dual state where step 1 ran but step 2 didn't).

## Portfolio organization

- **Active Client Engagements** — all active client projects
- **Fraction Internal** — internal tools, marketing, ops

Portfolios require Asana Advanced ($25/user/mo). If the workspace is on Starter, the bootstrap and hygiene scripts create **index projects** instead — regular projects named "📋 Active Client Engagements" / "📋 Fraction Internal" with notes listing links to each member project. Same organizational visibility, free on all plans.

## Tool precedence: first-party MCP → asana_ops.py → (never other Asana MCPs)

When more than one Asana surface is available, use them in this strict order:

1. **First-party `asana` MCP (`${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_mcp.py`)** — the preferred surface.
   Use it for everything it exposes (reads, `add_comment`, `assign_task`,
   `move_task_to_section`, `capture_inbox_idea`, `run_hygiene`). It is curated,
   project-scoped, and keeps the token in our own code.

   **Its state-changing tools require a `source` argument** —
   `move_task_to_section`, `assign_task` and `capture_inbox_idea` all refuse an
   empty one. This is Rule 1 (see `operating-rules.md`) moved out of prose and
   into code: the server posts the source to the card as a comment, so a status
   change carries its own audit trail even when no skill was loaded. Pass what
   actually prompted the change — `user request — asked to move to DONE`,
   `Fireflies transcript 2026-07-14 "Sprint review" — agreed to ship`. Writes
   past `ASANA_BULK_THRESHOLD` (default 5) additionally set Asana's
   `silent=true`, which is Rule 3 enforced the same way. `add_comment` takes no
   `source`: a comment *is* the audit trail.

   Tool names are namespaced by the plugin (`mcp__plugin_pm-kit_asana__<tool>`),
   so refer to them by bare name and resolve against whichever PM MCP is
   connected — these skills also run against Shortcut and Linear.
2. **`${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py`** — the privileged fallback, ONLY for operations the
   first-party MCP doesn't expose (see the structural list below) or when the MCP
   isn't connected. It self-authenticates (OAuth → refresh → `ASANA_PAT` /
   `ASANA_ACCESS_TOKEN`) and hits the REST API directly. Don't give up at an MCP
   gap — drop to the script.
3. **Any OTHER Asana MCP — do not use.** The official Asana plugin
   (`mcp.asana.com/sse`, OAuth-only) and community PAT servers are superseded by
   the first-party server. If the official plugin is enabled it registers under
   the same `asana` name and collides — **disable it** in projects that use the
   first-party server so there's no ambiguity about which tools run.

**Fallback rule (do not forget this):** never tell the user something can't be
done because the MCP lacked it — fall through to `asana_ops.py` first. The most
common failure mode is forgetting the script exists and giving up at an MCP gap.

The first-party MCP (and any Asana MCP) structurally **cannot** do these — go
straight to `asana_ops.py`:
- Archive projects (`PUT /projects/{gid}` with `archived: true`)
- Create custom fields (`POST /custom_fields`)
- Attach custom fields to projects (`POST /projects/{gid}/addCustomFieldSetting`)
- Create sections (`POST /sections`)
- Create portfolios (`POST /portfolios`)
- Add items to portfolios (`POST /portfolios/{gid}/addItem`)
- Upload a local file as an attachment (`POST /attachments`, multipart)

Separately, these are **deliberately omitted** from the curated MCP (for
guest-safety — the MCP exposes no raw create/destroy), so they also live in the
script even though an MCP *could* expose them:
- Create a rich task (`--create-task` — add-card's BACKLOG/INBOX creation with
  fields, section, sprint, audit tag). The MCP offers only `capture_inbox_idea`
  (light INBOX capture).
- Complete a task (`--complete-task` — card-done).
- Look up workspace users by name/email (`--find-user` — add-comment @mentions).
- Create a project (`--create-project` — asana-bootstrap; supports `--dry-run`
  as the preview/confirm step).

For everything else (search, read, comment, assign, section moves), try the MCP
first for ergonomics, then fall back to the script on any failure.

### asana_ops.py command surface

| Need | Command |
|---|---|
| One-time / refresh auth | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --auth` |
| Print a bearer token (for curl/other tools) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --token` |
| Full hygiene audit + fix | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --hygiene <PROJECT_GID>` |
| Auto-estimate story points | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --estimate <PROJECT_GID>` |
| Move a task to a section | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --move-section <TASK_GID> <SECTION_GID>` |
| Post a comment (HTML or `-` for stdin) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --post-comment <TASK_GID> '<body>…</body>'` |
| Create a rich task (add-card) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --create-task '{"name":…,"projects":[…],"section":"BACKLOG","custom_fields":{…},"sprint":[…],"audit_tag":true}'` |
| Complete a task (card-done) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --complete-task <TASK_GID>` |
| Find a user by name/email (mentions) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --find-user "<query>"` |
| Create a project (bootstrap; `--dry-run` to preview) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --create-project '{"name":…,"team":…,"notes":…,"default_view":"board"}'` |
| Attach a local file | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --attach-file <TASK_GID> <FILE_PATH>` |
| Elevate subtasks → top-level (flat-model fix) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --elevate-subtasks <PROJECT_GID>` |
| New phase (Feature group) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --new-phase <PROJECT_GID> "<PHASE_NAME>"` |
| Add Release enum option | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --add-release-option "Phase 5"` |
| Add Sprint enum option | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --add-sprint-option "Sprint 4/14-4/21"` |
| Ensure audit tag exists | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --ensure-audit-tag` |
| Cleanup tracks (A–E) | `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --track <A\|B\|C\|D\|E\|all> [--dry-run]` |

Most write paths accept `--dry-run`. For the underlying REST surface not exposed
as a flag, the script's `api(method, path, data=, params=)` helper (and the
`paginate()` wrapper) can issue any call — extend the script with a new flag
rather than reaching for raw `curl`.

## First-party Asana MCP server (`${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_mcp.py`)

A thin, **first-party** MCP server that gives teammates a native Asana tool
surface inside Claude, reusing `asana_ops.py` for auth + REST. Use it instead of
a community PAT MCP server when you don't want a third-party package holding a
user's token, and instead of the official OAuth-only plugin when a user must
authenticate with a **PAT** (guest / service / headless accounts).

**Why first-party:** the token only ever goes to Asana via your own code; you
control the exact tool set (no raw `create_task`/`delete`); and project access
is fenced server-side regardless of what the credential can otherwise see.

**Auth — OAuth *or* PAT, per user** (resolved by `asana_ops.get_token()`):
- *OAuth user:* `python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --auth` once, then point
  `ASANA_TOKEN_FILE` at the resulting token store (auto-refreshes).
- *PAT user:* set `ASANA_ACCESS_TOKEN` (or `ASANA_PAT`) in the MCP config.

**Env vars:**

| Var | Purpose |
|---|---|
| `ASANA_ACCESS_TOKEN` / `ASANA_PAT` | PAT credential (guest/service accounts) |
| `ASANA_TOKEN_FILE` | path to an OAuth token store (full users) |
| `ASANA_WORKSPACE` | pin the active workspace gid (multi-workspace accounts) |
| `ASANA_ALLOWED_PROJECTS` | comma-separated project GIDs; when set, every project/task tool is fenced to these (server-side) |
| `ASANA_READ_ONLY=1` | disable all write tools |

**Multi-workspace accounts — pick once.** A PAT (or OAuth login) carries *every*
workspace the account belongs to, so the server can't guess which one
`list_my_tasks` / `list_projects` / the audit tag should use. It resolves the
workspace by precedence: `ASANA_WORKSPACE` env → a saved choice → the sole
workspace if there's only one → otherwise it refuses to start and tells the user
to pick. Pick once (both the CLI and the MCP reuse it):

```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --list-workspaces      # see gid + name
python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --set-workspace <gid>  # save the choice
python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --pick-workspace       # or choose interactively
python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --list-projects        # projects in the active workspace (gid + name)
```

`--list-projects` exists so Claude can show projects **by name** and let the user
pick which to fence the MCP to (`ASANA_ALLOWED_PROJECTS`) — no hunting GIDs out of
Asana URLs. The MCP-setup flow is a single ask: *"Set up the Asana MCP with my
PAT — ask me which project."* Claude lists projects, the user picks a name, Claude
configures the fence.
Per-project tools (`get_task`, `assign_task`, `move_task_to_section`,
`add_comment`, `capture_inbox_idea`) key off the globally-unique project GID, so
`ASANA_ALLOWED_PROJECTS` already scopes them correctly regardless of workspace.

**Install:** `pip install -r scripts/requirements-mcp.txt`

**Config — guest, PAT, read-only, one project:**
```bash
claude mcp add asana \
  -e ASANA_ACCESS_TOKEN=<GUEST_PAT> \
  -e ASANA_ALLOWED_PROJECTS=<PROJECT_GID> \
  -e ASANA_READ_ONLY=1 \
  -- python3 /abs/path/scripts/asana_mcp.py
```

**Config — full user, OAuth, writes allowed:**
```bash
python3 ${CLAUDE_PLUGIN_ROOT}/skills/_shared/asana_ops.py --auth          # one-time browser login
claude mcp add asana \
  -e ASANA_TOKEN_FILE=$HOME/.config/asana-mcp/token.json \
  -- python3 /abs/path/scripts/asana_mcp.py
```

**Tool surface (curated):**
- *Reads:* `list_my_tasks`, `list_project_tasks`, `get_task`, `search_tasks`, `list_projects`, `get_task_comments`.
- *Curated writes:* `run_hygiene` (wraps the audit; `dry_run` default true), `add_comment` (plain text), `assign_task` (user gid / email / "me" / "" to unassign), `move_task_to_section` (by section name or gid, within the task's scoped project), `capture_inbox_idea` (top-level INBOX card carrying the `devhawk:add-card` tag + `Created-By: devhawk-asana-mcp@v1` footer — the flat-task discipline). Together these cover the guest workflow: **add** (`capture_inbox_idea`), **comment** (`add_comment`), **assign** (`assign_task`), **move** (`move_task_to_section`). Run guests in write mode (omit `ASANA_READ_ONLY`) fenced to their project via `ASANA_ALLOWED_PROJECTS`.
- Deliberately **excluded:** raw `create_task`, `delete_task`, field/section/workspace mutations. Richer BACKLOG creation still goes through the `add-card` skill.
