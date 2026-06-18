---
name: ado-asana-sync
profiles: [pm, engineer]
seed_managed: true
requires_tools: [python3]
requires_files: [scripts/asana_ops.py, scripts/ado_asana_sync.py, scripts/ado_auth.py]
description: >
  Mirror Azure DevOps work items into an Asana board — create + update cards, move
  sections by ADO state, and mirror ADO comments one-way (ADO → Asana). Scope is the
  set of people configured in the skill's state; ADO is the source of truth and Asana
  is the mirror. Triggers on "sync ADO to Asana", "mirror my Azure cards to Asana",
  "sync work items to the board", "update Asana from Azure DevOps", "pull DevOps cards
  into Asana". NOT for pushing Asana edits back to ADO (one-way only), and NOT for
  items outside the configured people.
---

# Azure DevOps → Asana Mirror

Mirrors ADO work items **assigned to a configured set of people** into an Asana board. Creates new
cards, updates changed ones (fields + status/section), and mirrors ADO comments one-way. Idempotent
and incremental — safe to re-run. ADO is the source of truth; Asana is a faithful mirror.

The work is done by **`scripts/ado_asana_sync.py`**, which hits ADO via REST and reuses
**`scripts/asana_ops.py`** for every Asana write and **`scripts/ado_auth.py`** for the ADO PAT.
Correlation (which ADO id maps to which Asana card), the change watermark, and per-item comment
markers live in a local state file `~/.claude/.ado_asana_state.json` (chmod 600). Each card also
carries an `External-ID: ado:NNNN` footer so the mapping survives a lost state file.

## Step 1 — One-time config (people + target project)

Resolve identities and the target board, then seed them into state.

```bash
# Target Asana project — pick the board's gid from the list
python3 ~/.claude/scripts/asana_ops.py --list-projects

# Asana user GID per person you want to mirror (match each to their ADO assignee email)
python3 ~/.claude/scripts/asana_ops.py --find-user "<person name or email>"
```

For each person, confirm their **ADO email** (their `System.AssignedTo` uniqueName in Azure DevOps).
Then seed config into state (`label` is any handle; add one block per person):

```bash
python3 ~/.claude/scripts/ado_asana_sync.py --config '{
  "asana_project_gid": "<ASANA_PROJECT_GID>",
  "org_url": "https://dev.azure.com/<ORG>",
  "project": "<ADO PROJECT NAME>",
  "people": {
    "<label>": {"ado_email": "<person@org>", "asana_gid": "<asana-gid>"}
  }
}'
```

> Example (Rogue Hire): `org_url` `https://dev.azure.com/roguehire`, `project` `Rogue Hire Platform`,
> people `jeremy` (`jeremy@hirefraction.com`, asana `1206452951803612`) and `belle`.

**State→section mapping** has sensible defaults (`New→INBOX, Active→WIP, Resolved→READY FOR TESTING,
Closed/Removed→DONE`). ADO process templates vary (Agile/Scrum/Basic) — if the board uses different
state names, confirm them and override via `"state_section": {"<ado state lower>": "<ASANA SECTION>"}`
in the same `--config`.

## Step 2 — Preflight (secrets + board shape)

- **Asana auth:** `python3 ~/.claude/scripts/asana_ops.py --token >/dev/null && echo OK` (auto-auths if
  needed). Set `ASANA_WORKSPACE` for multi-workspace accounts.
- **ADO PAT (central per-org store):** store a PAT once per org — read from **stdin**, never argv:
  ```bash
  echo -n '<PAT>' | python3 ~/.claude/scripts/ado_auth.py --set-pat https://dev.azure.com/<ORG> \
      --scope "Work Items: Read" --note "ado-asana-sync"
  python3 ~/.claude/scripts/ado_auth.py --list   # masked check
  ```
  Resolution order is `ADO_PAT` env → `--pat-file` → this store. **Minimal scope: Work Items → Read.**
  The store (`~/.claude/.ado-credentials.json`) is chmod 600 and git-ignored; the PAT is never echoed.
  ⚠️ Never reuse a PAT that has appeared in a chat/transcript — rotate it first.
- **Board shape:** if a dry run warns about a missing section/field, run `/asana-hygiene` on the board
  first.

## Step 3 — Dry run (always first)

```bash
python3 ~/.claude/scripts/ado_asana_sync.py --dry-run            # incremental (since last watermark)
python3 ~/.claude/scripts/ado_asana_sync.py --dry-run --only <ADO_ID>   # scope down while validating
```

Prints a per-item plan and **writes nothing**:
```
Plan: 2 create, 3 update, 4 comment(s) across 5 item(s)
  CREATE  #1234  'Fix the thing'  → WIP  [Bug/P1/belle@…]  +1 comment(s)
  UPDATE  #1190  [name, state, section→DONE, +2 comment(s)]
```
First run with no watermark = **full backfill** of every currently-assigned item.

## Step 4 — Confirm, then apply

After the user approves the plan:

```bash
python3 ~/.claude/scripts/ado_asana_sync.py            # incremental apply
python3 ~/.claude/scripts/ado_asana_sync.py --only <ADO_ID>   # single item
```

State is checkpointed after each item (resumable); the watermark advances at the end. **Notification
noise (PM Rule 3):** first-run backfill and any 6+ batch are bulk — tell the user a bulk mirror ran so
they can mute follower email. Single incremental updates are fine to leave noisy.

## Step 5 — Report

Summarize N created / M updated / K comments mirrored and the new watermark. Mirrored cards carry a
`Source: Azure DevOps work item #NNNN` line + `External-ID: ado:NNNN` footer, satisfying the
**source-attribution rule (PM Rule 1)** — attribution travels with the card, and each mirrored ADO
comment is itself the comment-trail.

## How it behaves (so you can explain it)

- **Assignee is mirrored** onto the card (deliberate deviation from "leave unassigned" — faithful
  mirroring is the point).
- **Comments are one-way** ADO → Asana, attributed (`ADO comment by <author> on <date>`), deduped by
  ADO comment id, so re-runs never double-post.
- **Closed/Removed** items move to **DONE** and are marked complete.
- **Idempotent:** a no-change item produces an empty plan; updates push only the changed fields.
- **Recovery:** if the state file is lost, the `External-ID: ado:NNNN` footer lets the next run re-find
  existing cards (one project scan) instead of creating duplicates.

## Verification (prove it on one item before a full run)

1. `--dry-run --only <id>` → diff shows CREATE with correct name/type/priority/points/section/assignee
   + comment count.
2. Apply `--only <id>` → card in the mapped section, fields + assignee set, footer present, comments
   mirrored; state file gains the item.
3. In ADO change the item's title + state + add a comment → `--only <id> --dry-run` shows only those 3
   → apply → card patched, section moved, exactly one new comment (no dupes).
4. Re-run `--only <id>` → empty plan (idempotent).
5. Delete the item's entry from `~/.claude/.ado_asana_state.json` → `--only <id>` finds the card via the
   footer (no duplicate). Then run the full incremental.

## When NOT to use this skill

- **Asana → ADO** write-back or any bidirectional sync — one-way mirror by design.
- **Items outside the configured people** — widen by adding to `people` in config.
- **Creating brand-new work** in Asana — use `add-card`. This only mirrors existing ADO items.
- **Fixing board hygiene** (missing fields/sections) — run `asana-hygiene` first, then sync.
