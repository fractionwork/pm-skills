---
name: pr-watch
profiles: [engineer]
description: >
  Background PR watcher. One tick per invocation: list open PRs, skip ones
  whose fingerprint (HEAD SHA + review decision + mergeable + checks + unresolved
  threads) hasn't changed since the last tick, surface the rest. Notifies only
  for actionable states (READY to merge, ISSUES, FIXABLE) — clean reviews stay
  silent. Designed to run on a `/loop 30m /pr-watch` cadence so you only hear
  about PRs that actually need attention. Triggers on "pr-watch", "watch open
  prs", "check pr status", "any prs ready", "monitor prs".
seed_managed: true
requires_tools: [gh, jq, node]
requires_files:
  - scripts/pr-watch-state.mjs
requires_subagents:
  - pr-watch-reviewer
requires_skills:
  - pr-review
requires_permissions:
  - "Bash(gh pr list *)"
  - "Bash(gh pr view *)"
  - "Bash(node scripts/pr-watch-state.mjs *)"
  - "Bash(jq *)"
---

# PR Watch

One tick = one quiet pass over the repo's open PRs. The watcher's job is to be
silent except when a PR has changed *and* the new state needs your attention.

## First-run setup — silence permission prompts

The watcher runs a small handful of read-only commands every tick. To avoid a
permission prompt on each one (which is especially annoying inside a `/loop`),
add these to the project's `.claude/settings.json` `permissions.allow`:

```json
"Bash(gh auth status)",
"Bash(gh pr list *)",
"Bash(gh pr view *)",
"Bash(node scripts/pr-watch-state.mjs *)",
"Bash(jq *)"
```

These are deliberately narrow — they cover the watcher's read paths only, not
mutating gh commands (`gh pr merge`, `gh pr close`, `gh pr edit`) which still
require explicit approval. `update-seed-skills` intentionally does not touch
`permissions` in settings.json, so this is a one-time per-project step.

## When to use

| Invocation | What happens |
|---|---|
| `/pr-watch` (no args) | Run one tick now. Useful for "any PRs ready?" |
| `/pr-watch snooze <N> <duration>` | Suppress notifications for PR #N for the duration (e.g. `30m`, `4h`, `2d`). Other PRs still ticked. |
| `/pr-watch show` | Print the current state file as a table. |
| `/pr-watch clear <N>` | Forget state for PR #N (forces re-review on the next tick). |
| `/loop 30m /pr-watch` | Run on a recurring interval. The interval is your choice — 30m is a sensible default during work hours. |

## Outcomes the watcher classifies into

| Outcome | When it fires | Surface? |
|---|---|---|
| `READY` | `reviewDecision=APPROVED`, `mergeable=MERGEABLE`, all required checks green, zero unresolved review threads | **Notify** — see Notification table for full body |
| `ISSUES` | pr-review found a BLOCK (`pnpm pr:audit` block survived, /code-review flagged a bug, or convention audit raised a critical/high finding) | **Notify** — see Notification table |
| `FIXABLE` | Only WARN/INFO findings, all autofix-eligible (mostly lint/convention nits) | **Notify** — see Notification table |
| `CLEARED` | Outcome is CLEAN now AND the prior recorded outcome was ISSUES or FIXABLE (one-shot transition) | **Notify** — see Notification table |
| `CLEAN` | All five pr-review activities passed (with no prior ISSUES/FIXABLE) | **Silent** |
| `SKIP` | Draft, snoozed, or unchanged fingerprint with a prior recorded outcome | **Silent** |

## State file

`.pr-watcher-state.json` at the repo root (gitignored). Per-PR entry:

```json
{
  "fingerprint": "sha=abc...|decision=APPROVED|mergeable=MERGEABLE|checks=ci=SUCCESS|unresolved=0",
  "outcome": "READY",
  "last_review_at": "2026-05-14T10:30:00Z",
  "last_notified_at": "2026-05-14T10:30:00Z",
  "snoozed_until": null
}
```

Identical fingerprint between ticks = silent skip. Anything in the fingerprint
changes (push, approval, check transition, thread resolved/added) = re-evaluate.

## Tick algorithm

### Step 1 — Prereqs
```bash
gh auth status >/dev/null
```
If unauthenticated, abort with a one-line message.

### Step 2 — List open PRs

`gh pr list` doesn't accept `reviewThreads` as a JSON field (only `gh pr view`
does), so this is a two-pass: get the listing cheaply, then augment each
non-draft PR with its reviewThreads via `gh pr view`.

```bash
PR_LIST=$(gh pr list --state open --limit 50 --json \
  number,title,url,isDraft,headRefOid,reviewDecision,mergeable,statusCheckRollup)

if [ "$(echo "$PR_LIST" | jq 'length')" -eq 0 ]; then
  echo "PR watch: 0 open"
  exit 0
fi

# Augment each non-draft PR with reviewThreads. Drafts get an empty list —
# they're skipped at plan time anyway, so we save one `gh pr view` per draft.
PR_JSON=$(echo "$PR_LIST" | jq -c '.[]' | while IFS= read -r pr; do
  number=$(echo "$pr" | jq -r '.number')
  isDraft=$(echo "$pr" | jq -r '.isDraft')
  if [ "$isDraft" = "true" ]; then
    echo "$pr" | jq '. + {reviewThreads: []}'
  else
    threads=$(gh pr view "$number" --json reviewThreads --jq '.reviewThreads')
    echo "$pr" | jq --argjson t "$threads" '. + {reviewThreads: $t}'
  fi
done | jq -s '.')
```

### Step 3 — Compute the action plan
```bash
PLAN=$(printf '%s' "$PR_JSON" | node scripts/pr-watch-state.mjs plan)
```

`PLAN` is a JSON array of `{ number, action, ... }`. Actions:

- `skip` — do nothing
- `ready` — fast-path; no review needed, just notify
- `review` — invoke pr-review to classify ISSUES / FIXABLE / CLEAN

### Step 4 — Prune closed PRs from state
```bash
OPEN_NUMBERS=$(printf '%s' "$PR_JSON" | jq -r '[.[].number] | join(",")')
node scripts/pr-watch-state.mjs prune "$OPEN_NUMBERS" >/dev/null
```

### Step 5 — Process each plan entry

For each entry where `action == "ready"`:
1. Notify using the **READY** template (see "Notification" below) — every body
   includes the merge command and the PR URL so the reviewer has a one-click
   next step.
2. Record: `node scripts/pr-watch-state.mjs record <N> READY "<fingerprint>" true`.

For each entry where `action == "review"` — dispatch one subagent per PR, in
parallel. Each subagent:

> Invoke the `pr-review` skill with argument `<N>` against PR #<N>. After the
> five activities complete, classify the outcome and emit a single final line:
>
> ```
> PR_WATCH_RESULT: outcome=<READY|ISSUES|FIXABLE|CLEAN> count=<N> summary="<one-line>"
> ```
>
> Classification rules:
> - `READY` — pr-audit clean, /code-review clean, convention audit zero findings, AND `gh pr view <N>` shows APPROVED + MERGEABLE + green checks + no unresolved threads
> - `ISSUES` — any BLOCK finding from pr-audit, any bug-flagged finding from /code-review, or any Critical/High convention finding
> - `FIXABLE` — only WARN/INFO findings AND all are auto-applicable (lint, convention nits, missing imports)
> - `CLEAN` — none of the above triggers, but PR isn't ready to merge yet (still awaiting review, etc.)

Parallel dispatch via the Agent tool — one tool call per PR in a single message
so they run concurrently. Each subagent runs in its own worktree (pr-review
handles that itself) so they don't collide.

**Pass `run_in_background: true` on every dispatch.** A full pr-review run
takes minutes (worktree, pnpm install, lint, typecheck, pr:audit, code-review,
convention audit), and there is no follow-up work in the tick that depends on
the result — the orchestrator's job is just "record outcome + notify."
Foreground dispatch blocks the watcher's main turn for the duration of the
slowest subagent, which on a `/loop` cadence wastes cache-warm time and stalls
any concurrent user request. Background dispatch lets the tick return
immediately; each subagent's completion arrives as an automatic notification,
at which point you handle Step 5's record + notify lines for that specific
PR.

On the handler turn, re-fetch the PR's current state with `gh pr view <N>`
and recompute the fingerprint before recording — the original tick's
`PR_JSON` variables are out of scope, and re-fetching also catches any
force-push that landed between dispatch and completion (so a stale
"clean" outcome doesn't get written against the old HEAD).

**Before the parallel `Agent` dispatch, record `PENDING` for each PR being
reviewed.** Without this, a subsequent tick (e.g. `/loop 30m /pr-watch` firing
again before the previous subagent returns) sees no recorded outcome for the
PR and dispatches a duplicate review — N parallel pr-reviews on the same PR,
duplicate PR comments, wasted tokens. The sentinel makes the next tick's
planner skip the PR as `action: skip, reason: pending`:

```bash
# For each entry where action == "review":
node scripts/pr-watch-state.mjs record <N> PENDING "<fingerprint>" false
```

The `record … false` form sets the outcome and fingerprint without bumping
`last_notified_at` (no notification fires for PENDING). When the real
outcome eventually arrives in a later notification turn, it overwrites
PENDING with the actual classification (READY / ISSUES / FIXABLE / CLEAN).

**Staleness.** The planner treats a PENDING entry older than 60 minutes as
crashed and re-dispatches on the next tick. That covers the case where the
subagent dies between dispatch and completion (rare, but a stuck PENDING
would otherwise leave the PR unreviewed forever).

**Dispatch to `subagent_type: "pr-watch-reviewer"`** (defined in
`.claude/agents/pr-watch-reviewer.md`), not `general-purpose`. The
pr-watch-reviewer agent preloads the `/code-review` plugin skill via its
`skills:` frontmatter, so Activity 3 of the review actually runs the plugin
instead of falling back to a manual diff read. A `general-purpose` subagent
discovers plugin skills only dynamically at invocation time, and historically
misinterprets the absence of a preloaded skill as "plugin not installed".

**One-time per-project setup for Activity 3.** Preloading the skill content
is necessary but not sufficient — the project must also explicitly allow
the subagent to invoke the Skill tool against the plugin. Add this to
`.claude/settings.json` `permissions.allow`:

```json
"Skill(code-review:code-review)"
```

Without that entry, the subagent's Skill invocation returns "denied" and
Activity 3 silently falls back to a manual diff read. See the agent file
(`.claude/agents/pr-watch-reviewer.md`) for the full three-layer model.
`sync-skills.sh` intentionally does not modify `permissions` in
settings.json, so this is a one-time per-project step.

For each subagent that returns (whether to the original tick or to a later
notification turn):
1. Parse the `PR_WATCH_RESULT:` line.
2. If `outcome` is `ISSUES` or `FIXABLE` or `READY` → notify.
3. If `outcome` is `CLEAN` **and** `prior_outcome` (from the plan entry) was `ISSUES` or `FIXABLE` → notify with the **CLEARED** template (one-shot signal that previously-flagged issues are gone).
4. If `outcome` is `CLEAN` with no prior ISSUES/FIXABLE → silent.
5. Record: `node scripts/pr-watch-state.mjs record <N> <outcome> "<fingerprint>" <notified>`.

For each entry where `action == "skip"` → do nothing. (The plan already
explains why, no need to log.)

### Step 6 — Summary

End-of-tick output to the terminal (user-visible, one short paragraph):

```
PR watch: 4 open · 2 skipped (unchanged) · 1 ready · 1 reviewed → ISSUES
```

If everything is `skip` → output `PR watch: N open, all unchanged` and exit.

## Notification

Use the `PushNotification` tool. (Load its schema via ToolSearch first if it
isn't already available: `ToolSearch(query: "select:PushNotification")`.)

Every body ends with an explicit **next-action** sentence and the PR URL so
the reviewer doesn't have to guess what to do or where to look.

| Outcome | Title | Body template |
|---|---|---|
| READY | `PR #N ready to merge` | `'<title>' — approved, checks green, no unresolved threads.` <br> **Next:** `gh pr merge <N> --squash --delete-branch` (or `/card-done` if a PM card is active). <br> `<url>` |
| ISSUES | `PR #N — <count> issue(s)` | `'<title>' — <summary>` <br> **Next:** `/pr-review <N>` to triage, push fixes, then `/pr-watch clear <N>` to re-tick. <br> `<url>` |
| FIXABLE | `PR #N — <count> auto-fixable` | `'<title>' — <summary>` <br> **Next:** `/pr-review <N>` applies the fixes, push, then `/pr-watch clear <N>`. <br> `<url>` |
| CLEARED | `PR #N — previously flagged issues cleared` | `'<title>' — review now clean (was <prior_outcome>).` <br> **Next:** revisit and decide whether it's ready to merge. <br> `<url>` |

Notifications are best-effort — if the tool isn't available in the current
environment, fall back to printing the same lines to the terminal. The state
file still gets written either way.

## Cost and cadence

- A tick where every PR is `skip` is cheap: one `gh pr list` call and one node
  invocation.
- A tick that re-reviews a PR is expensive: pr-review spawns a worktree,
  `pnpm install --frozen-lockfile`, runs lint + typecheck + pr:audit + /code-review
  + the convention audit. For 3+ changed PRs in one tick, expect minutes of
  wall-clock and meaningful subagent context usage.
- Default cadence (`/loop 30m /pr-watch`) assumes a few PRs in flight. Tune up
  to `/loop 1h` for low-velocity periods; tune down to `/loop 10m` for an
  active review day.
- Use `/pr-watch snooze <N> <duration>` aggressively. A PR you've decided to
  let sit overnight shouldn't be re-reviewed every 30 minutes.

## What this skill does NOT do

- It does not merge PRs. READY notifications surface the merge opportunity;
  the merge is still a human (or `card-done`-driven) action.
- It does not apply fixes. FIXABLE notifications point you at `pr-review <N>`
  which has the fix-and-push flow.
- It does not re-review unchanged PRs. If you want to force one, use
  `/pr-watch clear <N>` and the next tick will treat it as changed.
- It does not run during pre-push. The branch-base check + pr-audit in
  `create-pr` already cover that path.
