---
name: asana-bootstrap
description: >
  Create a new Asana project with all Fraction standards applied at creation
  time — required admins, the 8 standard custom fields (incl. Theme + Feature),
  the 8 standard sections (INBOX→DONE), project metadata, an initial Release
  option, and optional EPIC scaffold (top-level definition cards). Creation-time inverse of `asana-hygiene` (same rules, applied
  up-front). Triggers on "create an Asana project/board", "set up an Asana
  board", "new Asana project", "bootstrap Asana", "spin up a project in Asana
  using our standards". NOT for full DevHawk bootstrap (use `bootstrap`), adding
  cards (use `add-card`), or fixing an existing project (use `asana-hygiene`).
seed_managed: true
requires_tools: [python3]
requires_files: [scripts/asana_ops.py]
requires_mcp: [asana]
---

# Asana Bootstrap

Stand up a new Asana project that's already compliant with `docs/asana-best-practices.md` — no follow-up hygiene pass required.

The canonical rules live in `docs/asana-best-practices.md` and `.claude/skills/asana-hygiene/SKILL.md`. This skill is the **creation-time enforcement layer for whole projects** — it doesn't duplicate the rules, it sequences the calls that apply them.

## Step 1: Gather inputs (ask once, batched)

Before any API call, collect:

| Input | Required | Default if not given |
|---|---|---|
| Project name | yes | (must ask) |
| Workspace / team | yes | Fraction workspace if unambiguous; else ask |
| One-line description (`notes`) | yes | (must ask — don't ship empty `notes`; hygiene will flag it immediately) |
| Start date (`start_on`) | optional | today |
| Target completion (`due_on`) | optional | leave unset, flag as TODO |
| Initial phase name | optional | `Phase 1` |
| Layout | optional | `board` (Fraction convention) |
| Color | optional | next un-used standard color |
| Privacy | optional | workspace-default (private to team) |

Use **AskUserQuestion** with one batched question for the missing required fields. Don't ping-pong one prompt at a time.

If the request was terse ("create a board called ELEVAT4"), ask once for description + start/end dates + phase. Don't infer the description from the project name — `asana-hygiene` rejects vague auto-generated descriptions just as fast as empty ones.

## Step 2: Duplicate-project check (mandatory)

Before creating anything, search the workspace for an existing project with a similar name.

```
asana_typeahead_search type=project query="<proposed name's significant tokens>"
```

Reuse `add-card` Step 2.5's signal model (significant-token overlap ≥50%, substring containment, same domain noun, same client/customer prefix). One signal alone is noise; two or more → surface as a likely duplicate.

If candidates exist, present them and ask:

```
⚠️ This name may collide with existing project(s):

1. [PROJECT NAME] (permalink)
   Workspace: <name> · Team: <name> · <N> tasks · Last activity <date>
   Why it looks like a match:
   - <signal 1, with the specific overlap quoted>
   - <signal 2>

How would you like to proceed?
  (a) **Use the existing project** — I'll switch to it. If you want hygiene applied, I can run `asana-hygiene` against it now.
  (b) **Create anyway** — distinct product / new phase that genuinely warrants a separate board. I'll append a "Created alongside <existing permalink>" note in the description.
  (c) **Cancel** — don't create anything.
```

Quote at least one specific signal — vague "looks similar" is not enough to make a call.

When no candidates score, state explicitly: "No matching projects in `<workspace>` — proceeding to create."

## Step 3: Create the project

Use Asana MCP — it has the right confirm-step UX:

```
asana_create_project_preview     name=<name> workspace=<gid> team=<gid>
                                 notes=<description> layout=board
asana_create_project_confirm     <preview_id>
```

After confirm returns the new `project_gid`, capture it. Everything from Step 4 onward needs it.

If the workspace has standard project templates, **do not use them** — they ship with non-Fraction sections and fields that hygiene would then have to undo. The seed's standards are applied in Steps 4–6 directly.

## Step 4: Apply Fraction standards (one shell call)

Run hygiene against the freshly-created project. It's idempotent and front-loads everything: admins, custom fields, sections, Release enum coverage.

```bash
python3 scripts/asana_ops.py --hygiene <PROJECT_GID>
```

What this attaches (per `.claude/skills/asana-hygiene/SKILL.md` Step 2):

- **Admins:** Jeremy + Alyssia (required per `docs/asana-best-practices.md` → "Required admins").
- **8 standard custom fields:** Fraction Priority · Fraction Task Type · Story Points · Task Progress · Release · Sprint · Theme · Feature.
- **8 standard sections:** INBOX · BACKLOG · TODO · IN PROGRESS · IN REVIEW · READY FOR TESTING · DONE · Ready for Release.

The hygiene audit at the end will report a fresh project's only "issues": missing `start_on` / `due_on` (handled in Step 5) and zero tasks (handled in Step 6 if you opt in to scaffolding). Both are expected — don't act surprised in the response.

## Step 5: Set project metadata

Hygiene doesn't auto-set `notes`, `start_on`, `due_on` — those need values you collected in Step 1. Apply via REST:

```bash
# Description / dates (PUT /projects/<gid>)
python3 -c "
from scripts.asana_ops import api
api('PUT', '/projects/<PROJECT_GID>', {
    'notes': '<description>',
    'start_on': '<YYYY-MM-DD or null>',
    'due_on':   '<YYYY-MM-DD or null>',
})
"
```

(Or call directly through Asana MCP if a single-field write is simpler — but batch the three fields into one PUT to avoid three separate redraws of the project page.)

If the user didn't supply `due_on`, leave it unset and **flag it in the final report** as the one outstanding manual TODO. Don't auto-pick "+90 days" or similar — that's a fake commitment that confuses portfolio rollups.

## Step 6: Establish the initial phase (Release enum + first EPIC)

Every project needs at least one phase so the Release custom field has a non-empty option set the moment cards are created. Default phase name: `Phase 1`. Apply via:

```bash
python3 scripts/asana_ops.py --new-phase <PROJECT_GID> "Phase 1"
```

This call (per `create_new_phase` in `scripts/asana_ops.py`):
- Verifies/creates standard sections + fields (idempotent — duplicates of Step 4, harmless).
- Posts a project status update announcing the phase.
- Adds `Phase 1` as an enum option on the global Release field if it doesn't exist yet.

If the user said "this is Phase 2 / Phase 3 of an existing product line", pass that name instead.

### Step 6a: Initial EPIC scaffold (optional)

If the user supplied a feature list, problem statement, or external source (meeting transcript, PRD), offer to seed an EPIC structure:

```
Want me to scaffold initial EPICs from <source>?
  (a) Yes — I'll create N top-level `EPIC: <name>` definition cards in BACKLOG with descriptions + Source attribution.
  (b) No — leave the board empty for manual planning.
  (c) Just the EPIC titles, no tasks yet — I'll create the definition cards; tasks come later via `add-card` or hygiene enrichment.
```

Each EPIC is a **top-level definition card** (never a parent — the flat-task policy, `docs/asana-best-practices.md` → "Task structure"). It follows the same rules as `add-card`:
- Title format: `EPIC: <Name>` (add a `(Phase N)` suffix only to drive the card's own Release auto-fill).
- Description: 2-3 sentences of scope + `Source: …` line.
- Section: BACKLOG (never INBOX — EPICs are scaffolding decisions, not unvalidated ideas).
- Task Type: `EPIC` enum option. **Feature** = the epic's own name (so its tasks group with it by shared Feature value).
- Comment: post the source quote per the two-step source-attribution rule (`asana-hygiene` Step 7).

For the tasks that belong to each EPIC, defer to `add-card` (or batch via `asana-hygiene` Step 7 enrichment if >3 from one source). They are created **top-level** with `Feature = <epic name>` — not as subtasks.

## Step 7: Assign to portfolio / cost-attribution (if applicable)

If the workspace uses portfolios for product or client grouping (Fraction convention per `docs/asana-best-practices.md` → "Portfolio organization"), add the new project:

```bash
# Asana MCP can do this in one call:
asana_add_project_to_portfolio  portfolio_gid=<gid> project_gid=<PROJECT_GID>
```

Ask once which portfolio if multiple are plausible. If the user doesn't know or there's no clear match, skip and flag it as a TODO in the final report.

## Step 8: Source attribution (mandatory)

Per `feedback_pm_source_attribution.md` and the canonical rule in `asana-hygiene` Step 7 — projects need the same trail as cards:

1. **Description (notes):** end with a `Source: …` line. Format from `asana-hygiene` Step 7. For ad-hoc creation use `Source: ad-hoc — user request <YYYY-MM-DD>`.
2. **Project status update (the one `--new-phase` posts):** edit it to include the source quote, or post a second status with the quote if the auto-generated text is too generic.

Asana doesn't expose project-level comments the same way tasks do, but project status updates are the closest immutable artifact and serve the same audit purpose.

## Step 9: Confirm and offer next step

Final report — keep it tight:

```
✓ Created Asana project: <name>
  Permalink: <url>
  Workspace · Team · Portfolio (if applied)

Standards applied:
  ✓ Admins: Jeremy, Alyssia
  ✓ 8 custom fields attached
  ✓ 8 standard sections
  ✓ Release option: Phase 1
  ✓ Description + Source line set
  ✓ start_on: <date>

Outstanding (manual):
  • due_on — not set; ask when there's a real target
  • <portfolio assignment if skipped>

Next step?
  (a) Scaffold initial EPICs from a meeting transcript / PRD / email thread → enrichment per asana-hygiene Step 7
  (b) Add the first card now → I'll switch to `add-card`
  (c) Done for now — call back when you're ready to plan
```

## Step 10: Bulk-notification etiquette

If Step 6a creates more than 5 EPICs or initial tasks in one shot, **mute notifications** per the `feedback_pm_bulk_notifications.md` rule. Mechanics: pass `params={'silent': 'true'}` on `POST /tasks` and section-assignment writes (per `asana-hygiene` Step 5 → "Bulk operations").

Singular creations (one EPIC, one card) keep notifications on — that signal is wanted. The bright line is "did the user issue this as one batch decision".

When you mute, say so in the response so the user can adjust if they wanted the noise.

## When NOT to use this skill

- **Full DevHawk product bootstrap** (code scaffold + GitHub repo + DO app + Asana project bundled): use `bootstrap` — that skill calls into this skill for the Asana-only piece but adds code + infra around it.
- **Existing project needs cleanup**: use `asana-hygiene` — same rules, applied retroactively.
- **Adding one card to an existing project**: use `add-card` — narrower, faster.
- **Renaming / archiving / merging existing projects**: use `asana-hygiene` Step 8 reconciliation rules + manual MCP calls.
