---
name: milestone-mapper
description: >
  Generate a standalone HTML milestone progress tracker for a client or internal project.
  Produces a self-contained file with: Release Notes (what shipped), Gantt progress view,
  priority roadmap, on the radar, and blocked items. Pulls data from Fireflies transcripts,
  Asana, Jira, and Shortcut. Triggers on phrases like "milestone tracker", "milestone map",
  "create a milestone progress page", "build a status tracker", or "generate a gantt".
---

# Milestone Mapper

Generate a standalone HTML milestone tracker — a client-facing or internal status page that tells the story: **what shipped → where we are → where we're going → what's blocked**.

The output is a single self-contained HTML file. No external dependencies. Served locally via `python3 -m http.server 8080` or pushed to a GitHub repo.

---

## Phase 1: Discovery

Gather what you need before generating anything. Ask the user:

1. **Project / client name** — what is this tracker for?
2. **Audience** — client-facing (CEO/exec level) or internal?
3. **Priority source** — where did the priorities come from? (meeting, spreadsheet, kickoff call)
4. **Timeline** — when did the project start? Target end date?
5. **Team** — who's working on this? (names + color coding for assignee column if needed)
6. **Data sources** — which are connected: Fireflies, Asana, Jira, Shortcut, GitHub?
7. **Output location** — local file only, or push to a GitHub repo?

If a Fireflies transcript ID or meeting name is provided, pull it immediately to extract priorities and context.

---

## Phase 2: Data Gathering

Pull data from all available sources **in parallel**:

### Fireflies
- Search for transcripts related to the project/client
- Extract: priority order, milestone names, timeline commitments, blockers, assignee mentions
- Note the exact transcript ID and date for source attribution

### Asana / Jira / Shortcut
- Pull active epics and their status
- Pull recently completed tasks (last 1–2 weeks) for the Release Notes section
- Pull blocked items
- Note ticket IDs for source attribution

**If the Asana project has a "Theme" custom field:** use it as the grouping key for all sections — Release Notes cards, Gantt rows, and priority list items should all use Theme names as track names. Query completed tasks filtered by Theme to build Release Notes groups. This replaces manual milestone-to-ticket mapping.

- Fetch the Theme custom field GID from the project's custom field settings
- Group completed tasks by their Theme enum value
- Tasks with no Theme set are platform/infra — exclude from client-facing output unless relevant

### Cross-reference
- Map completed tickets to milestone tracks using the Theme custom field (e.g., Theme = "Daily Detail" → Daily Detail track)
- If no Theme field exists, infer track from ticket title/epic
- Count total tickets shipped this period — if 20+, surface that count prominently
- Identify items that are "on the radar" but not yet scheduled

---

## Phase 3: Content Planning

Before generating HTML, confirm content with the user:

### Section 0 — Release Notes
Present a draft grouped by Theme (or track if no Theme field):
```
Theme Name (→ Priority N)
• Bullet item (ticket ref)
• Bullet item
```
Ask: "Does this look right before I write the HTML?"

**Rules:**
- Group by Theme custom field value — one card per Theme that had completions this period
- Each group shows which milestone priority it maps to (`→ Priority N`)
- If 20+ tickets: show the count prominently (`24 tickets`)
- Exclude tasks with no Theme (platform/infra) unless the client cares
- For ambiguous items (e.g., something that sounds blocked but isn't), verify before including
- Add clarifying notes on items that could be misread (e.g., "via manual data feed — no scraper required")
- Theme name in Release Notes card must exactly match the Theme name in the Gantt and priority list

### Section 1 — Progress (Gantt)
Confirm:
- Milestone names and their target dates
- Current status of each (Done / In Progress / At Risk / Planned / Ready to Ship)
- Timeline span (start date → end date)

### Section 2 — What We're Building
Confirm:
- Priority list order and source (who ranked them and when)
- Status tags for each (Active / Ready to Ship / Planned / Discuss)

### Section 3 — On the Radar
Items acknowledged but not yet scheduled. Confirm what belongs here vs. the main Gantt.

### Section 4 — Blocked
External blockers outside the team's control. Confirm blocker details and who owns resolution.

---

## Phase 4: HTML Generation

Generate a single self-contained HTML file. Follow all layout and CSS patterns below exactly.

### File naming
`[client-slug]-milestone-progress.html` — e.g., `spinxpress-milestone-progress.html`, `elevat3-milestone-progress.html`

### Output location
Default: `[filename]` in the current project directory
If GitHub repo specified: generate locally first, then push.

---

### Layout structure

```
Page header (project name + date)
├── Section 0: Release Notes (what shipped this period)
├── Section 1: Progress (Gantt chart)
├── Section 2: What We're Building & Why (priority list)
├── Section 3: On the Radar (upcoming, unscheduled)
└── Section 4: Blocked
```

---

### CSS design system

Use this exact system — do not deviate:

```css
*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: #fff;
  color: #1A2332;
  padding: 40px 48px 56px;
  min-width: 800px;
}

/* Section headers */
.section-eyebrow { font-size: 10px; font-weight: 700; text-transform: uppercase; letter-spacing: 1.5px; color: #C5D0DB; margin-bottom: 4px; }
.section-title   { font-size: 22px; font-weight: 700; color: #1A2332; margin-bottom: 4px; }
.section-sub     { font-size: 13px; color: #9AAABB; margin-bottom: 24px; }
.section-rule    { height: 2px; background: #E4EAF0; margin-bottom: 0; }
.section-header  { margin-top: 56px; margin-bottom: 0; }

/* Status badge colors */
.s-done     { background: #E0F2F1; color: #00695C; }
.s-active   { background: #E3F2FD; color: #1565C0; }
.s-atrisk   { background: #FFF8E1; color: #E65100; }
.s-blocked  { background: #FFEBEE; color: #C62828; }
.s-planned  { background: #ECEFF1; color: #607D8B; }
.s-ready    { background: #E0F2F1; color: #00695C; }
.s-watch    { background: #FFF8E1; color: #F9A825; border: 1px solid #FFE082; }
```

**Color palette for gantt bars:**
- Done: `#00897B` on `#E0F2F1`
- In Progress: `#1976D2` on `#E3F2FD`
- At Risk: `#FF8F00` on `#FFF3E0`
- Planned: `#90A4AE` on `#ECEFF1`

**Assignee colors (if used):**
- Primary dev (e.g., Austin): `#1565C0` (blue)
- Secondary dev (e.g., Dilan): `#2E7D32` (green)
- Third (e.g., Sam): `#6A1B9A` (purple)
- Client-owned: `#FFB74D` (orange), rendered with `box-shadow: inset 3px 0 0 #FFB74D` — NOT border-left (avoids layout shift)

---

### Gantt timeline math

Timeline runs from project start → project end. Calculate percentages:

```
position% = (date - start_date).days / total_days * 100
```

Month divider positions use the first of each month.

Today line: `left: [today_pct]%` — red (`#EF5350`), 2px wide, z-index 5.

**Done rows:** no today-line. Bar fills from 0% to completion date position.

**Bar anatomy:**
```html
<div class="gbar" style="left:[start]%;width:[width]%">
  <div class="gbar-track" style="background:[track-color]"></div>
  <div class="gbar-fill" style="background:[fill-color];width:[progress]%"></div>
  <div class="gbar-tick" style="background:[fill-color]"></div>
  <div class="gbar-date">[Target Date]</div>
</div>
```

---

### Release Notes card grid

```html
<div class="rn-grid"> <!-- grid-template-columns: repeat(auto-fill, minmax(240px, 1fr)) -->
  <div class="rn-card">
    <div class="rn-track">[Track Name]</div>
    <div class="rn-milestone">→ Priority N</div>
    <ul class="rn-list">
      <li>[Item]</li>
    </ul>
  </div>
</div>
```

Ticket count badge on the section title:
```html
<span class="rn-count">[N] tickets</span>
<!-- background: #E8F5E9; color: #2E7D32; -->
```

---

### Priority list row

```html
<div class="priority-item">
  <div class="priority-num">[N]</div>
  <div class="priority-name">[Name]</div>
  [optional: <div class="priority-assignee pa-[name]">[Name]</div>]
  <div class="priority-desc">[Description]</div>
  <span class="priority-source">[Source · Date]</span>
  <span class="priority-tag pt-[status]">[Status]</span>
</div>
```

**Client-owned items:** use `box-shadow: inset 3px 0 0 #FFB74D` on `.priority-item`, NOT `border-left`.

---

### Source attribution

Every item in the priority list and Gantt should carry a source tag:
- `[Location] · [Month Year]` — e.g., `Houston · Mar 2026`
- `⚠ New scope · [Call date]` — for items that came in after the original plan
- `discuss with client` — for items not yet validated

---

### On the Radar cards

```html
<div class="on-deck-grid"> <!-- repeat(auto-fill, minmax(220px, 1fr)) -->
  <div class="on-deck-card">
    <div class="on-deck-priority">Priority [N]</div>
    <div class="on-deck-name">[Name]</div>
    <div class="on-deck-desc">[Description]</div>
  </div>
</div>
```

Blocker card (for client-owned blockers):
```html
<div class="on-deck-card" style="border-left: 3px solid #EF5350;">
  <div class="on-deck-phase" style="color:#EF5350;">⛔ Blocker — [Name]</div>
  <div class="on-deck-name">[What's blocked]</div>
  <div class="on-deck-desc">[Details + what we need from them]</div>
</div>
```

---

### Legend + footer

Always include at the bottom of the Gantt section:
```html
<div class="footer">
  <div class="leg"><div class="leg-sw" style="background:#FF8F00"></div>At Risk</div>
  <div class="leg"><div class="leg-sw" style="background:#1976D2"></div>In Progress / Planned</div>
  <div class="leg"><div class="leg-sw" style="background:#00897B"></div>Done / Ready to Ship</div>
  <div class="leg"><div style="width:2px;height:14px;background:#EF5350"></div>Today ([Month Day])</div>
</div>
```

---

## Phase 5: Deployment (optional)

If the user wants to push to GitHub:

1. Check if the target repo is already cloned locally; if not, clone it
2. Copy the HTML file to the repo root (or a specified path)
3. Commit with message: `Add [project] milestone progress tracker`
4. Push to main (confirm before pushing)

If GitHub Pages is not enabled on the repo, note that the file won't be auto-served as a rendered page — it's version-controlled storage. Offer to enable Pages if the user wants a live URL.

---

## Rules

- **Confirm content before writing HTML** — always show the Release Notes draft and get a yes before generating
- **No external dependencies** — the HTML file must be fully self-contained (no CDN links, no external fonts)
- **No tasks column in Gantt** — clients don't care about ticket counts; remove if present
- **Theme = milestone track** — if the Asana project has a "Theme" custom field, use Theme values as the canonical track names across all sections (Release Notes, Gantt, priority list). Never invent different names.
- **Naming consistency** — if a track appears in Release Notes AND the Gantt, use the exact same name in both
- **Ticket volume matters** — if 20+ tickets shipped, say so prominently; it signals momentum
- **Clarify ambiguous items** — if a bullet could be misread by the client (e.g., sounds like blocked work but isn't), add a parenthetical
- **Source attribution on everything** — every priority and Gantt row should carry where it came from
- **Done items float to top of Gantt** — completed milestones appear first
- **Client-owned items use box-shadow, not border-left** — avoids layout shift with `box-sizing: border-box`
- **Today line omitted on Done rows** — don't show a today marker on completed milestones
