# do-deploy — failure modes and fixes

Ten symptoms account for almost every stuck deploy. Match the symptom, apply the fix, redeploy.

## 31-second hang on db-migrate

**Symptom:** drizzle-kit spinner runs for ~31 seconds with no SQL output, then the pre-deploy job exits with "component terminated with non-zero exit code: 1". No migrations execute. Build logs show the spinner, runtime logs show nothing useful.

**Cause:** `DATABASE_URL` was declared as a `type: SECRET` env var with a hardcoded `private-<host>` URL. That bypasses DO's binding, so:
- The CA cert is never injected
- The private hostname doesn't resolve from inside the App Platform container
- The TLS handshake hangs until App Platform's 31-second connection timeout kills it

**Fix:** Use the `databases:` block with `production: true` + `cluster_name`, and reference `${db.DATABASE_URL}` in your envs instead:

```yaml
envs:
  - key: DATABASE_URL
    scope: RUN_AND_BUILD_TIME
    value: ${db.DATABASE_URL}   # not a SECRET — this is a variable reference

databases:
  - name: db
    engine: PG
    version: "16"
    production: true
    cluster_name: <PROJECT_NAME>-db
```

**Confirm the fix:** `doctl apps spec get <app-id>` should show `DATABASE_URL` at the app level with no hardcoded `value:` pointing at `private-...`. The live spec should use the `${db.DATABASE_URL}` reference.

## 1-second exit after drizzle "already exists" notices

**Symptom:** drizzle-kit dies at the spinner with `non-zero exit code: 1`, no SQL error text, no stack trace. Logs show the two `42P06` / `42P07` "schema drizzle already exists, skipping" notices, then immediate failure.

**Cause:** the dedicated DB user has DML grants but doesn't own the tables — `ALTER TABLE` is owner-only in Postgres, and `postgres-js` swallows the permission-denied message before drizzle-kit can surface it. Tables ended up doadmin-owned because a migration was once run as doadmin (manual local apply or hot-fix script).

**Confirm:** add your IP to the cluster firewall and connect as doadmin:

```sql
SELECT tableowner FROM pg_tables WHERE schemaname='public';
```

If owners are `doadmin` rather than the dedicated user, that's the drift.

**Fix:** run the ownership-transfer DO-block from `docs/deployment/first-deploy.md` → "First deploy" → GRANT section (the `ALTER TABLE ... OWNER TO ...` loop). It's idempotent. Then trigger a fresh deploy — the next db-migrate logs `[✓] migrations applied successfully!`.

**Prevention:** never run `pnpm db:migrate` from a developer machine against the prod or staging `DATABASE_URL`. Migrations belong on the pre-deploy `db-migrate` job only.

## Heroku buildpack failure on db-migrate

**Symptom:** Build fails on the `db-migrate` job with "Failed to collect page data for /dashboard", "ELIFECYCLE Command failed with exit code 1", and a trailing footer "Love, Heroku". The job never reaches the `run_command`.

**Cause:** The `db-migrate` job has no `dockerfile_path`. DO falls back to the Heroku Node buildpack, which runs `pnpm build` on every Node project by default. Next.js build tries to collect page data for static routes and crashes — because `db-migrate` doesn't need a Next.js build, but Heroku's buildpack doesn't know that.

**Fix:** Add `dockerfile_path: docker/Dockerfile.worker` to the db-migrate job:

```yaml
jobs:
  - name: db-migrate
    github:
      repo: fractionwork/<PROJECT_NAME>
      branch: main
    dockerfile_path: docker/Dockerfile.worker   # ← this
    kind: PRE_DEPLOY
    run_command: sh scripts/predeploy.sh
    instance_size_slug: basic-xxs
```

The worker Dockerfile installs all deps (including drizzle-kit + tsx) and is the right base for migration + seed commands — no Next.js build involved. `scripts/predeploy.sh` runs `drizzle-kit migrate` then the project's idempotent reference-data seed (`lib/db/seed.ts`) inside a real shell — see the next symptom for why it can't be inlined as `cmd1 && cmd2`.

## DATABASE_URL not found at runtime

**Symptom:** `db-migrate` reaches `npx drizzle-kit migrate`, prints "DATABASE_URL not found" (from `drizzle.config.ts`), and exits.

**Cause:** `DATABASE_URL` was declared per-component (e.g. only on `web`) instead of at the app level. The dashboard value only attached to the web component; the db-migrate job's env was empty.

**Fix:** Move shared env vars to the top-level `envs:` block in `app.yaml` so every component inherits them:

```yaml
envs:
  - key: DATABASE_URL
    scope: RUN_AND_BUILD_TIME
    value: ${db.DATABASE_URL}
  - key: REDIS_URL
    scope: RUN_AND_BUILD_TIME
    value: ${valkey.DATABASE_URL}
  - key: BETTER_AUTH_SECRET
    scope: RUN_TIME
    type: SECRET
  - key: BETTER_AUTH_URL
    scope: RUN_TIME
  - key: NEXT_PUBLIC_APP_URL
    scope: RUN_AND_BUILD_TIME
```

Per-component envs are only for genuinely scoped secrets (e.g. `RESEND_API_KEY` on the worker).

## GitHub user not authenticated

**Symptom:** `doctl apps create --spec app.yaml` fails with HTTP 400 and "GitHub user not authenticated" (or similar) from the DO API. The user is definitely authed with `gh` locally, and `doctl auth init` completed successfully.

**Cause:** DO ↔ GitHub OAuth has not been granted at the **organization** level. Personal authorization is not enough — DO needs an explicit org grant to read the repo.

**Fix:** One-time per GitHub org:

1. Visit https://cloud.digitalocean.com/apps
2. Click "Create App" (you won't finish — just need the flow)
3. Select "GitHub" as the source
4. Click "Manage Access"
5. Find the org in the list and grant DigitalOcean access

Then retry `doctl apps create`. No changes needed on your end.

## Maximum clusters reached

**Symptom:** `doctl databases create` fails with HTTP 412 "maximum clusters reached". Account is at the default cap (~10 managed-DB clusters).

**Fix:** Either delete unused clusters (carefully) or request a limit increase.

To identify deletion candidates:

```bash
doctl databases list --format ID,Name,Engine,Size,Status

# Clusters with empty firewall rules almost always have no live consumers
for id in $(doctl databases list --format ID --no-header); do
  NAME=$(doctl databases get "$id" --format Name --no-header)
  FW=$(doctl databases firewalls list "$id" --format UUID --no-header | wc -l)
  echo "$id  $NAME  firewall_entries=$FW"
done
```

**DO NOT** delete clusters in unfamiliar projects without explicit owner approval. A project name like "Sunset Resources" can mean "resources to be sunset" (a graveyard) but it might also hold live data for a slow-moving product. When in doubt, ask — and prefer opening a DO support ticket for a limit increase over guessing wrong.

```bash
# Support ticket route (slower but safer)
# https://cloud.digitalocean.com/support/tickets/new
# Request: raise managed database cluster limit from 10 to 20 (or your target)
```

## next build fails with "Cannot find module '/app/scripts/...'" during pnpm install

**Symptom:** `docker build` (and DO's auto-build) aborts during the `deps` stage with `Error: Cannot find module '/app/scripts/<some-file>'` and `ELIFECYCLE Command failed with exit code 1`.

**Cause:** The Dockerfile's `deps` stage triggers `package.json`'s `prepare` (or any other lifecycle) script during `pnpm install`, but the script file isn't COPY'd into the image yet — only `package.json` + `pnpm-lock.yaml` are present at that layer.

**Fix:** Add `--ignore-scripts` to the install command in **both** `docker/Dockerfile` and `docker/Dockerfile.worker`:

```dockerfile
RUN corepack enable pnpm && pnpm install --frozen-lockfile --ignore-scripts
```

Lifecycle scripts are a dev-environment concern; production images don't need them. If a direct dep genuinely requires its own postinstall (native bindings via node-gyp etc.), allowlist it explicitly rather than dropping `--ignore-scripts` wholesale.

## App loads but client-side fetches go to undefined/api/...

**Symptom:** The deploy succeeds. Pages render. But browser-side requests hit `https://undefined/api/...`, Better Auth callbacks fail silently, or `console.log(env.NEXT_PUBLIC_*)` in a client component prints `undefined`.

**Cause:** The client bundle was built with `NEXT_PUBLIC_*` env vars undefined. `NEXT_PUBLIC_*` gets inlined at `next build` time, not resolved at runtime. DO passes `BUILD_TIME`-scoped vars to `docker build` as `--build-arg`, but the Dockerfile must declare each one as `ARG` (to receive it) and `ENV` (to expose it to `next build`).

**Fix:** In `docker/Dockerfile` builder stage, add a matching pair for every `NEXT_PUBLIC_*` declared in `lib/env.ts`:

```dockerfile
ARG NEXT_PUBLIC_APP_URL
ENV NEXT_PUBLIC_APP_URL=$NEXT_PUBLIC_APP_URL
```

Then push and force a rebuild — regular auto-deploy may use a cached image:

```bash
doctl apps create-deployment <app-id> --force-rebuild
```

**Verification:** locally, `SKIP_ENV_VALIDATION=1 NEXT_PUBLIC_APP_URL=https://test.example.com pnpm build` then `grep -r "test.example.com" .next/standalone` should find hits in the compiled chunks. If no hits, the ARG/ENV pair is missing.

## Build fails with "REDIS_URL is required" during page-data collection

**Symptom:** `next build` aborts with `Error: REDIS_URL is required at lib/jobs/connection.ts:N` during the page-data collection phase. Locally the build works (because you have `REDIS_URL` set); on DO it fails.

**Cause:** A queue export in `lib/jobs/queues.ts` is calling `getRedisConnection()` at module-eval time. When any client code transitively imports a queue (e.g. `/dashboard` → segment helper → `segmentQueue`), `next build`'s page-data collector tries to open Redis. But DO bindings only resolve at `RUN_TIME` — at `BUILD_TIME` `process.env.REDIS_URL` is undefined regardless of the binding's `scope`.

**Fix:** Wrap each queue export in a `lazyQueue` Proxy that defers `createQueue` until first property access. The seed's `lib/jobs/queues.ts` shows the pattern:

```ts
function lazyQueue(name: string): Queue {
  let real: Queue | null = null;
  return new Proxy({} as Queue, {
    get(_target, prop, receiver) {
      if (!real) real = createQueue(name);
      const value = Reflect.get(real, prop, receiver);
      return typeof value === "function" ? value.bind(real) : value;
    },
  });
}

export const emailQueue = lazyQueue("email");
```

Call sites unchanged — `emailQueue.add(...)` works identically.

**Verification:** `unset REDIS_URL && SKIP_ENV_VALIDATION=1 pnpm build` should succeed without hitting any "REDIS_URL is required" path.

## Deploy succeeds but admin-UI edits to certain rows keep reverting

**Symptom:** A user edits a row through the admin UI (district manager name, forecast ratio, role permissions, etc.). The next deploy silently reverts the edit. They edit it again. Same thing happens on the next deploy. Repeat until somebody notices the pattern.

**Cause:** The seed (`lib/db/seed.ts`) is using `onConflictDoUpdate` somewhere. The pre-deploy job runs `npx drizzle-kit migrate && npx tsx lib/db/seed.ts` on every deploy, and the upsert overwrites whatever the admin UI changed since the last run.

**Fix:** Switch the offending insert to `onConflictDoNothing`:

```typescript
// ✗ wrong — reverts admin edits on every deploy
await db.insert(role).values(rows).onConflictDoUpdate({
  target: [role.name],
  set: { permissions: sql`excluded.permissions` },
});

// ✓ right — additive only, leaves edited rows alone
await db.insert(role).values(rows).onConflictDoNothing({
  target: [role.name],
});
```

If you genuinely need to push a value change from code, ship a Drizzle migration with an explicit `UPDATE ... WHERE ...` clause instead of relying on seed re-runs. The migration runs once, is audited via the migrations history, and runs before the seed.

**Diagnosis:** `git grep -n onConflictDoUpdate lib/db/seed.ts` — every match is a bug under this convention.

## Pre-deploy job errors with `Unrecognized options for command 'migrate': &&, npx, ...`

**Symptom:** The pre-deploy job fails immediately with a message like `Unrecognized options for command 'migrate': &&, npx, tsx, lib/db/seed.ts` (or any variant where the literal `&&` appears as a positional arg to drizzle-kit).

**Cause:** DO App Platform's `run_command:` is **NOT** shell-evaluated. It splits on whitespace and `exec`s the first token directly. So `cmd1 && cmd2` doesn't chain — the literal `&&` gets passed as an argument to `cmd1`.

**Fix:** Use a wrapper shell script. The seed ships `scripts/predeploy.sh` for exactly this; the AppSpecs invoke it via `run_command: sh scripts/predeploy.sh`. The script handles chaining inside a real shell with `set -e`:

```sh
#!/usr/bin/env sh
set -e
echo "▶ Running database migrations..."
npx drizzle-kit migrate
echo "▶ Running database seed..."
npx tsx lib/db/seed.ts
echo "✓ Pre-deploy complete (migrate + seed)"
```

If your project's `app.yaml` / `app.staging.yaml` still has `run_command: npx drizzle-kit migrate && npx tsx lib/db/seed.ts`, switch it to `run_command: sh scripts/predeploy.sh`. Note the **two-step ship sequence**: the script must be in the deployed image *before* the live spec flips to it. Order: (1) merge the PR adding `predeploy.sh` so the next auto-deploy lands the file in the image, (2) `doctl apps update --spec app.yaml` to flip the live spec, (3) the next deploy actually exercises the script.

---

*Patterns confirmed during an Example_1 prod bring-up, 2026-04, plus the SpinXpress staging hotfix triple, 2026-04-30 / 05-01, the seed-upsert-reverts-edits incident, 2026-05-01, and the run_command exec-form discovery, 2026-05-01.*
