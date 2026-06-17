---
name: do-deploy
profiles: [engineer]
description: >
  Provision and deploy a DevHawk app to DigitalOcean App Platform end-to-end. Use when
  bootstrapping a new app's prod or staging deployment, or redeploying an existing one.
  Triggers on phrases like "deploy to DO", "provision DO app", "set up digitalocean",
  "create DO app", "ship to DO", "stand up the DigitalOcean app", "first deploy".
  Discovers current state, compares to seed targets, produces a phased plan split into
  provisioning / code / config, and executes with per-phase user checkpoints. Walks
  through DO Project creation, managed PG + Valkey clusters, app spec apply, secret
  seeding, first deploy, ingress capture, and optional staging via shared clusters.
requires_tools: [doctl, gh, jq, psql]
requires_files: [scripts/sync-app-spec.sh]
---

# DigitalOcean App Platform deployment

You are provisioning a DevHawk app on DigitalOcean App Platform. The seed defines the target shape (`app.yaml`, `app.staging.yaml`, the binding pattern, app-level envs, `dockerfile_path` on jobs, etc. — see `docs/deployment.md`). Your job is to get the project from its **current** state to that **target** state safely.

The most common failure of this skill is jumping into the 10-step happy-path before knowing what's already there. **Don't.** Follow the four phases below in order.

For pure copy-paste commands, see `runbook.md`. For failure symptoms, see `troubleshoot.md`. For the full canonical recipe, see the project's `docs/deployment.md`.

---

## Phase 0 — Discover current state

Read first, ask second. You need answers to all of these before producing a plan.

The output of Phase 0 is a single classification — one of three states — that determines how heavy Phase 1 and Phase 2 need to be:

- **Greenfield** — `doctl apps list` shows no app for this project; `doctl databases list` shows no clusters named `<PROJECT_NAME>-db` / `<PROJECT_NAME>-valkey`; the repo's `app.yaml` looks seed-compliant. **This is the common, simple case.** Phase 1 will be a trivially all-❌ table that doubles as the design spec, and Phase 2 collapses to a single phase. Move quickly — don't burden the user with ceremony.
- **Partially deployed** — some components exist (clusters but no app, or an old app pointing at the wrong clusters, or live spec drifts from the repo). Phase 1 + 2 do real work; Phase 2 phases additively to avoid downtime.
- **Already deployed (pattern adoption / drift)** — the app is up but doesn't match the seed targets. Phase 2 uses additive → cutover → cleanup phasing if prod has real users.

State this classification explicitly to the user as soon as Phase 0 completes.

### From the repo
- Does `app.yaml` exist? Does it use the seed pattern (`databases:` block + `production: true` + `cluster_name`, app-level `envs:`, `dockerfile_path` on the `db-migrate` job)? Or is it a stub / outdated?
- Does `app.staging.yaml` exist? If yes, multi-env intent.
- Does `docker/Dockerfile.worker` exist? (Required for the pre-deploy migration job.)
- Does `lib/jobs/queues.ts` and `lib/jobs/worker.ts` set `BULLMQ_PREFIX`? (Needed for shared-cluster staging.)
- Does `.github/workflows/ci.yml` exist with the `quality` + `test` jobs and the aggregate `CI Gate` job? (`CI Gate` is the single required check for branch-protection gating.) It should NOT have a deploy job — DO drives deploys directly.
- Do `app.yaml` and `app.staging.yaml` have `deploy_on_push: true` on every github stanza? That's the seed pattern — DO handles deploys, GitHub branch protection gates merges.

### From `doctl`
```bash
doctl auth list                     # configured team contexts
doctl account get                   # currently active team
doctl apps list                     # is there already a deployed app for this project?
doctl databases list                # what managed clusters exist for this team
doctl projects list                 # is there already a Project for this product
```

If `doctl apps list` shows an app whose name matches `<PROJECT_NAME>` or `<PROJECT_NAME>-staging`, **the project is already partially or fully deployed**. Get the live spec:

```bash
doctl apps spec get <app-id>        # live spec — often differs from the repo's app.yaml
```

Compare the live spec against the repo. Flag drift. Drift is common when env vars were set in the dashboard but never written back to the spec.

### From the user (only what the above can't tell you)
- `<PROJECT_NAME>` — kebab-case slug (e.g. `example-1`). Used for app name, cluster names, GitHub repo. Check `app.yaml` first; ask only if missing.
- `<ProductName>` — display name for the DO Project (e.g. `Example_1`). One project per product. Default to PascalCase form of the slug; confirm.
- **"Is this project pre-launch, or does prod carry real user traffic / sensitive data?"** This drives whether shared-cluster staging is safe and whether destructive cutovers need expand→contract phasing.
- **"Which DO team should we deploy into?"** If `doctl auth list` shows multiple contexts, ask. Use the AskUserQuestion tool with each context as an option plus an "Add a new team" fallback. For each context you can resolve email + team UUID:
  ```bash
  for ctx in $(doctl auth list 2>&1 | sed 's/ (current)//'); do
    EMAIL=$(doctl account get --context "$ctx" --format Email --no-header 2>/dev/null)
    UUID=$(doctl account get --context "$ctx" --format UUID --no-header 2>/dev/null)
    echo "$ctx → $EMAIL  team=$UUID"
  done
  ```
  Then `doctl auth switch --context <slug>` and `doctl account get` to confirm.

### Verify the DO ↔ GitHub OAuth grant for the active team
DO PATs are team-scoped, AND the GitHub org grant is per team + per org. If the repo is in an org this team hasn't connected before, app creation fails with "GitHub user not authenticated":

> Visit https://cloud.digitalocean.com/apps → Create App → GitHub source → "Manage Access" → grant DigitalOcean access to the org. One-time per team + org pair.

Confirm this is done before Phase 3.

**If you cannot answer something from the repo or doctl, ASK.** Do not assume. Bad assumptions in Phase 0 produce bad plans in Phase 2 and broken deploys in Phase 3.

---

## Phase 1 — Compare current state to seed targets

For **greenfield**, this table is mostly a formality — almost everything will be ❌ MISSING. Produce it anyway: it doubles as the design spec for what Phase 2 will provision, and confirms you're not about to recreate something that already exists in another team or under a different name.

For **partially deployed** or **already deployed**, this is where the real work happens — surface every drift before proposing any changes.

Produce the table BEFORE proposing changes:

| # | Seed target | Current state | Status | Blocker? |
|---|---|---|---|---|
| 1 | `databases:` block + `production: true` + `cluster_name` | (what `app.yaml` and live spec actually have) | ✅ / ⚠️ / ❌ / ⚪ | (any reason this can't be done?) |
| 2 | App-level `envs:` for DATABASE_URL, REDIS_URL, BETTER_AUTH_SECRET, BETTER_AUTH_URL, NEXT_PUBLIC_APP_URL, NODE_ENV | … | … | … |
| 3 | `dockerfile_path: docker/Dockerfile.worker` on `db-migrate` job | … | … | … |
| 4 | `app.staging.yaml` with `db_name`/`db_user` isolation + Valkey `/1` + `BULLMQ_PREFIX=bull:staging` | … | optional | "real users on prod" → don't share clusters |
| 5 | DO Project `<ProductName>` exists; resources tagged `env:prod`/`env:staging` | … | … | … |
| 6 | DO ↔ GitHub OAuth granted for active team + repo's org | … | … | … |
| 7 | App, PG cluster, Valkey cluster all in same metro (`region: nyc` → `nyc3`) | … | … | "PG already in fra" → migration needed |
| 8 | Managed PG cluster `<PROJECT_NAME>-db` exists | … | … | … |
| 9 | Managed Valkey cluster `<PROJECT_NAME>-valkey` exists | … | … | … |
| 10 | App `<PROJECT_NAME>` deployed and ACTIVE | … | … | … |
| 11 | (if multi-env) Staging app `<PROJECT_NAME>-staging` deployed and ACTIVE | … | … | … |

Status legend:
- ✅ MATCHES — already correct, leave alone
- ⚠️ PARTIAL — partially right; needs adjustment
- ❌ MISSING — not done; needs to be added
- ⚪ N/A — doesn't apply (e.g. single-env was the user's choice)

**Show this table to the user.** Then wait for them to react. They may scope down (e.g. "skip staging for now"), deprioritize, or surface context you didn't have ("we already have a Project named differently").

---

## Phase 2 — Phased plan, split into provisioning / code / config

For each ❌/⚠️ row, propose a fix. Group fixes into phases that don't break a running app, and split each phase into three explicit categories so they don't get conflated:

- **Provisioning** — infra changes (doctl commands, dashboard actions, cluster creation, Project assignment). Not free or instant; some are not reversible cheaply.
- **Code updates** — file edits in the repo (path + nature of change, no diffs yet).
- **Config updates** — env vars, secrets, dashboard settings. App-level vs per-component matters.

### Greenfield (most common — single phase)

Compress to one phase. The standard sequence:

```markdown
## Phase 1 — Initial provisioning + first deploy

### Provisioning  (≈$30/mo recurring once clusters online)
1. Create DO Project `<ProductName>` (if not present)
2. Create managed PG cluster `<PROJECT_NAME>-db` (db-s-1vcpu-1gb, nyc3, ~$15/mo, tagged env:prod, product:<name>)
3. Create managed Valkey cluster `<PROJECT_NAME>-valkey` (same, ~$15/mo)
4. Wait for both clusters to reach Status: online (1–5 min)
5. `doctl apps create --spec app.yaml` — DO auto-binds the clusters via app.yaml's `databases:` block
6. After first deploy succeeds: `doctl projects resources assign $PROJECT_ID --resource=do:app:$APP_ID --resource=do:dbaas:$PG_ID --resource=do:dbaas:$VALKEY_ID`

### Code updates
1. (none — assumes seed-compliant `app.yaml` is already in the repo with `<PROJECT_NAME>` substituted. If Phase 0 found stale placeholders or non-seed shape, fix that BEFORE provisioning anything.)

### Config updates
1. `BETTER_AUTH_SECRET` (app-level, Encrypted) — paste output of `openssl rand -hex 32` via DO dashboard
2. After first deploy + ingress capture: set `BETTER_AUTH_URL` and `NEXT_PUBLIC_APP_URL` to the captured ingress; this triggers an automatic redeploy

### Validation
- /api/health → 200
- `doctl apps logs <app-id> --type=run` → no missing-env errors
- `doctl apps spec get <app-id>` → matches repo `app.yaml`
```

If multi-env was confirmed in Phase 0, add a Phase 1b for the staging app on shared clusters (Step 10 in the playbook). Greenfield staging can also run in the same phase as prod since there's no traffic at risk — just sequence them: prod first, then staging once prod's clusters are online.

### Partially or already deployed (additive → cutover → cleanup)

Don't compress. Use the additive pattern from the brief:

- **Phase A — Additive** — add new things alongside existing (e.g. add app-level envs while leaving per-component duplicates in place). Deploys, but does not change behavior yet.
- **Phase B — Cutover** — switch the deploy to use the new spec (e.g. remove the SECRET DATABASE_URL; the `databases:` binding becomes the only source). One brief deploy.
- **Phase C — Cleanup** — remove deprecated config (per-component env duplicates, unused old clusters if migrating, etc.).

If prod has real users, recommend doing each phase as a separate deploy and validating between them. If prod is pre-launch (no real users yet, even if technically deployed), you can compress A+B+C — just be explicit about the choice.

---

## Phase 3 — Execute with per-phase checkpoints

Only after the user approves the Phase 2 plan. For each phase:

1. **Announce** — "Starting Phase A. This will: [N file edits], [N doctl commands]. The destructive provisioning steps are [list]; I'll pause before each one."
2. **Code + config edits** — execute without per-file confirmation (reversible via git).
3. **Pause before each provisioning command that creates, modifies, or deletes infra.** Show the exact command, the cost implication, and what it changes. Wait for go-ahead.
4. **Run validation** at the end of the phase. If anything is wrong, STOP. Do not proceed.
5. **Checkpoint** — "Phase A complete. Validation: [results]. Ready for Phase B?"

**Never batch phases.** Always pause between them.

**Never execute destructive provisioning** (deleting clusters, dropping logical databases, changing cluster size) without explicit per-command confirmation, even if the user pre-approved the plan. The plan is intent; each destructive command is its own decision.

### Standard execution playbook (greenfield happy path)

These are the 10 building blocks the plan composes. In a greenfield project they're all in Phase 1. In an already-deployed project, only the ones flagged ❌/⚠️ in Phase 1's table are needed.

#### Step 1: Verify auth (if not done in Phase 0)
Already covered in Phase 0. Skip to Step 2.

#### Step 2: Create (or confirm) the DO Project
```bash
doctl projects list --format Name,ID --no-header | awk '$1=="<ProductName>"'
# If not present:
PROJECT_ID=$(doctl projects create --name <ProductName> \
  --description "<ProductName> production + staging" \
  --purpose "Web Application" --environment Production \
  --format ID --no-header)
```

#### Step 3: Create the managed Postgres cluster
Region-pinned, tagged, smallest tier (`db-s-1vcpu-1gb` = ~$15/mo). Match the metro to the app spec's `region:`.

```bash
doctl databases create <PROJECT_NAME>-db \
  --engine pg --version 16 \
  --size db-s-1vcpu-1gb \
  --region nyc3 --num-nodes 1 \
  --tag "env:prod,product:<PROJECT_NAME>"
# Wait until Status: online.
```

#### Step 4: Create the managed Valkey cluster
DO's Redis is now Valkey-based. AppSpec engine is `VALKEY` (uppercase); CLI uses lowercase `valkey`.

```bash
doctl databases create <PROJECT_NAME>-valkey \
  --engine valkey \
  --size db-s-1vcpu-1gb \
  --region nyc3 --num-nodes 1 \
  --tag "env:prod,product:<PROJECT_NAME>"
```

If "maximum clusters reached" → see `troubleshoot.md`.

#### Step 5: Apply `app.yaml`
The `databases:` block references clusters by `cluster_name`. DO finds them, adds the app to each cluster's trusted sources, and exposes bindable env vars.

```bash
doctl apps create --spec app.yaml
APP_ID=$(doctl apps list --format ID,Spec.Name --no-header | awk '$2=="<PROJECT_NAME>"{print $1}')
```

If "GitHub user not authenticated" → return to Phase 0's org OAuth check.

#### Step 6: Set BETTER_AUTH_SECRET
The one secret the binding can't supply. Generate and paste via dashboard:

```bash
openssl rand -hex 32   # copy output
```
Dashboard → Apps → `<PROJECT_NAME>` → Settings → App-Level Env Vars → `BETTER_AUTH_SECRET` → paste → mark Encrypted.

#### Step 7: Trigger the first deploy
```bash
doctl apps create-deployment "$APP_ID"
# Phase: PENDING_BUILD → BUILDING → PENDING_DEPLOY → DEPLOYING → ACTIVE
INGRESS=$(doctl apps get "$APP_ID" -o json | jq -r '.[0].default_ingress')
```

If it ends in `ERROR` → match the symptom against `troubleshoot.md` (especially the 31-second hang and the Heroku buildpack fallback).

#### Step 7.5: Verify Dockerfile build-args for any NEXT_PUBLIC_* env vars

Before the first deploy, check `docker/Dockerfile`'s builder stage has matching `ARG` + `ENV` pairs for every `NEXT_PUBLIC_*` declared in `lib/env.ts`. `NEXT_PUBLIC_*` is inlined into the client bundle at `next build` time — DO passes BUILD_TIME-scoped vars as `--build-arg`, but the Dockerfile must declare each ARG to receive them and ENV to expose them to `next build`. Without this dance the client bundle captures `undefined` and no amount of runtime env-setting fixes it.

```dockerfile
ARG NEXT_PUBLIC_APP_URL
ENV NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL
```

Local verification before pushing:

```bash
SKIP_ENV_VALIDATION=1 NEXT_PUBLIC_APP_URL=https://test.example.com pnpm build
grep -r "test.example.com" .next/standalone   # should find hits in client chunks
```

If `grep` finds nothing, the ARG/ENV pair is missing — fix the Dockerfile before the first deploy or you'll be debugging "undefined/api/..." in production. After fixing on an already-deployed app, force a fresh build:

```bash
doctl apps create-deployment <app-id> --force-rebuild
```

#### Step 8: Set BETTER_AUTH_URL + NEXT_PUBLIC_APP_URL, redeploy
Dashboard → Settings → App-Level Env Vars → set both to `$INGRESS` → Save (auto-redeploys).

#### Step 9: Smoke-test + assign to project
```bash
curl -f "$INGRESS/api/health"   # expect 200
PG_ID=$(doctl databases list --format ID,Name --no-header | awk '$2=="<PROJECT_NAME>-db"{print $1}')
VALKEY_ID=$(doctl databases list --format ID,Name --no-header | awk '$2=="<PROJECT_NAME>-valkey"{print $1}')
doctl projects resources assign "$PROJECT_ID" \
  --resource="do:app:$APP_ID" \
  --resource="do:dbaas:$PG_ID" \
  --resource="do:dbaas:$VALKEY_ID"
```

#### Step 10: (optional) Staging app via shared clusters
If `app.staging.yaml` exists and Phase 1 flagged it ❌:

```bash
# 1. Create the staging logical DB on the shared PG cluster
doctl databases db create "$PG_ID" <PROJECT_NAME>_staging

# 2. Create the dedicated staging PG user. Without this, the app's
#    `${db.DATABASE_URL}` binding tries to connect as a non-existent
#    user and every migration fails with an auth error.
doctl databases user create "$PG_ID" <PROJECT_NAME>_staging

# 3. Run GRANT/REVOKE SQL to lock the prod user out of staging and
#    vice versa. Full SQL is in docs/deployment/staging.md → "First-time
#    staging bootstrap (runbook)" — that doc is the canonical source.
#    Skipping this step leaves the two envs sharing privileges, which
#    defeats the point of the user split.

# 4. Create the staging app — DO auto-binds clusters via app.staging.yaml
doctl apps create --spec app.staging.yaml
STAGING_APP_ID=$(doctl apps list --format ID,Spec.Name --no-header | awk '$2=="<PROJECT_NAME>-staging"{print $1}')

# 5. FRESH BETTER_AUTH_SECRET — never reuse prod's
openssl rand -hex 32
# Dashboard → <PROJECT_NAME>-staging → BETTER_AUTH_SECRET = paste, Encrypted

# 6. First deploy + ingress capture
doctl apps create-deployment "$STAGING_APP_ID"
STAGING_INGRESS=$(doctl apps get "$STAGING_APP_ID" -o json | jq -r '.[0].default_ingress')
# Dashboard → BETTER_AUTH_URL + NEXT_PUBLIC_APP_URL = $STAGING_INGRESS

# 7. Assign to project for cost attribution
doctl projects resources assign "$PROJECT_ID" --resource="do:app:$STAGING_APP_ID"
```

Staging uses Valkey DB `/1` + BullMQ prefix `bull:staging` (defense-in-depth) for shared-cluster isolation. **For the GRANT/REVOKE SQL in step 3, follow `docs/deployment/staging.md` → "First-time staging bootstrap (runbook)" verbatim** — it includes the temporary firewall add for psql access and the matching cleanup.

---

## After first deploy: secret rotation workflow

Once the app is live, secrets are normally edited via the DO console. After every console change, run `scripts/sync-app-spec.sh {staging|prod}` and commit the result so the IaC stays in sync. Full workflow + norms in `docs/secrets.md`. The `.github/workflows/spec-drift.yml` check fails any PR / cron run where the committed spec doesn't match live.

```bash
scripts/sync-app-spec.sh staging
git diff -- app.staging.yaml      # confirm only the expected envelope(s) changed
git commit -am "ops: sync staging spec — <what changed in console>"
```

The drift workflow runs on PRs touching the specs, on pushes to develop/main, and on a weekday cron (catches dashboard-only changes). Keep `DIGITALOCEAN_ACCESS_TOKEN` set in GitHub Secrets so the cron has auth.

---

## Report back

When the plan completes, summarize for the user:

- DO team: `<context-slug>` (email)
- DO Project: `<ProductName>` (ID)
- Clusters: PG `<PROJECT_NAME>-db` (ID), Valkey `<PROJECT_NAME>-valkey` (ID)
- Prod app: `<PROJECT_NAME>` (ID) — ingress URL, health-check status
- Staging app (if provisioned): `<PROJECT_NAME>-staging` (ID) — ingress URL
- Phases completed: A / B / C
- What's left for the user to do manually: set any remaining component-scoped secrets (RESEND_API_KEY, STRIPE_*) when integrations come online; finalize custom domain; etc.

If anything failed mid-phase, STOP and hand off to `troubleshoot.md`. Do not force the flow forward past a broken step.
