---
name: create-pr
profiles: [engineer]
description: >
  Create a pull request for the current branch. Auto-detects the target branch
  (develop > staging > main), rebases from it first, then creates the PR via gh.
  Triggers on "create pr", "open pr", "submit pr", "make a pr", "pull request",
  "push and pr", or any request to create a pull request.
seed_managed: true
requires_tools: [gh, jq, pnpm, node]
requires_files: [scripts/pr-audit.mjs]
---

# Create PR

## Step 1: Detect current branch + target

```bash
CURRENT=$(git rev-parse --abbrev-ref HEAD)
```

If on `main` or `develop`, stop — PRs aren't created from integration branches.

**Target branch logic** (in order):
1. If the builder explicitly named a target ("PR into main", "merge to staging") → use that
2. Else check which integration branches exist on the remote:
```bash
git fetch origin --prune
HAS_DEVELOP=$(git rev-parse --verify origin/develop 2>/dev/null && echo yes || echo no)
HAS_STAGING=$(git rev-parse --verify origin/staging 2>/dev/null && echo yes || echo no)
```
3. Pick the target:
   - `develop` exists → target `develop`
   - No `develop`, `staging` exists → target `staging`
   - Neither → target `main`

**Exception:** only target `main` directly if the builder explicitly says so. If someone says "create a PR" with no target and both `develop` and `main` exist, always pick `develop`.

Show the builder: *"PR: `[current]` → `[target]`"*

## Step 1.5: Branch-base check (refuse stacked-on-PR branches)

Refuse to create a PR for a branch whose merge-base with `origin/$TARGET` is not on `$TARGET`'s first-parent trunk — that almost always means the branch was created from another open PR's tip, and the resulting PR will become unmergeable when the upstream squash-merges.

```bash
node scripts/branch-base-check.mjs --strict --base="$TARGET"
```

If the script exits non-zero, **stop and surface the message to the builder**. Do NOT call `gh pr create`. The script's output names the guessed source branch and gives the cherry-pick recipe. Two possible recoveries:

- **Re-base the work onto `origin/$TARGET`** — `git switch -c <new-branch> origin/$TARGET`, cherry-pick the relevant commits, push, run the skill again from the new branch.
- **Stack intentionally** — if the dependency on the upstream PR is real and the merge order is coordinated, set `ALLOW_STACKED=1` for this run and target the PR base to the upstream branch (not `$TARGET`). Note the dependency in the PR body so reviewers know the merge order.

Skip this step entirely if `scripts/branch-base-check.mjs` doesn't exist (older seed snapshot — surface a one-line note that the gate is missing and continue).

## Step 2: Rebase from target

Ensure the branch is up to date before creating the PR:

```bash
git fetch origin "$TARGET"
git rebase "origin/$TARGET"
```

If the rebase has conflicts:
- Stop and tell the builder which files conflict
- Do NOT force-push or abort without asking
- Ask: "Resolve conflicts, or merge instead of rebase?"

If rebase succeeds cleanly, force-push to update the remote branch (the rebase rewrote history):
```bash
git push --force-with-lease
```

If the branch hasn't been pushed yet:
```bash
git push -u origin "$CURRENT"
```

## Step 2.5: Pre-flight review (full audit)

After the rebase + push but before `gh pr create`, run the full pr-review activities locally so the PR is opened with a known-good audit baseline. The PR doesn't exist yet, so findings are captured locally; once the PR is created in Step 3, the captured findings are replayed as PR comments.

### 2.5a. Deterministic gates (hard-block)

These two gates are non-negotiable. If either fails, stop and surface to the builder.

```bash
CHECK_OUTPUT=$(pnpm check 2>&1) ; CHECK_EXIT=$?
AUDIT_OUTPUT=$(pnpm pr:audit --base="origin/$TARGET" 2>&1) ; AUDIT_EXIT=$?
```

- **`pnpm check` (typecheck + ESLint + Biome) — Exit ≠ 0:** stop, show `$CHECK_OUTPUT`. Do NOT call `gh pr create`.
- **`pnpm pr:audit` — Exit ≠ 0 (BLOCK survives):** stop, show `$AUDIT_OUTPUT`, and ask the builder to either (a) fix the BLOCK, (b) add a per-line `// audit-skip: <check-id> — <reason>`, or (c) add `pr-audit: <check-id> — <reason>` to a commit message to demote it to WARN. Do NOT call `gh pr create`.

### 2.5b. Heavy review activities (capture, then gate)

If both deterministic gates pass, run the heavier review activities. The PR doesn't exist yet → run `pr-review` in **no-PR mode** so it captures findings to the terminal as a structured summary (no GitHub PR comments — the PR doesn't exist).

```
Skill(skill: "pr-review")  # no args → current-branch + no-PR mode
```

This runs the /code-review plugin (5-agent analysis) and the DevHawk convention audit @ 75%. Capture the resulting findings — they will be replayed as PR comments after `gh pr create` succeeds.

### 2.5c. Gate decision

Inspect the captured findings:

| Worst finding | Action |
|---|---|
| Critical | **Block.** Show findings; ask the builder to fix before creating the PR. |
| High | **Block + offer override.** Show findings; ask: "Fix first, or create PR with these as known issues noted in the body?" |
| Medium only | **Warn + proceed.** Show findings; continue to Step 3 (do not pause for confirmation). |
| None | **Proceed silently.** |

When the builder elects to proceed past High findings, add a "Known issues" section to the PR body (Step 3) listing each finding with file:line.

### 2.5d. Capture for replay

Persist the captured findings (lint + typecheck output, `pr:audit` output, /code-review summary, DevHawk audit findings) in shell variables so they can be replayed as PR comments after Step 3. The replay uses the same comment shapes as `pr-review` Activities 1–4 — same headings (`## Lint + Typecheck`, `## pr-audit`, etc.), same details blocks. Reviewers see a freshly-opened PR with the full audit trail already posted.

## Step 3: Create the PR

```bash
gh pr create --base "$TARGET" --title "[title]" --body "$(cat <<'EOF'
## Summary
[2-3 bullets from the commit messages on this branch]

## Changes
[list of files changed, grouped by type: schema, actions, UI, tests]

## Test plan
- [ ] `pnpm typecheck` passes
- [ ] `pnpm test:run` passes
- [ ] Tested in browser (if UI changes)

---
Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

**Title:** derive from the branch name or commit messages. Keep under 70 chars. Use conventional format: `feat:`, `fix:`, `chore:`, `refactor:`.

**Body:** auto-generate from `git log "$TARGET"..HEAD --oneline`. Group changes by type. Include a test-plan checklist.

Show the PR URL to the builder.

## Step 3.5: Replay captured audit findings as PR comments

Step 2.5 already ran the full pr-review activities in no-PR mode and captured the findings. Now that the PR exists, post the captured findings as PR comments — same shapes pr-review uses:

- `## Lint + Typecheck` — `pnpm check` summary + collapsed output.
- `## pr-audit` — pr-audit result + collapsed output.
- *(code-review plugin output)* — the plugin posts its own comments when it runs against a PR; if it ran in no-PR mode and produced terminal output only, summarize the findings in a follow-up `## Code Review` comment.
- `## Convention Audit (75%+ confidence)` — DevHawk findings, grouped by file.

Use `gh pr comment <PR_NUMBER> --body "$BODY"` for each. The builder ends up with a freshly-opened PR that already has the full audit trail — reviewers don't need to wait for a separate `pr-review` invocation.

Do NOT re-run the activities. They produce the same output against the same code; replay is sufficient.

## Step 4: PM card transition (always)

Every PR should correspond to a PM card so the board reflects reality. This step is **not optional** — either move the active card or ask which one to move.

### 4a. Find the active card

Check for `.devhawk-work.json`. If it exists with a `cardId`/`cardUrl`, use that.

### 4b. No active card → ask, don't skip

If `.devhawk-work.json` doesn't exist or has no active card:

> No active PM card found. Which card does this PR represent?
> 1. Provide a card ID or URL (Asana / Shortcut / Linear) — I'll move it to READY FOR REVIEW
> 2. Create a new card now — invoke `add-card` skill (in BACKLOG, then transition through TODO → WIP → READY FOR REVIEW)
> 3. Skip PM tracking for this PR (rare — explain why in PR body)

Wait for the answer. If they pick (1), record it in `.devhawk-work.json` so `card-done` can close it after merge.

### 4c. Move card to READY FOR REVIEW

Use the canonical section/state name from `docs/asana-best-practices.md` and `docs/shortcut-best-practices.md`:

- **Asana:** move to the `READY FOR REVIEW` section via our MCP (it resolves the section by name within the card's project — no need to look up a section ID):
  ```
  mcp__asana__move_task_to_section(task_gid="<cardId>", section="READY FOR REVIEW")
  ```
  If the MCP isn't connected, the script equivalent is `python3 scripts/asana_ops.py --move-section <cardId> <reviewSectionId>`.
- **Shortcut:** transition `workflow_state_id` to **Ready for Review** (started type).
  ```
  PUT /api/v3/stories/<id>  {"workflow_state_id": <ready_for_review_state_id>}
  ```
- **Linear:** transition issue to **In Review** state via Linear MCP.

If the card is in INBOX or BACKLOG (skipped over TODO/WIP), surface that to the builder before moving — usually means the card lifecycle was bypassed and they may want to confirm the right card.

### 4d. Comment on card with PR details

```
PR created: [PR title] ([PR URL])

Changes:
- [file-level summary grouped by type: schema, actions, UI, tests]

Testing:
- [basic test steps from acceptance criteria]
- [ ] typecheck passes
- [ ] lint passes
- [ ] tested in browser (if UI)
```

### 4e. Include card link in PR body

Add to the PR description: `Card: [card URL]`. This bidirectional link is what makes `card-done` work cleanly after merge.
