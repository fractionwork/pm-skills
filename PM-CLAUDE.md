# Fraction PM operating mode

This Claude Code instance is configured for Project / Product Management work
on Fraction's PM systems (Asana, Shortcut, Linear, Jira). Use the bundled
skills to manage cards consistently.

## Available PM skills

- **`add-card`** — create a new card with all hygiene rules applied (sections, fields, parent EPIC, source attribution, dupe detection)
- **`add-comment`** — post a comment on an existing card; converts Markdown into the format each system actually accepts (Asana's HTML allowlist is fussy — this skill validates *before* the call so you never see a silent failure)
- **`card-done`** — close a card with a summary comment; works for dev-flavored merges and PM-flavored manual closeouts
- **`asana-hygiene`** — audit + fix an Asana project against Fraction best practices; includes duplicate-pair detection
- **`shortcut-hygiene`** — same for Shortcut

## Trigger phrases

| Want to … | Say something like … |
|---|---|
| Create a card | "add a ticket to ELEVAT3 about X", "log a bug about Y" |
| Comment on a card | "comment on card X", "leave a note on the ticket", "@mention Jane on this card" |
| Close a card | "close this card", "card done", "move X to done" |
| Audit a project | "clean up Asana", "audit ELEVAT3", "shortcut hygiene" |

When in doubt, just describe what you want in natural language — the skill loader picks the right one based on the trigger phrases.

## Operating rules — apply these on every PM operation

These are the standing rules for PM work. Apply them automatically — don't
wait for the user to repeat them per request.

### Rule 1: Source attribution required

When external research — a meeting transcript (Fireflies), an email
(Outlook / Gmail), a Slack thread, a calendar event, or codebase evidence —
informs a change to a PM card (creation, rename, description fill, status
move), leave a trail in the affected card. **Two-step rule, always:**

1. Edit the description with a `Source: …` line so attribution travels with the artifact.
2. Post a comment on the card quoting the specific evidence.

Both are required. Comments matter most because descriptions get rewritten — comments are the immutable audit trail.

Source line formats:

```
Source: Fireflies transcript YYYY-MM-DD "<meeting title>" — <action item / quote>
Source: Outlook email YYYY-MM-DD from <sender> — subject "<subject>"
Source: Slack #<channel> YYYY-MM-DD — thread by @<author> re: <topic>
Source: codebase — <path>:<line> [+ commit <sha>]
```

**Why this rule exists:** A previous batch of card renames + description fills based on meeting + email research left only freeform "Source: ..." lines in descriptions, no comments. An auditor 6 months later would have had to retrace by hand. Both layers are required.

**How to apply:** Don't wait for a formal hygiene/enrichment run. Anytime you're asked to "look at meetings/emails/codebase to inform a PM change," fire this rule. The canonical implementations live in `~/.claude/skills/asana-hygiene/SKILL.md` (Step 7) and `~/.claude/skills/shortcut-hygiene/SKILL.md` (Step 6).

### Rule 2: Card creation runs full hygiene

When the user asks to **add a new card** on an existing PM project — phrases like "add a ticket", "create a card", "log a bug", "open an issue", "track this", "new task" — apply the full Fraction hygiene rules at creation time, not after the fact.

Defer to the `add-card` skill. Specifically:

- Section = BACKLOG (new validated work) or INBOX (pre-discussion ideas) — see the skill for which trigger phrases route where
- All required custom fields populated for the target section (Priority / Task Type / Story Points / Release / Sprint, etc. for BACKLOG; lighter for INBOX)
- Parent EPIC identified or surfaced for input
- Source attribution applied (Rule 1)
- Title not vague (≤4 words + generic verb pattern fails)
- Description not empty
- Owner left unassigned (assigned during sprint planning)
- Duplicate detection runs first — likely dupes are surfaced for user choice

**Why this rule exists:** Without it, ad-hoc "add a ticket about X" requests bypass hygiene because no skill auto-fires for those phrases — `asana-hygiene` only triggers on words like "audit" / "clean up" / "enrich." The `add-card` skill closes that gap.

**How to apply:** When you see a card-creation phrase, load and follow `~/.claude/skills/add-card/SKILL.md`. If the skill loader doesn't fire automatically, follow the rules manually using the field defaults table in that skill.

### Rule 3: Mute notifications on bulk operations

When performing bulk transitions on PM cards — moving sections en masse, marking many cards complete, batch-assigning, etc. — suppress notifications for that batch. A single bulk operation can fire dozens of emails to assignees and followers within minutes, which is just noise.

**How to apply:**

- **Asana:** pass `silent=true` (or use the `silent` query parameter, depending on the endpoint) on the PUT/POST that triggers the change. The `task` and `addTask` endpoints accept it. Verify against current API docs before using — the field name has changed in the past.
- **Shortcut:** `update_stories` doesn't fire notifications by default for batch endpoints; use the bulk endpoint rather than per-story PUTs when possible.
- **Linear:** GraphQL `issueUpdate` accepts `notifySubscribers: false`.
- **Singular operations** (one card, one move) keep notifications on so a meaningful mention/assignment reaches the right person.
- **Small batches (≤5):** offer the user the choice — muting can occasionally hide legitimate signal.
- **Larger batches (6+):** mute by default and tell the user you did so they can adjust if they want the noise.

**Why this rule exists:** A bulk move of 35 SCRUM cards from READY FOR RELEASE → DONE fired ~35 individual completion notifications, landing as 35 emails in the team's inboxes simultaneously for what was conceptually a single bookkeeping action. "We will mute next time."

## What's NOT installed

This is the PM-only bundle. The full DevHawk seed (used by Fraction engineers) includes additional skills for code review, PR management, feature builds, deployments, and stack bootstrapping — those are not in scope here. If you find yourself needing dev tooling, ask a Fraction engineer to walk through the full seed install.

## Updating

Re-run the install command (curl one-liner or `bash install.sh` from a clone). The installer is idempotent — safe to run as often as needed.

## Where things live

- Skills: `~/.claude/skills/` (e.g. `~/.claude/skills/add-card/SKILL.md`)
- Scripts: `~/.claude/scripts/` (e.g. `~/.claude/scripts/asana_ops.py`)
- This file (operating rules + skill index): `~/.claude/CLAUDE.md`
- Tokens: `~/.claude/.env` (chmod 600 — never commit, never share)

## Token rotation

When you leave Fraction or want to rotate access:

1. Revoke the token at the source (Asana / Shortcut / Linear / Jira settings).
2. Delete the matching line from `~/.claude/.env`.
3. Re-run the install command if you want to set a fresh one up.

For Asana plugin OAuth: open Claude Code, run the plugin's logout flow, then re-auth on next use.
