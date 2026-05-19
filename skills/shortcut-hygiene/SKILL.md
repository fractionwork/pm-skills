---
name: shortcut-hygiene
description: >
  Audit and fix a Shortcut project against Fraction best practices. Checks for
  missing Priority custom field, stories without estimates/owners/types, missing
  epics, vague titles, empty descriptions, workflow state coverage, and stale
  Inbox stories (>30 days). Field-strict checks (estimate / type / Priority /
  epic / Iteration) skip Inbox stories — those are deferred until Inbox →
  Unscheduled promotion. The owner check skips Inbox AND Unscheduled — both
  are intentionally unassigned per the three-tier rule (ownership lands at
  sprint planning when a story moves to Started+). Reports gaps with story name + permalink
  under each non-zero category and offers fixes. Can also enrich the backlog
  from meeting transcripts, emails, and chat. **Always enforces all best
  practices by default** — only skip checks if the user explicitly opts out.
  Triggers on "clean up shortcut", "audit shortcut project", "fix shortcut
  board", "standardize shortcut", "shortcut hygiene", "enrich shortcut
  backlog".
seed_managed: true
requires_tools: [python3]
requires_files: [scripts/shortcut_ops.py]
requires_mcp: [shortcut]
---

# Shortcut Hygiene

Audit a Shortcut project against `@docs/shortcut-best-practices.md` and fix gaps.

Uses Shortcut MCP for reads where available. Uses `scripts/shortcut_ops.py` (REST API) for custom field creation and bulk operations. Auth: `SHORTCUT_API_TOKEN` env var.

## Step 1: Pick the project

List projects via MCP or REST:
```
GET /projects
```

AskUserQuestion — header: "Project", question: "Which Shortcut project to audit?", options from project list.

## Step 2: Audit

Field-strict checks (estimate / story_type / Priority / epic / Iteration) **skip stories in the Inbox workflow state** — those gaps get filled at the Inbox → Unscheduled promotion conversation, not before. The **owner check is stricter** — it skips Inbox AND Unscheduled (the BACKLOG-equivalent), only flagging Started+ stories without an owner. Title / description / source-attribution checks still apply to Inbox. See @docs/shortcut-best-practices.md for the per-state field requirement table.

### 2.1 Priority custom field
Check if a workspace-level "Priority" enum field exists with P0-P3 values.
```
GET /custom-fields
```

### 2.2 Story estimates (excl. Inbox)
Every non-Inbox story should have an `estimate` (built-in field). Inbox stories deliberately deferred.

### 2.3 Story owners (Started+ only)
Stories in `started`-type workflow states (and beyond) should have at least one `owner_id`. **Both Inbox AND Unscheduled stories stay unassigned** — three-tier rule: Inbox = unrefined, Unscheduled = refined-but-not-yet-pulled-into-active-work, Started+ = ownership required. This mirrors Asana's INBOX/BACKLOG/TODO+ split.

### 2.4 Story types (excl. Inbox)
Every non-Inbox story should have a `story_type` (`feature`, `bug`, or `chore`). Inbox deliberately deferred.

### 2.5 Epic coverage (excl. Inbox)
Non-Inbox stories should belong to an epic. Inbox stories may legitimately not have one yet.

### 2.6 Priority populated (excl. Inbox)
If the Priority custom field exists, check how many non-Inbox stories have it set.

### 2.7 Workflow state distribution
Show story counts by workflow state. Flag if all stories are in "Inbox" or "Unscheduled" (nothing triaged or refined).

### 2.8 Vague titles (all states)
Flag titles that are short (≤4 words after stripping any leading `[KEY-N]` prefix) AND start with a generic verb (`fix`, `update`, `tweak`, `change`, `adjust`, `modify`, `edit`, `improve`), or contain `TBD` / `TODO` / `misc` as a standalone word. Applies to Inbox too — vague titles are a problem at every stage.

### 2.9 Empty descriptions (all states)
Stories with no `description` text — flagged at every stage including Inbox, since the per-state table requires a 1-2 sentence description even for Inbox items.

### 2.10 Inbox summary + stale Inbox
Surface the Inbox count so the funnel is visible. Flag stories that have sat in Inbox >30 days with no `updated_at` activity — promote, reject, or explicitly defer. Inbox-as-graveyard defeats the point.

### 2.11 No Iteration (excl. Inbox)
Non-Inbox stories without an `iteration_id`. The Shortcut equivalent of Asana's Sprint check.

## Step 3: Report

For each non-zero category, the audit prints story name + `app_url` (capped at 20, with `... and N more` overflow). Example output:

```
══ Audit: ProjectName ══
  ✅ Priority custom field exists
  No estimate: 3 of 45
     • Wire up rate parity scrape
       https://app.shortcut.com/fraction/story/1234
     ...
  No owner: 8 of 45
     • ...
  Vague titles: 2
     • [SCRUM-170] Fix timeout in scraper
       https://app.shortcut.com/fraction/story/1240
  Empty descriptions: 4
     • EPIC: Platform Ops
       ...
```

AskUserQuestion — header: "Fix", question: "Fix gaps?", options: "Fix all" / "Pick which" / "Report only"

## Step 4: Fix

### Priority custom field
```bash
python3 scripts/shortcut_ops.py --setup
```

### Missing estimates / owners / types
Bulk-update via REST. For estimates, infer from story complexity if possible (small=2, medium=5, large=8). For types, default to `feature` unless name contains "bug" or "chore". For owners, leave unassigned and report.

### Missing epics
Group stories by theme/prefix and suggest epics. Create with confirmation.

### Bulk operations: mute notifications

When transitioning **more than 5 stories in one action** (workflow_state move, completion, owner change, etc.), suppress watcher notifications. A bulk transition is one bookkeeping decision; firing N emails for it is just noise.

Shortcut suppresses follower emails on the **bulk update endpoint** but not on per-story PUTs. Use:

```
PUT /api/v3/stories/bulk
{ "story_ids": [...], "workflow_state_id": <target> }
```

For operations the bulk endpoint doesn't support (per-story comments, owner additions), use the per-story PUT and accept the notification cost — or, for very large batches, temporarily un-watch the stories before the action and re-watch after.

**Singular operations** (one story, one comment from a real conversation, one assignment) keep notifications on — that signal is usually wanted. The threshold is "did the user issue this as one batch decision, or as N individual decisions" — bulk = mute, individual = loud.

When you mute, **say so in the response** so the user can adjust if they wanted the noise.

## Step 5: Backlog vs Ready workflow states

Shortcut uses workflow states instead of Asana sections. The mapping:

| Shortcut State | Type | Logical Column |
|---|---|---|
| Inbox | `unstarted` | INBOX — pre-stakeholder ideas, not yet validated |
| Unscheduled | `unstarted` | BACKLOG — validated, unrefined, not ready to work |
| Ready for Development | `unstarted` | TODO — refined and ready to start |
| In Development | `started` | WIP |
| Ready for Review | `started` | REVIEW |
| Ready for Deploy | `started` | READY FOR RELEASE |
| Completed | `done` | DONE |

New work from external source enrichment (Step 6) goes to **Unscheduled** by default. Pre-stakeholder ideas (`add-card` skill triggers like "PM mentioned", "we might want to") land in **Inbox**. Stories move from Inbox → Unscheduled only after a stakeholder discussion comment is logged (the same promotion-gate rule as Asana — see `@docs/asana-best-practices.md`). Stories move from Unscheduled → Ready for Development after refinement (description, estimate, priority, acceptance criteria).

If the project's Shortcut workflow doesn't have an "Inbox" state, add one as the first `unstarted` state — that's the structural prerequisite for the whole pre-backlog flow. Field-strict checks in shortcut-hygiene (estimate / story_type / priority) skip Inbox stories, the same way asana-hygiene skips INBOX section items.

## Step 5a: Duplicate-pair detection (mandatory)

Walk the project's open stories (skip Completed) and surface likely duplicate pairs. Mirror the signal model used by `add-card` Step 2.5 — a pair counts as a likely dupe when **two or more** of these hit:

| Signal | What to check |
|---|---|
| Title token overlap | ≥50% of significant tokens shared (lowercase + stopword strip) |
| Substring containment | One title appears in the other (after stopword strip) |
| Same epic | Both sit under the same Shortcut epic |
| Same source | Both `Source: …` lines reference the same meeting / email / channel / commit / PR |
| Same domain noun | Both reference the same primary entity (specific noun, not generic verb) |

For each likely pair, present:

```
⚠️ Likely duplicate pair:

A. [TITLE] (permalink) — <state> · Opened <date> · <owner>
B. [TITLE] (permalink) — <state> · Opened <date> · <owner>

Why it looks like a dupe:
- <signal 1, with the specific overlap quoted>
- <signal 2>

How would you like to handle this?
  (1) **Merge B into A** — copy B's description/comments onto A, close B with a "Merged into <A permalink>" comment. Use Shortcut's native "duplicate of" relationship.
  (2) **Merge A into B** — same, other direction. Pick whichever has more context, the better title, or the active owner.
  (3) **Mark distinct** — leave both, add a "relates_to" relationship in both directions so future readers see the link.
  (4) **Defer** — skip; surface again on next hygiene run.
```

**Bulk-mute notification rule applies** (per the bulk-operations memory): when merging >5 pairs in one session, set `notifySubscribers: false` on the Linear/Shortcut close-side mutation to avoid notification spam.

Always quote at least one specific signal. "Looks similar" without evidence is noise the user can't act on.

### When no duplicate pairs are found

Report explicitly: "No likely duplicate pairs in `<project>`." This confirms the check ran rather than was skipped.

## Step 6: Source attribution (canonical rules)

**Whenever external research — meeting transcripts, emails, chat threads, calendar events, or codebase evidence — informs a change to a story, leave a trail.** This rule applies to every operation below, not just enrichment.

### The two-step rule

1. **Edit the description** with a `Source: …` line so the attribution travels with the artifact.
2. **Post a comment** via `POST /stories/{id}/comments` quoting the specific evidence. Descriptions get rewritten; comments are an immutable audit trail.

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
| **Create new story** from research | Append `Source: …` line | "Created from <source>: <quote>" |
| **Fill empty description** based on research | Add `[ENRICHED YYYY-MM-DD from <source>]` block | "Description filled from <source>: <quote>" |
| **Rename based on research** | (no description change unless context warrants) | "Renamed based on <source>. Old: …  New: …  <quote>" |
| **Workflow state move from code-to-card** | (optional) | "Moved to <state>. Evidence: <path>:<line>, commit <sha>" |

### Step 6a: Gather data from available sources (when enriching from scratch)

Query all available data sources in parallel:
- **Fireflies MCP** — meeting transcripts, action items, summaries
- **Microsoft 365 MCP** — Outlook emails from relevant domains
- **Slack MCP** — relevant channel messages and threads
- **Codebase** — Glob/Grep for evidence of work-in-progress or completion
- Any other connected MCP data sources

### Step 6b: Cross-reference against existing stories

Pull all current stories from the project and compare:
- Match action items / requests against existing story names and descriptions
- Identify **gaps** (new work not yet tracked) → use the "Create new story" row above
- Identify **clarifications** (vague titles or empty descriptions that the source explains) → use "Fill empty description" or "Rename based on research"
- Identify **enrichment** (existing stories with new context) → use "Fill empty description" with the `[ENRICHED ...]` block

### Step 6c: Place new stories in Unscheduled

All newly created stories from enrichment go to the **Unscheduled** workflow state (the Shortcut equivalent of BACKLOG). They need refinement before moving to Ready for Development:
- Set Priority custom field based on urgency signals
- Set `story_type` (`feature`, `bug`, or `chore`)
- Auto-estimate based on description complexity
- Assign to an epic if one exists
- Do NOT set `owner_id` — leave unassigned for triage

### Step 6d: Report summary

After any source-driven change run, report:
- Sources scanned (counts per source type)
- Stories created / renamed / enriched (with links)
- Items already covered (no action needed)
- Ambiguous items that need the builder's input

## Step 7b: Sprint (Iteration) and Release tracking

Shortcut and Asana model these orthogonal concepts on different primitives. Don't conflate them — they answer different questions.

| Concept | Asana | Shortcut | What it answers |
|---|---|---|---|
| **Sprint** (1-2 wk iteration) | `Sprint` multi_enum custom field | **Iterations** (built-in) | "What are we working on this week?" |
| **Release** (months / launch arc) | `Release` enum custom field | **Labels** (e.g. `release:phase-2`) or a custom field if the project warrants it | "What ships together?" |

When auditing:

1. **Sprint / Iteration**: Check if Iterations are set up. Stories committed to current work should have an Iteration. Count stories with no Iteration. Report distribution by Iteration.
2. **Release**: If the team uses release labels (`release:phase-1`, `release:phase-2`, …) or a custom Release field, check coverage. If neither is in use and the project has multiple ship windows, recommend adopting Labels for it.
3. **Active-iteration view**: stories in workflow state "Ready for Development" / "In Development" should be in the current Iteration. If not, surface as a triage signal.

For new stories created during enrichment (Step 6): leave Iteration empty (lands in Unscheduled = BACKLOG). Iteration is set when the story is committed during sprint planning.

## Step 8: Code-to-card reconciliation

When asked to scan the codebase and reconcile with stories:
- Pull all incomplete stories from the project
- Search the codebase for implementation evidence (file existence, git commits referencing story IDs)
- For implemented stories in Unscheduled/Ready for Dev → move to Ready for Review/Deploy and comment with file paths + commit SHAs
- For stories in later states with no code evidence → flag for investigation
- For code with no matching story → report as untracked work

Move stories between workflow states via:
```
PUT /stories/{id}  {"workflow_state_id": "<target_state_id>"}
```

## Auth requirement

```bash
export SHORTCUT_API_TOKEN="..."
# Generate at: Shortcut → Settings → API Tokens
```
