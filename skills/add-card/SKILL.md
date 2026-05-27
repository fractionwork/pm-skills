---
name: add-card
description: >
  REQUIRED for any single-card creation in an existing PM project — do NOT call
  PM MCP `create_task*` / `create_story` / `create_issue` directly; invoke this
  so hygiene rules and audit attribution are applied. Creates one Asana/Shortcut/
  Linear card routed to INBOX (pre-stakeholder idea) or BACKLOG (validated work),
  with source attribution, parent EPIC, standard fields, and a filterable
  `devhawk:add-card` marker. Triggers on "add a ticket/card/task/story/issue",
  "new card", "log a bug", "open an issue", "track this", "park this idea",
  "PM mentioned". NOT for bulk imports (use asana-hygiene Step 7) or new-project
  setup (use bootstrap).
seed_managed: true
requires_mcp_any_of: [asana, shortcut, linear]
---

# Add Card

Create a single PM card with all hygiene rules baked in. Mirror of how `asana-hygiene` would back-fill — but at *creation time* so the card is born clean.

The canonical hygiene rules live in `docs/asana-best-practices.md` and `.claude/skills/asana-hygiene/SKILL.md`. This skill is the **creation-time enforcement layer** — don't duplicate the rules here, reference them.

## Step 1: Resolve the target project

If the user names the project ("add a ticket to ELEVAT3 about X"), resolve it via Asana MCP `asana_typeahead_search` (or Shortcut/Linear equivalent).

If the user is ambiguous ("add a ticket about X"), check `.devhawk-work.json` for the active project. If still unclear, ask: "Which project — ELEVAT3, Paryani Construction, …?"

## Step 2: Decide target section — INBOX or BACKLOG

The default is **BACKLOG**. Override to **INBOX** when the request signals an unvalidated idea — something that hasn't been discussed with stakeholders yet. See `docs/asana-best-practices.md` for the full flow.

| Phrase / signal | Target section |
|---|---|
| "log a bug", "fix X", "the report broke", concrete defect | **BACKLOG** |
| "add a feature for Y" with clear scope | **BACKLOG** |
| "PM mentioned", "we might want to", "idea:", "haven't discussed yet" | **INBOX** |
| "stakeholders haven't seen this", "before we commit", "noodle on this" | **INBOX** |
| "track this thought", "park this", "future consideration" | **INBOX** |
| Tech-debt / latent risk discovered in code review, refactor, or audit — no stakeholder has weighed in | **INBOX** |
| User said "no urgency", "low priority", "when we have time", "future" | **INBOX** |
| Ambiguous | **Ask once**: "Has this been discussed with stakeholders, or is this a pre-discussion idea?" |

When in doubt, ask. The cost of putting an idea in INBOX is zero; the cost of putting an unvalidated idea in BACKLOG is that it pollutes sprint-planning views.

**Common trap — separate "fix-clarity" from "validation."** An agent reviewing code can identify a tidy fix path (env-var rename, dead-code removal, schema migration) in 30 seconds. That makes the BACKLOG slot feel right because every field is fill-able. But the question for the section choice is *who decided this work should happen*, not *can the work be specified*. Tech-debt and latent-risk discoveries should land in INBOX even when the fix is fully scoped — until a stakeholder (PM, lead, operator) signs off that it's worth prioritizing.

## Step 2.5: Duplicate check (mandatory)

Before any field validation or creation, **search the target project for likely duplicates**. Skipping this is the #1 cause of split-thread cards (two tickets discussing the same thing, neither with the full context).

### Searching

For **Asana**: `asana_search_tasks` against the resolved project with the proposed title's significant tokens (drop stopwords: a/the/and/of/to/for/on/in/with/is/are). Take top ~10 hits.

For **Shortcut**: search the project's stories via MCP, same token approach. Filter to non-archived, non-completed stories.

For **Linear**: search team issues via MCP, same token approach. Filter out completed/cancelled.

### Scoring — what counts as a likely dupe

A match is a likely dupe when **two or more** of these signals hit:

| Signal | What to check |
|---|---|
| Title token overlap | ≥50% of significant tokens shared (after lowercase + stopword strip) |
| Substring containment | Existing title appears in new title or vice-versa (after stopword strip) |
| Same parent EPIC | If the new card has a parent EPIC and an existing card sits under the same EPIC |
| Same source | The proposed `Source: …` line points at the same meeting / email / channel / commit / PR as an existing card |
| Same domain noun | Both reference the same primary entity (e.g. "approver dropdown", "S3 upload retry" — not generic verbs like "fix" or "update") |
| Recency | Existing card opened within the last 14 days (older work-streams may legitimately revisit a topic) |

A single signal alone (e.g. one shared keyword) is not enough — that produces noise. Two signals = present as a dupe candidate. Three+ signals = strongly likely dupe.

### Presenting matches to the user

If one or more candidates score as likely dupes, **stop and surface them before creating anything**:

```
⚠️ This may duplicate existing work:

1. [TITLE] (permalink)
   Status: <section/state> · Opened: <relative date> · Owner: <name or unassigned>
   Why it looks like a dupe:
   - <signal 1, e.g. "75% title token overlap: 'approver', 'dropdown', 'role'">
   - <signal 2, e.g. "Same parent EPIC: ELEVAT3 → Auth & Access">
   - <signal 3, e.g. "Same source: 2026-04-29 standup">

2. [TITLE] (permalink)
   …

How would you like to proceed?
  (a) **Update the existing card** — I'll append a comment with the new context and (if helpful) update missing fields. No new card created.
  (b) **Add anyway** — I'll create the new card and cross-link it to #1 in both descriptions ("Possibly related: …"). Use this when the items are genuinely separate.
  (c) **Cancel** — don't create anything.
```

Always quote at least one specific signal in the reasoning — vague "looks similar" is not enough for the user to make a call.

### Handling each choice

**(a) Update existing card** — call into the same source-attribution machinery as Step 6:

1. Append a comment on the existing card via `asana_create_task_story` (or Shortcut/Linear equivalent). Format:
   ```
   [ADDITIONAL CONTEXT 2026-MM-DD from <source>]
   <the new context the user provided — a quote, a snippet, or the original ask verbatim>
   ```
2. If the existing card is missing fields the new context fills (description, source, parent EPIC, etc.), prompt the user to confirm a field-level update. Do NOT silently overwrite — ask first.
3. Report the updated card's permalink + what changed. Skip Steps 3–7.

**(b) Add anyway** — proceed to Step 3, but in the new card's description add a `Possibly related: <permalink>` line (one per matched dupe). After creating, also append a one-line comment on each suspected dupe pointing back at the new card so the cross-link is bidirectional.

**(c) Cancel** — exit cleanly. No card created, no side effects.

### When no dupes are found

State explicitly: "No likely duplicates in `<project>` — proceeding to create." This is a small line, but it's the user's only confirmation that the search ran. Then continue to Step 3.

## Step 3: Pre-flight validation (before creating anything)

Validation scales with target section. INBOX is intentionally light — demanding Story Points before the team has discussed the idea is the wrong order of operations.

| Check | INBOX | BACKLOG (and below) |
|---|---|---|
| Title quality (not vague, no standalone TBD/TODO/misc) | required | required |
| Description (1-2 sentences) | required | required |
| Source attribution | **required** | required |
| Parent EPIC identifiable | optional | required (or explicit "EPIC pending") |
| Priority / Type / Points / Release | optional (skip — re-evaluate at promotion) | required |

If any required check fails, ask the user for the missing info before creating.

## Step 4: Populate fields

For **Asana** (6 standard custom fields per `docs/asana-best-practices.md`):

| Field | INBOX default | BACKLOG default | When to ask |
|---|---|---|---|
| Section | `INBOX` | `BACKLOG` | Decided in Step 2 |
| Fraction Priority | leave unset | `P2 — Medium` | If urgency mentioned ("urgent", "critical") → ask P0/P1 |
| Fraction Task Type | leave unset | Auto-detect: "bug"/"fix" → Bug, "chore"/"cleanup" → Chore, "spike"/"investigate" → Spike, "EPIC:" prefix → EPIC, otherwise Story | Never (override-able later) |
| Story Points | leave unset | Auto-estimate (mirror `auto_estimate()` in `scripts/asana_ops.py`): trivial=1, small=2, medium=3, large=5, complex=8 | If the user gave one explicitly |
| Release | leave unset | Active phase. If unknown, default to `Phase 1`. For ELEVAT3 currently: `Phase 2`. | If the project has multiple active phases |
| Sprint | none | None unless the user explicitly says "for this sprint" | Only if user mentions a sprint by name |
| Owner / assignee | unassigned | **Leave unassigned** — owner gets set during sprint planning | Never auto-assign |

INBOX cards intentionally skip Priority / Type / Points / Release — these get filled in during the INBOX → BACKLOG promotion conversation, not before.

For **Shortcut**: same logic, mapped to Shortcut primitives — workflow_state → Unscheduled (= BACKLOG), iteration → none unless committed, estimate, owner_ids (leave empty), story_type (feature/bug/chore), custom_fields[Priority].

For **Linear**: state → Backlog, priority (default Medium=3), team selected.

For **INBOX cards specifically**: skip Priority / Task Type / Story Points / Release / Sprint custom-field assignments. Only set Section=INBOX, the parent EPIC if known, and the description (with Source line). Lighter creation matches the lighter pre-flight requirements.

## Step 5: Create the card

Asana: `asana_create_task` with `name`, `notes`, `projects`, `memberships=[{project, section}]` (BACKLOG or INBOX), `custom_fields` (only the ones required for the target section per Step 4), `parent` (the EPIC if applicable). Sprint goes via PUT after creation since `asana_create_task` may not accept multi_enum on create.

**Subtask gotcha — must call `addProject` after create when `parent` is set.** Asana's API silently drops the `projects` / `memberships` params when `parent` is provided: the new task is parented but unprojected. Custom-field PUTs then fail with "Custom field with ID X is not on given object" (400). After `asana_create_task` with a `parent`, immediately call `POST /tasks/<new_gid>/addProject` (one call per project the parent is on) **before** setting any custom fields. The seed script `python3 scripts/asana_ops.py --add-subtasks-to-project <parent_gid>` is the idempotent recovery tool if this gets missed.

## Step 6: Source attribution (mandatory)

Per `feedback_pm_source_attribution.md` and `asana-hygiene` Step 7 — **two-step rule, always**:

1. Description includes a `Source: …` line at the bottom (per the format library in `asana-hygiene` Step 7).
2. Post a comment on the new card via `asana_create_task_story` (or Shortcut/Linear equivalent) quoting the specific source content.

Even when the user says "I just thought of this" — record it: `Source: ad-hoc — user request 2026-04-27`. The trail's value is consistency, not just provenance. **For INBOX cards this rule is non-negotiable** — without source attribution, an INBOX item is just untraced noise.

## Step 6.5: Audit marker (mandatory)

Every card created by this skill carries **two markers** so it's identifiable in the PM UI and parseable by audit scripts. Both are mandatory — neither is a substitute for the other.

### Marker A — system-native label/tag (filterable in the UI)

Attach the well-known label `devhawk:add-card` to the new card. If the label/tag does not yet exist on the workspace/project, create it idempotently.

| System | How |
|---|---|
| **Asana** | Workspace-level tag (`POST /workspaces/<ws_gid>/tags` if missing, then `POST /tasks/<gid>/addTag` per card). The MCP can attach an existing tag but cannot create new workspace tags — run `python3 scripts/asana_ops.py --ensure-audit-tag` once per workspace; the script is idempotent and prints the tag gid. Cache the gid in `.devhawk-work.json` for reuse. |
| **Shortcut** | Label (workspace-level). Just include `labels: [{name: "devhawk:add-card", color: "#0E8A16"}]` on story creation — Shortcut auto-creates the label on first use and attaches an existing one by name afterward. No setup script needed. |
| **Linear** | Issue label. Linear's MCP can create labels directly — call `linear.createIssueLabel({ name: "devhawk:add-card", color: "#0E8A16" })` if missing, then include the label id on creation. |

### Marker B — description footer (machine-parseable, survives label removal)

Append exactly this footer to the card's `notes`/`description`, **after** the `Source: …` line from Step 6:

```
---
Created-By: devhawk-add-card@v1 · 2026-MM-DDTHH:MMZ
```

Format requirements:
- Literal three-hyphen `---` separator on its own line before the footer (markdown hr).
- `Created-By:` key — exact case, no leading whitespace.
- `devhawk-add-card@v1` — skill name + schema version. **Bump to `@v2` if the marker format or rules change materially**; older cards stay identifiable by their `@v1` stamp.
- ISO-8601 UTC timestamp, minute precision (`Z` suffix). Use `new Date().toISOString().slice(0, 16) + "Z"` or equivalent.

### Why both markers

| | Label/tag (A) | Description footer (B) |
|---|---|---|
| Visible in card chip rows | ✓ | ✗ |
| Filterable in saved views | ✓ | ✗ (search-only) |
| Survives a user removing it | ✗ | ✓ (rarely edited) |
| Machine-parseable for audits | ✓ | ✓ (more structured) |
| Carries version | ✗ | ✓ (`@v1`, `@v2`, …) |

Use both. A skill-created card without either marker is a hygiene violation — `asana-hygiene` / `shortcut-hygiene` should flag it (future work — not in scope for this skill, but the marker format is stable enough to write a checker against).

### When the marker setup fails

If `--ensure-audit-tag` / `--ensure-audit-label` is genuinely unavailable (script missing, missing creds, MCP outage for Linear), **still attach the description footer**, log a warning, and tell the user so they can apply the label by hand later. The card itself should still get created — never block creation because the audit metadata can't be stamped. The footer alone keeps the card auditable.

## Step 7: Confirm and offer next step

After creation, report:
- Card name + permalink
- Target section (INBOX or BACKLOG)
- Fields set (or explicitly skipped for INBOX)
- Source attribution noted
- Audit marker stamped (`devhawk:add-card` label + `Created-By:` footer)
- One follow-up offer:
  - INBOX: "Want me to schedule a stakeholder discussion comment when that conversation happens?"
  - BACKLOG (sprint in flight): "Want to commit this to the active sprint?"

## Project hygiene assumptions

This skill is the **card-level enforcement layer**. It assumes the project itself is already healthy — specifically:

- **Two admins per project** (`docs/asana-best-practices.md` → "Required admins"). If the project lacks two admins, the card you create is at risk of being orphaned. Run `/asana-hygiene` first if you're not sure.
- **The 6 standard custom fields + the `devhawk:add-card` workspace tag are attached.** If `--ensure-audit-tag` has never run on this workspace, the tag won't exist. `/asana-hygiene` and the audit-tag setup are both idempotent — run them once per project / workspace and forget.
- **Notifications stay ON for singular operations.** This is a single-card create — assignees and followers SHOULD be notified. The bulk-notification suppression rule (`feedback_pm_bulk_notifications.md`) applies to `/asana-hygiene` Step 7 enrichment and similar bulk paths, not here.

## When NOT to use this skill

- **Bulk imports** (>3 cards from one source): use `asana-hygiene` Step 7 enrichment workflow instead — same rules but optimized for batch.
- **New project setup**: use `bootstrap` — that skill creates the EPICs + initial backlog as one connected scaffold.
- **Card editing** (rename, re-parent, fill description on existing card): not this skill — see `asana-hygiene` source-attribution rules for those operations.
