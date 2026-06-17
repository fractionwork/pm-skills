# Phase 2 — Scaffold generation

After confirmation, generate the following ON TOP of the existing seed repo files.

Read docs/conventions.md before generating any code.

### Docker isolation (`docker/docker-compose.dev.yml`, `.env.local`)

Each project MUST have unique Docker resource names so multiple projects can run simultaneously. Update `docker/docker-compose.dev.yml`:

1. Add `name: [project-name]` at the top level (Compose project name — prefixes all containers and networks)
2. Change `POSTGRES_DB`, `POSTGRES_USER` to use the project name (e.g., `rateiq` instead of `devhawk`)
3. Assign unique host ports to avoid collisions. Use a deterministic offset based on the project name so ports are stable across restarts. Pick from ranges: PG 5433-5499, Redis 6380-6499, OpenObserve 5081-5099. Example for a project:
   - PostgreSQL: `"5433:5432"`
   - Redis: `"6380:6379"`
   - OpenObserve (if enabled): `"5081:5080"`
4. Update the `healthcheck` test to use the new username

Then update `.env.local` and `.env.example` so `DATABASE_URL` and `REDIS_URL` reflect the new ports and credentials:
```
DATABASE_URL="postgresql://[project-name]:[project-name]_local@localhost:[pg-port]/[project-name]"
REDIS_URL="redis://localhost:[redis-port]"
```

Also update `drizzle.config.ts` default fallback if it hardcodes port 5432.

Update `package.json` name from the seed default to the project slug:
```bash
sed -i 's/"name": "devhawk-app"/"name": "[project-name]"/' package.json
```

### Theme and layout (`app/globals.css`, `app/layout.tsx`)

**Invoke the `frontend-design` skill with the UX direction from Phase 1's architecture review as explicit, structured input.** Do not let the skill re-derive or guess — hand it the approved values directly:

```
Invoke frontend-design with:
- Aesthetic direction: [approved vibe from architecture review]
- Display font: [font name + source: Google Fonts / local]
- Body font: [font name + source]
- Color palette: [dominant colors + sharp accents, as HSL]
- Light/dark/both: [decision]
- Nav pattern: [sidebar / top nav]
- Primary surfaces to restyle: globals.css @theme block, app/layout.tsx,
  app/(auth)/sign-in + sign-up, app/(dashboard)/layout.tsx
```

The goal is a distinctive, cohesive aesthetic — not a generic template. Read docs/conventions.md for UI design principles.

Handing the skill pre-decided inputs is the difference between a result that matches the builder's review-time intent and one that drifts mid-generation. If any of these values weren't captured during architecture review, go back and ask — don't proceed with "I'll pick".

Based on the UX direction from discovery:

- **Aesthetic direction:** Commit to the specific vibe the user described. If they said "luxury/refined," every detail should reinforce that — typography, spacing, color, motion. If they said "brutalist/raw," lean into it with confidence. Half-measures produce generic results.
- **Typography:** Choose a distinctive display font + complementary body font via `next/font/google` or `next/font/local`. Do NOT default to Inter — pick something that reinforces the aesthetic. Update the font variable in `layout.tsx`.
- **Color scheme:** Update CSS custom properties in `globals.css` `@theme` block. Use HSL values for all color tokens. Dominant colors with sharp accents — don't distribute colors timidly across the palette.
- **Dark mode:** If requested, add dark mode variants in `globals.css` under a `.dark` selector and add a theme toggle component. The seed includes `@variant dark (&:is(.dark *))` ready for this.
- **Navigation:** Based on preference (sidebar vs top nav), create the appropriate shell layout in `app/(dashboard)/layout.tsx`. Sidebar for data-heavy/dashboard apps, top nav for content/marketing-oriented apps.
- **Auth pages:** Restyle the sign-in/sign-up pages in `app/(auth)/` to match the chosen aesthetic. These are the first thing users see — they set the tone.
- **Motion:** Add purposeful transitions for page loads and state changes. One well-orchestrated entrance animation creates more delight than scattered micro-interactions.

If no strong preferences were expressed, keep the seed defaults but still choose a distinctive font. These can always be refined later.

### Database schema (`lib/db/schema/[domain].ts`)
- One file per domain (products.ts, orders.ts, etc.)
- Follow patterns in docs/database-patterns.md
- Include organizationId on all tenant-scoped tables
- Add export to `lib/db/schema/index.ts`
- Generate Zod validation schemas alongside each table

### Route stubs (`app/`)
- Page files with basic layout and placeholder content
- Route groups: `(auth)` for login/signup, `(dashboard)` for authenticated pages
- API routes only for webhooks and external consumers
- Loading and error boundary files for key routes

### Better Auth config updates (`lib/auth.ts`, `lib/auth-client.ts`, `lib/db/schema/auth.ts`)
- Activate required social providers (uncomment + add env vars to `.env.example`)
- Add required plugins (passkey, magicLink, stripe, apiKey, etc.)
- Update `lib/auth-client.ts` with matching client plugins

**If multi-tenant (organizations enabled) — the seed default:**
- Keep the `organization()` plugin in `lib/auth.ts` and `organizationClient()` in `lib/auth-client.ts`
- Keep `organization`, `member`, `invitation` tables in `lib/db/schema/auth.ts`
- Keep `activeOrganizationId` on the `session` table
- All app data tables MUST include `organizationId` column with a foreign key to `organization.id`
- All queries MUST filter by `session.session.activeOrganizationId`
- Add `**Auth variant:** org` to the project metadata block in `CLAUDE.md` so skills know the variant.

**If NOT multi-tenant — solo variant (admin plugin):**

Run the bootstrap-time switcher. It swaps the 5 auth-related files to the solo-auth templates the seed ships, generates the schema-diff migration, and updates the `CLAUDE.md` variant marker:

```bash
bash scripts/switch-to-solo-auth.sh
pnpm db:migrate   # apply the generated migration locally
```

The script is idempotent-fail: it refuses to run once you've generated migrations beyond the initial baseline, because the org → solo flip drops `organization` / `member` / `invitation` tables and you don't want that destructive on a live DB. For a project that wants to flip variants after going live, see `docs/auth-patterns.md` → "Switching variants after go-live".

What the swap gives you:
- `admin()` plugin instead of `organization()` (Better Auth admin plugin: global `role`, `banned`, `impersonateUser`, `setRole`, etc.)
- `user.role`, `user.banned`, `user.banReason`, `user.banExpires` columns instead of `organization`/`member`/`invitation` tables
- `/api/bootstrap` promotes the first signed-up user to `role="admin"` instead of creating a default org
- `lib/db/seed-core.ts` becomes a stub (no default-org row to seed)
- `**Auth variant:** solo` in the project metadata block

After the swap, do NOT add `organizationId` columns to app data tables, and do NOT apply the `organizationId`-filter rule from `CLAUDE.md`. See `docs/auth-patterns.md` → "Solo variant" for the full picture.

### BullMQ queue definitions (`lib/jobs/`)
- Add queue declarations in `queues.ts`
- Create processor files in `lib/jobs/processors/[queue-name].ts`
- Register workers in `worker.ts`

### AI agent definitions (`lib/ai/`)
- Tool definitions with Zod parameter schemas
- Agent configurations
- Chat route handler if needed

### Observability (if user opted in)

Only include this if the user said yes to observability during discovery. Skip entirely if they declined.

**Docker Compose** — Add OpenObserve to `docker/docker-compose.dev.yml`:
```yaml
openobserve:
  image: public.ecr.aws/zinclabs/openobserve:latest
  ports:
    - "5080:5080"
  environment:
    ZO_ROOT_USER_EMAIL: "dev@localhost"
    ZO_ROOT_USER_PASSWORD: "devhawk123"
    ZO_DATA_DIR: "/data"
  volumes:
    - openobserve_data:/data
```
Add `openobserve_data:` to the volumes section.

**Dependencies** — Add to `package.json`:
```
@opentelemetry/sdk-node
@opentelemetry/auto-instrumentations-node
@opentelemetry/exporter-trace-otlp-http
@opentelemetry/exporter-logs-otlp-http
@opentelemetry/api
pino
pino-opentelemetry-transport
```

**Instrumentation** — Create `app/instrumentation.ts` (Next.js auto-loads this):
```typescript
export async function register() {
  if (process.env.NEXT_RUNTIME === "nodejs") {
    await import("@/lib/telemetry");
  }
}
```

**Telemetry config** — Create `lib/telemetry.ts`:
- Initialize OpenTelemetry NodeSDK with auto-instrumentations
- OTLP trace exporter pointing at `OTEL_EXPORTER_OTLP_ENDPOINT` (default: `http://localhost:5080/api/default`)
- OTLP log exporter for structured logs
- Service name from `OTEL_SERVICE_NAME` env var

**Logger** — Create `lib/logger.ts`:
- Pino logger with `pino-opentelemetry-transport` for trace-correlated structured logs
- Export a `logger` instance used across Service and Worker
- In development, also log to stdout in pretty format

**Worker** — Update `lib/jobs/worker.ts` to import `@/lib/telemetry` at the top so OTel instruments the worker process.

**Environment** — Add to `.env.example`:
```
OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:5080/api/default"
OTEL_SERVICE_NAME="[project-name]"
```

**Dashboard access** — OpenObserve UI at `http://localhost:5080` with credentials `dev@localhost` / `devhawk123`.

### DO App Platform AppSpec (`app.yaml`, optional `app.staging.yaml`)

The seed ships with `app.yaml` (prod) and `app.staging.yaml` (staging-on-shared-clusters) using `<PROJECT_NAME>` placeholders. Sed-replace the placeholders with the project slug:

```bash
sed -i "s|<PROJECT_NAME>|[project-slug]|g" app.yaml app.staging.yaml
```

Both specs use `deploy_on_push: true` — DO App Platform clones the repo and deploys directly when a push lands on `main` (prod) or `develop` (staging). CI (`.github/workflows/ci.yml`) only runs `quality` + `test` and gates merges via GitHub branch protection — there is no GHA deploy job.

Then:
- **If multi-env:** leave both files in place.
- **If single-env:** delete `app.staging.yaml`. Do NOT leave dormant staging infrastructure declared — it's confusing and will bit-rot.

> ⚠️ **Adding a `NEXT_PUBLIC_*` env var?** Update `docker/Dockerfile`'s builder stage with a matching `ARG NEXT_PUBLIC_FOO` + `ENV NEXT_PUBLIC_FOO=$NEXT_PUBLIC_FOO` pair, or the client bundle will be built with `undefined` inlined. `NEXT_PUBLIC_*` is baked at `next build` time; runtime env-setting can't fix it after the fact. See `do-deploy/SKILL.md` Step 7.5 for the verification recipe.

#### After first deploy: sync the committed spec

DO returns encrypted `EV[...]` envelopes for every secret you set during bootstrap. Pull the live spec back into the committed YAML so the IaC reflects reality:

```bash
scripts/sync-app-spec.sh prod
# scripts/sync-app-spec.sh staging   # if you set up staging
git diff -- app.yaml app.staging.yaml
git commit -am "ops: bootstrap reconciliation — sync spec from DO"
```

The first sync after bootstrap usually has a large diff (the seed's placeholder values get replaced by live envelopes); subsequent diffs should be small. Without this step the spec-drift CI check fails on the next push. See `docs/secrets.md` for the full secret-management workflow.

#### After first deploy: configure branch protection

DO auto-deploys from `main` (prod) and `develop` (staging) via `deploy_on_push: true`. CI runs `quality` + `test` (gated behind the `changes` classifier) and reports a single aggregate `CI Gate` check, but does NOT gate the deploy by itself. To gate deploys on CI passing, configure GitHub branch protection to require **`CI Gate`** — once the `CI` workflow has run at least once on each branch (so the `CI Gate` name is registered).

Require `CI Gate` only, never `quality` / `test` directly: those jobs are path-skipped for docs-only changes, and a required check that is never reported reads to branch protection as *pending forever*, deadlocking docs-only PRs. See `docs/deployment/docker-ci.md` → "Branch protection (required gate)".

Run this — it applies protection and degrades gracefully when the plan doesn't support it (private repos on a Free plan return `403`), so bootstrap continues instead of aborting:

```bash
REPO="{owner}/{repo}"   # e.g. fractionwork/my-app

apply_branch_protection() {
  local branch="$1" out
  if out=$(gh api -X PUT "repos/$REPO/branches/$branch/protection" --input - 2>&1 <<'JSON'
{
  "required_status_checks": { "strict": false, "contexts": ["CI Gate"] },
  "enforce_admins": false,
  "required_pull_request_reviews": { "required_approving_review_count": 1, "dismiss_stale_reviews": true },
  "restrictions": null
}
JSON
  ); then
    echo "✓ branch protection set on $branch (requires CI Gate + 1 review; admins exempt)"
  elif printf '%s' "$out" | grep -qiE 'upgrade|403|not available'; then
    echo "⚠ branch protection unavailable on $branch — private repos on a Free plan return 403."
    echo "  CI still runs and reports CI Gate on every PR; it just isn't a hard merge gate."
    echo "  Enforcement layer here: the pre-push hook + 'pnpm pr:audit' (create-pr refuses BLOCKs) + pr-review/pr-watch."
    echo "  For a hard gate: keep the repo public (protection is free), or upgrade the org to Team."
  else
    echo "✗ branch protection failed on $branch: $out" >&2
    return 1
  fi
}

apply_branch_protection main
git show-ref --verify --quiet refs/remotes/origin/develop && apply_branch_protection develop
```

`enforce_admins: false` exempts repo admins so they can override-merge (incl. their own PRs — GitHub never lets an author satisfy their own required review; the exemption governs *merge*, not *approval*). Set it to `true` to bind admins too.

Without protection, anyone with merge access can push code that fails CI directly to the deploy branch and DO will deploy it. Branch protection is the durable gate where the plan supports it — the pre-push hook (`.githooks/pre-push`), `pnpm pr:audit`, and `pr-review`/`pr-watch` are the client-side guardrails that still apply on repos where it doesn't.

The seed's `lib/jobs/queues.ts` and `lib/jobs/worker.ts` already read `BULLMQ_PREFIX` from env (default `bull`). Staging overrides to `bull:staging` via `app.staging.yaml`. No scaffold action needed here — the pattern is baseline.

The DO Project (`<ProductName>`) and the managed PG + Valkey clusters are NOT created during scaffold. They're provisioned in Phase 4 via the `do-deploy` skill.

### Seed files (`lib/db/seed-core.ts` + `lib/db/seed.ts`)

The seed runs as the LAST step of the pre-deploy job (`drizzle-kit migrate && tsx lib/db/seed.ts`) on every deploy. Reference data — default org, roles, pipelines, default ratios, system property groups, etc. — lands on a fresh prod DB without a manual SSH step.

**The seed ships both files**; bootstrap doesn't need to create them. They split as follows:

| File | Owner | Synced by `update-seed-skills`? | Contents |
|---|---|---|---|
| `lib/db/seed-core.ts` | DevHawk seed | **Yes** — overwritten on every sync | Stack-baseline reference data (default org today; future: `app_registry`, baseline role shapes, etc.) Exported as `seedCore()`. |
| `lib/db/seed.ts` | Project | **No** — synced once at bootstrap, never touched after | Calls `seedCore()`, then project-specific inserts. Safe place for your additions. |

**Idempotency contract: every INSERT in either file must use `onConflictDoNothing`. Never `onConflictDoUpdate`.** Upserts silently revert admin-UI edits on every deploy. This is non-negotiable.

When a feature ships new reference data (a new role, a new pipeline status, a new default ratio), add it to `lib/db/seed.ts` after the `seedCore()` call:

```typescript
import { db } from "@/lib/db";
import { roleDefinition } from "@/lib/db/schema/role";
import { seedCore } from "./seed-core";

await seedCore();

await db
  .insert(roleDefinition)
  .values([{ name: "admin", permissions: [...] }])
  .onConflictDoNothing({ target: roleDefinition.name });
```

Drizzle gotcha: when conflict-targeting against a **partial** unique index, the parameter is `where`, not `targetWhere` (the latter is correct only for `onConflictDoUpdate`):

```typescript
.onConflictDoNothing({
  target: forecastRatioDefault.accountCode,
  where: sql`store_id IS NULL`,
})
```

### Test stubs (`tests/`)
- Vitest files with describe blocks matching features
- Playwright spec files for critical user flows
- Empty test bodies with TODO comments describing what to test

### CLAUDE.md addendum
Add a project-specific section at the TOP of CLAUDE.md (before the generic stack section):

```markdown
# [Project Name]

[One-liner description]

## Domain concepts
- [Entity]: [What it is, key fields]
- [Entity]: [What it is, relationships]

## Business rules
- [Rule that affects implementation]
- [Validation constraint]

## Build order (recommended)
1. [First epic — usually auth + core data model]
2. [Second epic — core workflow]
3. [Third epic — integrations]
4. [Fourth epic — polish + edge cases]
```

### Update README.md

Replace the seed repo README with a project-specific one. The README should include:

```markdown
# [Project Name]

[One-liner description]

## Architecture

[Keep the mermaid component diagram from the seed README but update labels if the project
adds queues, workers, or external services beyond the defaults]

## Local development

### Prerequisites
- Node.js 22+
- pnpm (via corepack)
- Docker (for PostgreSQL + Redis)

### Setup
\```bash
git clone git@github.com:fractionwork/[project-name].git
cd [project-name]
pnpm install
docker compose -f docker/docker-compose.dev.yml up -d
cp .env.example .env.local
# Edit .env.local with your values
pnpm db:generate
pnpm db:migrate
pnpm dev          # Starts PG + Redis + web + worker
\```

## Scripts
[Table of pnpm scripts from CLAUDE.md — dev, build, test, lint, typecheck, db:*, worker:*]

## Stack
[Stack table from seed README]

## Project structure
[Brief description of key directories and what lives where, based on the generated scaffold]
```

Remove all seed-specific content: the `/devhawk-new` workflow, "What's in the seed" section,
provisioning details, manual setup from seed instructions, and the install-global-command references.
The README should read as if this project was always its own thing.

### Post-scaffold review

After typecheck passes, run `/code-review` against the generated scaffold. The plugin's CLAUDE.md-compliance agent will catch convention drift in the generated code (missing `organizationId` on tenant tables, `any` types, mutation API routes that should be Server Actions, etc.). Address high-confidence findings before moving to Phase 3.

### Post-scaffold verification

After generating all files, this is where Docker starts for the first time — with the project-specific compose project, DB user, and port mappings already in place. `/devhawk-new` only pulled the images; it deliberately didn't start containers to avoid collisions with other seed-based projects. The `down` below is a defensive no-op in the normal flow; it only matters if the user manually started containers earlier.

```bash
docker compose -f docker/docker-compose.dev.yml down   # Defensive: tear down if any seed-default containers are somehow running
docker compose -f docker/docker-compose.dev.yml up -d   # First real start — project-specific names/ports
# Wait for PG to be ready with the new username
until docker compose -f docker/docker-compose.dev.yml exec postgres pg_isready -U [project-name] 2>/dev/null; do sleep 1; done
pnpm db:generate   # Generate migrations from new schema
pnpm db:migrate    # Apply to local database
pnpm typecheck     # Verify everything compiles
```

Fix any errors before proceeding.

> ⚠️ Never run `pnpm db:migrate` from a developer machine against the prod or staging `DATABASE_URL`. Migrations only run via the pre-deploy `db-migrate` job. Manual local applies create table-ownership drift (doadmin-owned tables → dedicated-user can't `ALTER` them) which silently breaks future migrations. See `docs/deployment/troubleshooting.md` → "Common failure modes" for recovery.
