---
name: card-done
profiles: [pm, engineer]
description: >
  Close out the active PM card after a PR is merged. Moves the card to
  Done/Ready for Test, posts a summary comment with PR details and review
  feedback, and clears the work context. Triggers on "merged", "PR approved",
  "done with this card", "card done", "close this card", "task complete".
seed_managed: true
requires_tools: [gh]
requires_mcp_any_of: [asana, shortcut, linear]
---

# Card Done

Close the loop on the active PM card after merge.

## Step 1: Read context

Read `.devhawk-work.json`. If present, the active card's id + project + branch are recorded there — proceed to Step 2.

If `.devhawk-work.json` is missing or empty (typical for PMs working without a code branch, or for ad-hoc closeouts), prompt the user:

> No active card tracked. Which card are you closing? (paste a URL, GID, or a search term)

Resolve the response:

- **URL or GID** — extract the id and look up the card via the matching MCP (`mcp__asana__get_task`, Shortcut/Linear/Jira equivalents) to confirm it exists and capture the project context.
- **Search term** — search the user's recent assigned/active cards across the connected PM systems; show the top 5 with permalinks; ask which one. Don't guess if more than one matches.

Once resolved, hold the card record in memory for the rest of the steps. Skip Step 2's PR check (see below) when the user is closing a non-dev card — there may be no PR to inspect.

**PM-mode signal:** if the resolved card has no `branch` association in `.devhawk-work.json`, no `gh` repo configured in the cwd, or the user explicitly says "this isn't tied to a PR" / "manual close" — skip directly to Step 4 (pick destination section). Steps 2 (PR status) and 3 (PR feedback) become no-ops; Step 6 (summary comment) drops the PR-flavored sections and asks the user for the closeout summary instead.

## Step 2: Check PR status

```bash
PR_JSON=$(gh pr view --json state,mergedAt,url,title,number,reviews,comments 2>/dev/null)
```

If no PR exists for this branch, ask: "No PR found for `[branch]`. Was this merged manually, or should I create a PR first?"

If PR exists but not merged: tell the builder the current state (open, review requested, changes requested). Ask if they want to close the card anyway.

## Step 3: Collect PR feedback

```bash
# Review comments
gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[].body'
# Inline comments
gh api repos/{owner}/{repo}/pulls/{number}/comments --jq '.[] | "\(.path):\(.line) — \(.body)"'
```

## Step 4: Pick the destination section

Per `docs/asana-best-practices.md` / `docs/shortcut-best-practices.md`, the post-merge transition is one of two:

- **DONE** — straight to done. Use when the project has no QA step or the user explicitly skips it for this card.
- **READY FOR TESTING** — merge happened, but QA must validate before close. This is the default when a project uses the standard 8-section Asana flow (INBOX → BACKLOG → TODO → WIP → RFR → RFT → RFRel → DONE) or the equivalent Shortcut states.

Decide via project shape + user intent:
- If `READY FOR TESTING` exists in the project's sections / workflow states → default to RFT, ask the user if they want DONE instead.
- If only `DONE` exists → straight to DONE.

**State the choice** to the user before acting: *"Moving [card title] to [section]."*

## Step 5: Move first, then mark complete

**Critical invariant:** `completed: true` (Asana) is only set when the card lands in the **DONE** section. Marking complete in any earlier section leaves a card "completed" in WIP/RFR/RFT — a broken state that hides work from board views.

Order of operations:

1. **Move the card to the chosen section.** If the move fails (auth, missing section ID, REST error), STOP. Report the failure. Do NOT mark complete.
2. **Verify the move** by reading the card back and confirming `memberships[*].section.gid` (Asana) / `workflow_state_id` (Shortcut) matches the target.
3. **Only then**, if and only if the destination is DONE, set `completed: true` (Asana) or transition to a `done`-type workflow state (Shortcut handles this implicitly via the state transition).

### Asana (top-level task)

```
# Step 1: Move to target section (by name — resolved within the card's project)
mcp__asana__move_task_to_section(task_gid="<cardId>", section="<SECTION NAME>")

# Step 2: Verify
mcp__asana__get_task(task_gid="<cardId>")   # confirm memberships[*].section.name == target

# Step 3: ONLY if section == DONE (the curated MCP omits completion by design)
python3 scripts/asana_ops.py --complete-task <cardId>
```

If destination is RFT, the card stays `completed: false` until QA closes it (separate flow).

### Asana (epic rollup via the Feature field)

Every task is top-level (flat-task policy) — there are no subtask siblings. The epic is the task's `Feature` value. After the task is verified in DONE and marked complete, optionally roll the epic up: query the other incomplete tasks sharing the same `Feature` (`mcp__asana__search_tasks` / `mcp__asana__list_project_tasks`, filtered by the Feature value).
- None left incomplete → if an `EPIC`-typed definition card exists for that Feature, move it to DONE and mark `completed: true` (move first, verify, then complete).
- Some still incomplete → comment on the EPIC definition card (if any): "[title] completed. [N] of [M] Feature tasks remaining." Do NOT touch the epic card's state.

### Shortcut

Transition `workflow_state_id` to either Ready for Review (rare post-merge), Ready for Deploy (RFT-equivalent), or Completed. Shortcut's "completed" status is derived from the workflow state's type (`done`), so the move IS the completion — no separate boolean. Same verify step: read story back, confirm new `workflow_state_id`.

### backlog.md

Change `— WIP` to whatever the destination column header is (`— RFT` or `— DONE`). Only check acceptance criteria `- [ ] → - [x]` if the destination is DONE. See `docs/backlog-format.md`.

## Step 6: Post summary comment on card

**Asana:** `add_comment(task_id, text)`
**Shortcut:** `POST /stories/<id>/comments`
**Linear:** Linear MCP `createComment`

Comment content:
```
PR merged: [PR title] ([PR URL])

Changes:
- [file-level summary from the PR]

Review feedback:
- [reviewer comments, if any]
- [inline comments, if any]

Testing:
- [basic test steps derived from the acceptance criteria]
```

## Step 7: Clear context (only if card reached DONE)

If the destination was RFT (or anywhere other than DONE), the card is **not yet finished** — leave `.devhawk-work.json` in place so the QA close-out can find it later. Skip the rest of this step.

If the destination was DONE:

Delete `.devhawk-work.json` (or empty it).

```bash
rm -f .devhawk-work.json
```

If `.devhawk-work.json` was never present (PM-mode close), this step is a no-op.

## Step 8: Offer next

> **[Card title]** is [done | in RFT pending QA]. Pick the next task?

If yes, invoke `next-task`.

In PM-mode (no `.devhawk-work.json`, no dev branch), `next-task` won't apply — instead offer:

> Anything else to close out, or want to run hygiene on `<project>`?
