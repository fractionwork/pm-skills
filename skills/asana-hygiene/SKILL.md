---
name: asana-hygiene
description: >
  Audit and fix an Asana project against Fraction best practices — missing
  custom fields (incl. Theme + Feature), subtasks that need elevating to
  top-level (flat-task model), orphaned tasks, missing admins,
  unestimated/vague/empty cards, non-standard sections, stale INBOX. Auto-fixes
  what it can and reports the rest; can enrich the backlog from
  transcripts/emails/chat. Triggers on "clean up asana", "audit project", "fix
  asana board", "standardize project", "asana hygiene", "enrich backlog".
seed_managed: true
requires_tools: [python3]
requires_files: [scripts/asana_ops.py]
requires_mcp: [asana]
---

# Asana Hygiene

Audit and fix an Asana project against `docs/asana-best-practices.md`.

Uses `scripts/asana_ops.py` for all operations. The script handles auth (auto-runs OAuth if needed) and provides reusable commands.

> **Tool precedence:** prefer the **first-party `asana` MCP** (`scripts/asana_mcp.py`); fall back to **`scripts/asana_ops.py`** for anything it lacks or when disconnected (it covers everything the MCP can't — create fields/sections/portfolios/tags, archive, upload files via `--attach-file`); do **not** use other Asana MCPs (official plugin / community servers are superseded). Full precedence + command surface in `docs/asana-best-practices.md` → "Tool precedence".

## Step 1: Pick the project

Use Asana MCP to list projects, or ask the builder for the project GID/name.

## Step 2: Run the audit + fix

```bash
python3 scripts/asana_ops.py --hygiene <PROJECT_GID>
```

This runs the full audit and auto-fixes:
- **Admins:** adds Jeremy + Alyssia if missing
- **Custom fields:** attaches 8 standard fields (Priority, Task Type, Story Points, Task Progress, Release, Sprint, Theme, Feature)
- **Sections:** creates missing standard sections (INBOX → DONE)
- **Metadata:** reports missing start_on, due_on, notes (needs manual input)
- **Priority / Task Type / Story Points / Release:** auto-fill **only for non-INBOX items** — INBOX is intentionally light (these get filled at the INBOX → BACKLOG promotion conversation, not before). Audit output labels these as "(excl. INBOX)" so the funnel stays honest.
- **INBOX summary:** counts items awaiting stakeholder discussion
- **Stale INBOX:** flags items unmoved for >30 days (`INBOX_STALE_DAYS` in `scripts/asana_ops.py`)
- **No assignee (TODO+ only):** doesn't flag BACKLOG/INBOX — those are intentionally unassigned
- **Orphaned tasks:** reports tasks with no section
- **Vague titles:** reports "fix/update/misc" titles for manual cleanup (applies to all sections, including INBOX)
- **Empty descriptions:** reports tasks with no description (applies to all sections — INBOX still requires a 1-2 sentence description + Source line)
- **Missing Feature (excl. INBOX):** non-EPIC tasks with no `Feature` value. `Feature` is free-text and **per-project**, so hygiene **auto-fills only when the project already uses exactly one Feature** (unambiguous → blanks inherit it); with zero or multiple epics in play it reports for triage (the value is a judgement call). INBOX exempt — Feature is set at the INBOX → BACKLOG promotion.
- **Missing Theme (excl. INBOX):** non-EPIC tasks with no `Theme` value. `Theme` is free-text and **per-project** (no shared enum), so hygiene **auto-fills only when the project already uses exactly one Theme** (unambiguous → blanks inherit it); with zero or multiple themes in play it reports for triage (the value is a judgement call). INBOX exempt.
- **Subtasks present (flat-model violation):** reports any task that still has a parent, or still owns subtasks. Asana can't move a subtask between board sections, so these are stuck. Fix with `python3 scripts/asana_ops.py --elevate-subtasks <PROJECT_GID>` (non-destructive — see `docs/asana-best-practices.md` → "Subtask elevation"). Also catches the dual state (member of a project *and* still parented).
- **Non-standard sections:** reports any sections beyond the 8 standards (INBOX → DONE)

## Step 3: Manual follow-up

The script reports items it can't auto-fix:

### Metadata
If start_on, due_on, or notes are missing, ask the builder:
- "What's the project start date?"
- "What's the target completion date?"
- "Give me a one-liner for the project description."

Then set via: `python3 scripts/asana_ops.py` REST calls or MCP.

### Vague titles
Show the list of vague titles. Ask: "Should I rename these to be more actionable?" Propose clearer titles based on the description.

### Empty descriptions
Show tasks with no description. Ask the builder to provide context, or read the codebase / meeting transcripts / documents to derive descriptions.

### Unassigned tasks
Don't auto-assign — report the count and ask who should own them.

## Step 4: Auto-estimate story points

If stories lack estimates, run:
```bash
python3 scripts/asana_ops.py --estimate <PROJECT_GID>
```

Estimates based on description complexity: 1 (trivial) → 2 (small) → 3 (medium) → 5 (large) → 8 (complex). Signals: word count, keywords (integrate/architecture/pipeline = complex, fix/rename/cleanup = simple).

These are rough estimates for sorting — the builder should refine during sprint planning.

## Step 5: Section moves

To move a task to a section:
```bash
python3 scripts/asana_ops.py --move-section <TASK_GID> <SECTION_GID>
```

### Bulk operations: mute notifications

When moving / completing / re-assigning **more than 5 cards in one action**, suppress assignee+follower notifications. A bulk transition is one bookkeeping decision; firing N emails for it is just noise. Asana supports `?silent=true` as a query parameter on the writes that fire notifications:

- `POST /sections/{section_gid}/addTask?silent=true` — section moves
- `PUT /tasks/{task_gid}?silent=true` — completion changes, assignee changes, custom-field changes
- `POST /tasks?silent=true` — task creation that auto-notifies via assignee/parent

In `scripts/asana_ops.py`, pass via the existing `params=` arg:
```python
api('POST', f'/sections/{dest}/addTask', {'task': gid}, params={'silent': 'true'})
api('PUT',  f'/tasks/{gid}',             {'completed': True}, params={'silent': 'true'})
```

**Singular operations** (one card moves, one assignment, one comment from a real conversation) keep notifications on — that signal is usually wanted. The threshold is "did the user issue this as one batch decision, or as N individual decisions" — bulk = mute, individual = loud.

When you mute, **say so in the response** so the user can adjust if they wanted the noise. Some Asana notification paths (mentions in comments, due-date side effects on dependencies) ignore `silent` and may still fire — flag that as an honest limitation rather than promising total silence.

### INBOX → BACKLOG → TODO

The flow has three pre-WIP stages, each with a different bar:

- **INBOX** — raw requirements not yet discussed with stakeholders. Title + description + Source line are required; Priority / Type / Points / Release are deliberately deferred. The `add-card` skill routes "PM mentioned", "we might want to", "haven't discussed yet"-style requests here.
- **BACKLOG** — stakeholder buy-in confirmed. Standard custom fields populated (incl. Theme + Feature). Owner unassigned.
- **TODO** — pulled into the active sprint. Estimated, owned, ready to start.

**Promotion gate**: moving a task out of INBOX requires a stakeholder discussion comment on the card recording the conversation that validated it. Format: `Stakeholder discussion YYYY-MM-DD with @<person> — accepted as scoped. <one-line outcome>`. This extends the Step 7 source-attribution rule into a workflow gate. If stakeholders rejected the item, close it (don't move to BACKLOG); the discussion comment + closed status is the audit trail.

**Stale INBOX**: items unmoved for >30 days are flagged. Promote, reject, or explicitly defer — INBOX-as-graveyard defeats the point.

### BACKLOG → TODO refinement criteria

A task moves from BACKLOG to TODO when it has:
- A clear description with actionable details
- An estimate (Story Points)
- Acceptance criteria (for stories)
- An owner or is ready to be picked up

External-source enrichment (meetings/emails/chat) lands in BACKLOG by default — see Step 7c for the placement rules.

## Step 5b: Release field population

The Release enum field (`1214267151463854`) tracks which phase/release a task belongs to. Hygiene auto-populates it:

1. **From an EPIC definition card's own name:** if an `EPIC`-typed card contains "(Phase N)", set its Release = "Phase N". (There are no parent epics in the flat model — the old "child inherits from parent" path is gone; propagate by shared `Feature` instead.)
2. **From task prefixes:** `[SCRUM-*]` = Phase 1, `[PHAS-*]` = Phase 2 (Jira migration convention)
3. **From the `create_new_phase` function:** new phases auto-create a Release enum option and tag all tasks
4. **Manual:** builder can set Release directly on any task

When creating new tasks (bootstrap, enrichment, or manually), always set the Release field to the current active phase. If the phase is unknown, ask the builder.

To add a new release option:
```bash
python3 scripts/asana_ops.py --add-release-option "Phase 5"
```

## Step 5c: Sprint field population

The Sprint **multi_enum** field (`1205043346485340`) tracks time-boxed iterations.

**Naming convention**: `Sprint M/D-M/D` (e.g. `Sprint 4/7-4/14`). Year omitted; dates uniquely identify the sprint.

**Multi-select rationale**: a task carrying over to the next sprint can carry both tags so velocity reports correctly attribute completion.

**TODO = active sprint only**: items not in the current sprint should live in BACKLOG. When opening a new sprint:
1. Add the option: `python3 scripts/asana_ops.py --add-sprint-option "Sprint 4/14-4/21"`
2. Tag the committed tasks
3. Move all unsprinted tasks from TODO → BACKLOG (Asana view: filter `Sprint is empty AND Section = TODO`, then bulk-move)

**Sprint vs Release**: Release is a phase/launch arc (months); Sprint is an iteration (1-2 weeks). Orthogonal — every task can have both set independently.

## Step 6: Backlog quality review

Beyond the automated checks, review:
- **Stale tasks:** incomplete tasks created >90 days ago with no updates. Ask: "Still relevant or should we archive?"
- **Missing acceptance criteria:** stories with descriptions but no checklist of what "done" looks like. Propose criteria from the description.
- **Epic balance:** are all tasks stuffed under one `Feature`? Propose splitting into distinct Features.
- **Context from external sources:** if the builder mentions meeting notes, transcripts, PRDs, or Slack threads — read them and update task descriptions with actionable details.

### Step 6a: Duplicate-pair detection (mandatory)

Walk the project's open tasks (skip DONE / Ready for Release) and surface likely duplicate pairs. Mirror the signal model used by `add-card` Step 2.5 — a pair counts as a likely dupe when **two or more** of these hit:

| Signal | What to check |
|---|---|
| Title token overlap | ≥50% of significant tokens shared (lowercase + stopword strip) |
| Substring containment | One title appears in the other (after stopword strip) |
| Same Feature | Both carry the same `Feature` value (same epic) |
| Same source | Both `Source: …` lines reference the same meeting / email / channel / commit / PR |
| Same domain noun | Both reference the same primary entity (specific noun, not generic verb) |

For each likely pair, present:

```
⚠️ Likely duplicate pair:

A. [TITLE] (permalink) — <section> · Opened <date> · <owner>
B. [TITLE] (permalink) — <section> · Opened <date> · <owner>

Why it looks like a dupe:
- <signal 1, with the specific overlap quoted>
- <signal 2>

How would you like to handle this?
  (1) **Merge B into A** — copy B's description/comments onto A, close B with a "Merged into <A permalink>" comment.
  (2) **Merge A into B** — same, other direction. Pick whichever has more context, the better title, or the active owner.
  (3) **Mark distinct** — leave both, append a "Related: <other permalink>" line to each so future readers see the relationship without confusion.
  (4) **Defer** — skip; surface again on next hygiene run.
```

**Bulk-mute notification rule applies** (per Step 5 → "Bulk operations"): when merging >5 pairs in one session, suppress assignee/follower notifications on the close side. Neither our `asana` MCP nor `asana_ops.py` exposes a `silent` flag yet — so post the merge comment first, then close the duplicate with `python3 scripts/asana_ops.py --complete-task <gid>`, accepting that watchers may still see the close in their Inbox.

Always quote at least one specific signal — vague "looks similar" produces noise the user can't act on.

### When no duplicate pairs are found

Report explicitly: "No likely duplicate pairs in `<project>`." This confirms the check ran rather than was skipped.

## Step 7: Source attribution (canonical rules)

**Whenever external research — meeting transcripts, emails, chat threads, calendar events, or codebase evidence — informs a change to a task, leave a trail.** This rule applies to every operation below, not just enrichment.

### The two-step rule

1. **Edit the description** with a `Source: …` line so the attribution travels with the artifact.
2. **Post a comment** via `mcp__asana__add_comment` (plain text), or `python3 scripts/asana_ops.py --post-comment <gid> '<body>...</body>'` for rich HTML, quoting the specific evidence. Descriptions get rewritten; comments are an immutable audit trail.

Both steps are required. Skipping the comment is the most common failure mode — don't.

### Source line formats

```
Source: Fireflies transcript YYYY-MM-DD "<meeting title>" — <action item / quote>
Source: Outlook email YYYY-MM-DD from <sender> — subject "<subject>"
Source: Slack #<channel> YYYY-MM-DD — thread by @<author> re: <topic>
Source: Google Calendar YYYY-MM-DD — meeting "<title>"
Source: codebase — <path>:<line> [+ commit <sha>]
```

### Apply to all four operations

| Operation | Description edit | Comment to post |
|---|---|---|
| **Create new task** from research | Append `Source: …` line | "Created from <source>: <quote>" |
| **Fill empty description** based on research | Add `[ENRICHED YYYY-MM-DD from <source>]` block | "Description filled from <source>: <quote>" |
| **Rename based on research** | (no description change unless context warrants) | "Renamed based on <source>. Old: …  New: …  <quote>" |
| **Status move from code-to-card** | (optional) | "Moved to <state>. Evidence: <path>:<line>, commit <sha>" |

### Step 7a: Gather data from available sources (when enriching from scratch)

Query all available data sources in parallel:
- **Fireflies MCP** — meeting transcripts, action items, summaries for the relevant project
- **Microsoft 365 MCP** — Outlook emails from relevant domains/contacts
- **Slack MCP** — relevant channel messages and threads
- **Google Calendar MCP** — meeting context and attendees
- **Codebase** — Glob/Grep for evidence of work-in-progress or completion
- Any other connected MCP data sources

### Step 7b: Cross-reference against existing tasks

Pull all current tasks and compare:
- Match action items / requests against existing task titles and descriptions
- Identify **gaps** (new work not yet tracked) → use the "Create new task" row above
- Identify **clarifications** (vague titles or empty descriptions that the source explains) → use "Fill empty description" or "Rename based on research"
- Identify **enrichment** (existing tasks with new context) → use "Fill empty description" with the `[ENRICHED ...]` block

### Step 7c: Place new tasks in BACKLOG

All newly created tasks from external source enrichment go to the **BACKLOG** section, not TODO. They need refinement before they're ready to work:
- Set Priority based on urgency signals in the source (explicit deadlines → P1, "nice to have" → P3)
- Set Task Type (Story, Bug, Chore, Spike based on the nature of the request)
- Auto-estimate Story Points based on description complexity
- Set the `Feature` field to the appropriate epic (and `Theme` if known) — **as a top-level task; never create it as a subtask**
- Do NOT assign — leave unassigned for triage

**Flat-task rule — never create a subtask for a workflow item.** Asana can't move a subtask between board sections, so it can never flow INBOX → DONE. Always create tasks top-level with `projects` / `memberships` set, and carry the epic via the `Feature` field instead of a `parent`. If you ever find subtasks (legacy data, or another tool created them), elevate them: `python3 scripts/asana_ops.py --elevate-subtasks <PROJECT_GID>` (non-destructive — keeps gid, comments, attachments; copies the parent's Feature/Theme onto each child). See `docs/asana-best-practices.md` → "Subtask elevation".

### Step 7d: Report summary

After any source-driven change run, report:
- Sources scanned (counts per source type)
- Tasks created / renamed / enriched (with links)
- Items already covered (no action needed)
- Ambiguous items that need the builder's input

## Step 8: Code-to-card reconciliation

When asked to scan the codebase and reconcile with cards, this is a special case of the **status-move** operation in Step 7. Apply the same two-step rule (description optional, comment required):

- Pull all incomplete tasks from the project
- Search the codebase for implementation evidence (file existence, git log referencing ticket IDs)
- For implemented cards still in TODO/WIP → move to READY FOR TESTING + comment per the table above (`Source: codebase — <path>, commit <sha>`)
- For cards in READY FOR TESTING with no code evidence → flag for investigation
- For code with no matching card → report as untracked work

## Auth

The script auto-handles auth. If `.asana-token.json` is missing, it runs `--auth` (opens browser for one-time OAuth). If expired, it refreshes automatically.
