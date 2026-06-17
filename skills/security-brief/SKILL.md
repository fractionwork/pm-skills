---
name: security-brief
profiles: [engineer]
description: >
  Process the open `security/alerts` PR from the daily Trivy scan. Walks the
  reviewer through each finding in security/SECURITY-BRIEF.md, asks fix /
  suppress / accept-risk / false-positive, applies the action, updates the
  brief, runs lint + typecheck + unit tests, and pushes (never auto-merges).
  Triggers on "process security brief", "review security alerts", "handle
  security/alerts", "security-brief", "process trivy findings". Distinct from
  the built-in `/security-review` (which scans an arbitrary branch's diff).
seed_managed: true
requires_tools: [gh, jq, trivy, node]
requires_files: [scripts/trivy-process.mjs, security/suppressed.json, security/accepted-risks.json]
---

# Security brief processor

One invocation = one full pass through the open `security/alerts` PR. The skill's
job is to translate "the daily scan found N things" into "N things resolved with
documented rationale" — no half-states, no orphan findings.

## Pre-flight

Before doing anything, confirm:

1. `gh auth status` — must be authenticated.
2. `gh pr list --label security-scan --state open --json number,headRefName,title` — must return exactly one PR (or zero). If zero, tell the user "no open security PR; the next scan with new findings will open one" and exit.
3. The PR's `headRefName` should be `security/alerts`. If it isn't, abort with an explicit message — something has drifted from the workflow's contract.

## Step 1 — Check out the branch

```bash
PR_NUMBER=$(gh pr list --label security-scan --state open --json number --jq '.[0].number')
gh pr checkout "$PR_NUMBER"
git pull --ff-only
```

If `git pull --ff-only` fails because the reviewer made local changes since
the last scan tick, surface that to the user and let them decide: stash + pull
+ pop, or abort the skill. **Never** force-push or reset over reviewer work.

## Step 2 — Enumerate open findings

```bash
node scripts/trivy-process.mjs list --open true > /tmp/findings.json
node scripts/trivy-process.mjs summary
```

`list` returns an array of `{ fingerprint, severity, category, target, id, title, firstSeen, status }`. Show the user a short summary table:

```
open=5  critical=1 high=3 medium=1
─────────────────────────────────────────────────────────────────────
SEV       CATEGORY    ID                  TARGET            FIRST SEEN
CRITICAL  vuln        CVE-2025-XXXXX      pnpm-lock.yaml    2026-05-15
HIGH      misconfig   DS002               docker/Dockerfile 2026-05-14
HIGH      vuln        CVE-2024-YYYYY      pnpm-lock.yaml    2026-05-15
HIGH      secret      generic-token       app/page.tsx:42   2026-05-14
MEDIUM    vuln        CVE-2024-ZZZZZ      pnpm-lock.yaml    2026-05-12
```

Then ask the user how they want to triage: **walk through each one together**,
or **bulk-mark a category** (e.g. "all medium → accept-risk for 30 days").
Default to walk-through unless they ask for bulk.

## Step 3 — Walk through each finding

For each open finding, in severity order (CRITICAL → HIGH → MEDIUM → LOW):

1. **Open the relevant section in `security/SECURITY-BRIEF.md`** so the user can
   see the full context (description, refs, Trivy resolution hint).
2. **Show your analysis** — what is the actual risk to this project, what's the
   smallest fix, is there a known false-positive pattern (e.g. test fixtures,
   example code).
3. **Use `AskUserQuestion`** with these options (use this exact `header` chip):

   | Option | When to pick |
   |---|---|
   | **Fix now** (Recommended for vulns with a clean upgrade path) | A patched version exists and the bump is low-risk |
   | **Suppress (false-positive)** | The finding doesn't apply (e.g. test-only path, scanner mis-detection) |
   | **Accept risk** | The finding is real but the fix is too costly right now — must include re-evaluate window |
   | **Defer to next PR** | Out of scope for this review pass; leave open for the next session |

4. **Apply the chosen action** (see Step 4). The skill does the work; the
   reviewer just decides.

5. **Record resolution** via `scripts/trivy-process.mjs resolve`:

   ```bash
   node scripts/trivy-process.mjs resolve \
     --fingerprint "<fp>" \
     --status <fixed|suppressed|accepted|false-positive> \
     --rationale "<one-sentence reason>" \
     --reviewed-by "<git config user.email>"
   ```

   For `suppressed` / `false-positive`, the resolve subcommand auto-appends to
   `security/suppressed.json`. For `accepted`, it auto-appends to
   `security/accepted-risks.json` with a default 90-day re-evaluate window
   (pass `--re-evaluate-days N` to override).

## Step 4 — Apply each action

### Fix now

| Category | What to do |
|---|---|
| `vuln` (dependency) | `pnpm up <pkg>` to the fixed version (or to the parent that pulls a fixed transitive). If a direct bump bumps too many other things, prefer `pnpm up <parent>` first and see if the transitive resolves itself. Run `pnpm install --frozen-lockfile=false` to write the lockfile change. |
| `vuln` (image) | Bump the base image in `docker/Dockerfile` / `docker/Dockerfile.worker` to a patched tag. Confirm both Dockerfiles build locally before pushing. |
| `misconfig` (IaC) | Edit the offending file directly (Dockerfile, app.yaml, .github/workflows). Follow the Trivy resolution hint where given. |
| `misconfig` (Dockerfile root user) | Add `USER node` (or equivalent non-root) before `CMD`. Verify the container can still write any required dirs. |
| `secret` | **Stop and check with the user.** If it's a real committed secret: rotate at the provider first, then remove from history (BFG / `git filter-repo`), then add to `.trivyignore` only after rotation completes. If it's a test fixture, mark as false-positive and add a rationale that names the file pattern. |

Append a one-line note to the finding's `**Resolution notes:**` line in the
brief so the PR reviewer can see what was done.

### Suppress (false-positive)

1. Add the finding ID to `.trivyignore` with a comment block above it explaining the rationale (one line):

   ```
   # CVE-2024-XXXXX: only affects Windows path handling, we run Linux only
   CVE-2024-XXXXX
   ```

2. `trivy-process.mjs resolve --status suppressed` auto-appends to
   `security/suppressed.json` with the rationale. **Do not hand-edit that file.**

3. Move the finding's brief section from "Open findings" to a new
   "## Resolved — suppressed" section at the bottom of the brief, with the
   reviewer + date appended.

### Accept risk

1. Ask the user for: rationale (required), re-evaluate window (default 90 days).
2. `trivy-process.mjs resolve --status accepted --rationale "..." --re-evaluate-days N`.
3. Move the brief section to "## Resolved — accepted risk".
4. **Do NOT** add to `.trivyignore` — accepted risks must keep showing up in
   future scans until the re-evaluate date, so a deliberate decision happens
   at each interval. (The dedup model handles the silence: the scan sees the
   fingerprint in `accepted-risks.json` and won't re-report it. After the
   re-evaluate date, the skill surfaces it for re-review on the next scan.)

### Defer to next PR

Leave `status: open` in `in-flight.json`. The finding stays in the brief. Add
a short note in `**Resolution notes:**` (e.g. "Deferring — need maintainer
discussion on the package replacement"). Move on. The next scan won't re-add
this finding (already in-flight) and the next review session will see it.

## Step 5 — Update the brief summary

After all chosen actions are applied, regenerate the brief's top summary block:

```bash
node scripts/trivy-process.mjs summary
```

Edit `security/SECURITY-BRIEF.md`:

- Update the open-count line near the top.
- Confirm each resolved finding has its checkbox marked and resolution notes
  filled in.
- The "Open findings" section should now only contain `status: open` items.
- "Resolved — fixed" / "Resolved — suppressed" / "Resolved — accepted" sections
  hold what was done in this pass.

## Step 6 — Validate locally

```bash
pnpm install --frozen-lockfile  # in case dep changes touched the lockfile
pnpm lint
pnpm typecheck
pnpm test:unit
```

If any fails, **stop**. Show the failure to the user. Don't push a security
PR that breaks the build — the merge will block on CI and the next scan
will pile new findings on top of broken state.

## Step 7 — Commit + push

Commit with a structured message per major action:

```bash
git add -A
git commit -m "security: process $(date -u +%Y-%m-%d) brief

- Fixed: <N> finding(s)
- Suppressed: <N> finding(s)
- Accepted: <N> finding(s) (re-evaluate by <date>)
- Deferred: <N> finding(s)

See security/SECURITY-BRIEF.md for per-finding rationale."
git push
```

## Step 8 — Wait for CI, then hand off

CI must pass before merge. Don't bypass branch protection.

Once green:

```bash
gh pr view "$PR_NUMBER" --json mergeable,statusCheckRollup
```

If mergeable + checks green, surface the merge command to the user but **do
not run it**:

```
PR #N is ready to merge:
  gh pr merge $PR_NUMBER --squash --delete-branch

Run that yourself once you've eyeballed the brief one last time. After merge,
the next scan with new findings will open a fresh PR.
```

If `card-done` is wired up and the user has a PM card open for this work,
prompt them to run it after the merge to close out the card.

## What this skill does NOT do

- **Auto-merge.** Security changes always get a final human eyeball. The skill
  preps the PR; the human clicks merge.
- **Touch unrelated code.** A security review is not the right time to refactor
  surrounding code. Bumps and minimal misconfig fixes only.
- **Bypass `.trivyignore` for unresolved secrets.** Suppressing a committed
  secret without rotating it is worse than ignoring the alert — it pretends
  the secret is safe when it isn't. The skill refuses this path.
- **Run unattended.** This skill is reviewer-driven. Every finding requires an
  explicit decision; bulk-suppress is opt-in, not the default.

## State files at a glance

| File | Lives on | Purpose |
|---|---|---|
| `security/SECURITY-BRIEF.md` | `security/alerts` only | Reviewer-facing checklist |
| `security/in-flight.json` | `security/alerts` only | Fingerprints of open findings (dedup) |
| `security/suppressed.json` | `develop` | Permanent suppressions + rationale |
| `security/accepted-risks.json` | `develop` | Time-boxed accepted risks |
| `.trivyignore` | `develop` | Native Trivy filter (mirrors suppressed) |

When the PR merges, the first two disappear; the last three accumulate the
team's collective decisions and survive forever.
