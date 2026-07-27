# Operating rules — apply these on every PM operation

Standing rules for board work. Apply them automatically; don't wait to be reminded per
request.

Rule 2 of the previous three-rule set is deliberately gone: it said "card creation runs full
hygiene", which is now stated by `add-card`'s own description ("REQUIRED for any single-card
creation … do NOT call PM MCP `create_task*` directly"). A second copy of a rule is a copy that
drifts, and the skill description is what actually fires the skill.

---

## Rule 1: Source attribution required

When external research — a meeting transcript (Fireflies), an email (Outlook / Gmail), a Slack
thread, a calendar event, or codebase evidence — informs a change to a card (creation, rename,
description fill, status move), leave a trail **in the card**. Two steps, always:

1. Edit the description with a `Source: …` line, so attribution travels with the artifact.
2. Post a **comment** on the card quoting the specific evidence.

Both are required. The comment matters most: descriptions get rewritten, comments are the
immutable audit trail.

```
Source: Fireflies transcript YYYY-MM-DD "<meeting title>" — <action item / quote>
Source: Outlook email YYYY-MM-DD from <sender> — subject "<subject>"
Source: Slack #<channel> YYYY-MM-DD — thread by @<author> re: <topic>
Source: codebase — <path>:<line> [+ commit <sha>]
```

**Why.** A batch of card renames and description fills, based on meeting and email research,
once left only freeform `Source:` lines in descriptions and no comments. An auditor half a year
later would have had to retrace all of it by hand.

**When.** Don't wait for a formal hygiene or enrichment run. Any time you're asked to "look at
meetings / emails / the codebase to inform a PM change", this fires. Canonical implementations:
`asana-hygiene` Step 7 and `shortcut-hygiene` Step 6.

---

## Rule 3: Mute notifications on bulk operations

Bulk transitions — moving sections en masse, completing many cards, batch-assigning — suppress
notifications for the batch. One bulk operation can fire dozens of emails to assignees and
followers within minutes, which is pure noise.

- **Asana** — pass `silent=true` (or the `silent` query parameter, depending on endpoint) on the
  PUT/POST that triggers the change; `task` and `addTask` accept it. Verify against current API
  docs first: the field name has changed before.
- **Shortcut** — batch endpoints don't notify by default; prefer `update_stories` over per-story
  PUTs.
- **Linear** — GraphQL `issueUpdate` accepts `notifySubscribers: false`.
- **Single operations** (one card, one move) keep notifications **on**, so a real mention or
  assignment reaches the right person.
- **Small batches (≤5)** — offer the user the choice; muting can hide legitimate signal.
- **Larger batches (6+)** — mute by default, and say that you did, so they can ask for the noise
  back.

**Why.** A bulk move of 35 cards from READY FOR RELEASE → DONE fired ~35 completion
notifications, landing as 35 simultaneous emails for what was conceptually one bookkeeping
action.

---

## Enforcement, not just intent

These rules are prose, and prose is advisory — a direct MCP tool call made without any skill
loaded never sees them. Where a rule can be enforced in code, it is enforced in code, and this
file explains the intent behind the check rather than standing in for it:

- pm-kit's Asana MCP requires a `source` argument on write tools, so Rule 1 cannot be skipped by
  calling the tool directly.
- The same server defaults to `silent=true` once a run crosses the bulk threshold, so Rule 3
  holds even when nothing read this file.
