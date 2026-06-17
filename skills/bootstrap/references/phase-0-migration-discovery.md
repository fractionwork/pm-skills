# Phase 0 — Migration discovery *(existing apps only)*

Run this phase **before Phase 1** when the builder is porting an existing application onto the DevHawk stack. Skip it entirely for greenfield projects.

**Guiding principle (state this verbatim to the builder at the top of Phase 0):**

> Use as much of the target architecture as practical, but don't force-fit. A partial adoption that keeps a working component is better than a full rewrite that introduces risk for no gain. The goal is a balanced assessment — make the tradeoffs explicit and let the builder choose.

This phase is *advisory*. Its output is (a) a chosen migration shape that scopes the rest of bootstrap, and (b) a `MIGRATION.md` checklist committed to the new repo.

### When to run Phase 0

**Explicit triggers** — run unconditionally if the builder uses any of:
- "migrate", "port", "move onto the stack", "rehost", "lift onto DevHawk"
- Passes a path or repo URL to existing code with the bootstrap invocation (e.g. `/bootstrap migrate ~/Projects/oldapp`)
- "we already have an app"

**Auto-detect** — at the start of bootstrap, before Phase 1:
1. If `cwd` is the seed repo (clean, on `main`, no addendum to CLAUDE.md beyond seed default) → greenfield, skip Phase 0.
2. If the builder mentions a different cwd or repo path with existing commits / non-seed files / a `package.json` whose name isn't `devhawk-seed` → ask:
   > "I see existing code at `<path>`. Are you (a) porting this onto the DevHawk stack, or (b) starting greenfield and the path is incidental?"
   - (a) → run Phase 0
   - (b) → skip to Phase 1

Never assume; the auto-detect prompt is cheap and the cost of a missed migration framing is high.

### Step 0.1: Inventory

Read the source. Build a **comprehensive picture** before recommending anything. Required reads at minimum:

| Artifact | What you're learning |
|---|---|
| `README.md`, top-level docs | Stated purpose, deploy target, ops notes |
| `package.json` / `pyproject.toml` / `Gemfile` / `go.mod` | Language, framework, runtime version, dependencies |
| Dockerfile(s), `docker-compose*.yml` | Container shape, services, ports |
| `vercel.json`, `render.yaml`, `app.yaml`, `fly.toml`, `serverless.yml`, terraform/ | Current hosting config |
| `.env.example`, env loaders | External services + secrets surface |
| `prisma/schema.prisma`, `db/schema.rb`, `migrations/`, model files | Data model + ORM |
| Auth code (NextAuth, Devise, custom JWT, Clerk, Auth0, Cognito) | Auth shape, multi-tenancy, session strategy |
| Background-job code (Sidekiq, Celery, BullMQ, Resque, RQ, cron) | Async pattern, queue infra |
| `tests/` size + style | Coverage maturity, framework |
| CI config | Quality gates, deploy mechanism |

Spawn the **Explore** agent for any nontrivial codebase — it's faster and protects context. Report back with a one-page **Current Architecture** summary covering: language/framework, DB, hosting, auth, async, integrations, traffic/data scale (ask if not derivable), and prod-vs-pre-launch status.

### Step 0.2: Constraint capture

Ask the builder these explicitly — code can't tell you:

1. **Production state** — "Are there real users on this today, or is this pre-launch?" (Drives risk tolerance.)
2. **Compliance / contractual hosting** — "Anything that requires a specific cloud, region, or data-residency boundary?"
3. **Services that won't move** — "Any external services we're keeping as-is regardless of stack? (existing managed Postgres elsewhere, ML/Python services, third-party APIs you don't control)"
4. **Traffic / scale** — "Rough request rate, DB size, peak concurrency? Anything that changes the DO sizing math?"
5. **Timeline pressure** — "Is there a deadline that forces a minimum-viable migration over a clean one?"

Record answers verbatim — they shape the recommendation table.

### Step 0.3: Fit assessment table

Produce a per-layer table. Each row gets one of: **Adopt** (move to target), **Keep** (leave on current infra), **Hybrid** (run both during migration), **Rewrite** (no incremental path). Each cell needs a one-line *why*.

```
Layer          | Current             | Target              | Recommendation     | Reason
---------------+---------------------+---------------------+--------------------+----------------------------------
Framework      | Rails 7             | Next.js 16          | Adopt              | Greenfield rewrite acceptable; small surface
Database       | RDS Postgres 14     | DO Managed PG 16    | Keep (initial)     | Live data + pgvector indexes; migrate after stack stabilizes
Auth           | Devise              | Better Auth         | Adopt              | Sessions invalidate cleanly at cutover; user table maps 1:1
Background     | Sidekiq             | BullMQ              | Adopt              | Job catalog small (4 workers); rewrite cost < dual-stack cost
ML inference   | Python FastAPI svc  | —                   | Keep               | Don't force Node; expose as internal HTTP, called from BullMQ
Email          | Resend              | Resend              | Keep               | Already on the target's preferred provider
File storage   | S3                  | DO Spaces           | Hybrid → Adopt     | Migrate bucket-by-bucket post-cutover; egress cost is the only driver
Frontend       | React + Vite        | Next.js 16 App Rtr  | Rewrite            | App Router is opinionated; partial port creates two routing layers
```

The exact rows depend on the inventory. The discipline is: **don't recommend "Adopt" by default**. For each layer, justify why the move pays for itself. If you can't justify it, the answer is Keep or Hybrid.

### Step 0.4: Three options with tradeoffs

Always present three migration shapes so the builder picks consciously:

**Option A — Full migration** *(every Adopt row, all at once)*
- Pros: clean target architecture from day one, no dual-stack maintenance, consistent ops surface
- Cons: longest critical path, highest risk, biggest cutover, all bugs surface together
- Best for: pre-launch apps, apps with low traffic, teams with capacity for a focused rewrite

**Option B — Strangler-fig hybrid** *(adopt incrementally; route some traffic to new, some to old)*
- Pros: risk-bounded per slice, real users validate each step, can pause/rollback per slice
- Cons: dual-stack overhead during migration, routing layer complexity, possible data sync glue
- Best for: live apps with users, large surface area, teams that can't afford a freeze

**Option C — Minimal lift** *(rehost on DO App Platform; keep most of the existing stack)*
- Pros: fastest path to "on DO," lowest disruption, still lets you adopt secrets + IaC + staging patterns
- Cons: limited benefit from target architecture (less Better Auth/BullMQ/Drizzle leverage), may need a second migration later
- Best for: apps where the *hosting* was the pain point, not the stack itself

For each option, name **what's deliberately not adopted** and why — this is the balanced-assessment line. State it explicitly so the builder isn't surprised later.

After presenting, AskUserQuestion:
- header: "Migration shape"
- options: "A — Full migration", "B — Strangler-fig hybrid", "C — Minimal lift", "Custom (describe)"

### Step 0.5: Output → feeds Phase 1 + writes MIGRATION.md

The chosen shape **scopes the rest of bootstrap**:

- **Option A** → Phase 1 runs as if greenfield, but data-model step is informed by current schema (offer to translate the existing schema into Drizzle).
- **Option B** → Phase 1 covers only the *first slice*. Schema, routes, and queues are limited to what's being moved first. The rest gets a "future slice" note in MIGRATION.md.
- **Option C** → Skip most of Phase 1's scaffold work. Generate `app.yaml` against the *current* runtime (Dockerfile-based service), set up secrets workflow + staging + branch protection, and produce a much shorter scaffold. Most of the seed's auth/queues/Drizzle scaffolding is **not** generated.

Write `MIGRATION.md` at the new repo root with:

```markdown
# Migration plan

**Source:** <path or repo>
**Shape chosen:** <A | B | C | Custom>
**Date:** <today>

## Current architecture (as inventoried)
<one-page summary from Step 0.1>

## Constraints
<from Step 0.2>

## Fit table
<from Step 0.3>

## Migration slices (in order)
<for Option B: the slice list, each with: scope, success criteria, rollback plan>
<for Option A: the cutover checklist>
<for Option C: the rehost checklist + deferred-adoption list>

## What we deliberately did NOT adopt
<from Step 0.4 — make this list explicit so future maintainers know it was a conscious choice, not an oversight>

## Open questions
<anything the builder couldn't answer in Step 0.2>
```

Phase 1 picks up from here with the chosen shape baked in.

### Phase 0 anti-patterns (refuse these)

- **"Just port everything to the target"** — without a fit-table justification, this is a rewrite disguised as a migration.
- **Adopting BullMQ for an app with three cron jobs and no async work** — the seed's async surface only pays for itself when there's real async work. A `pg_cron` row or a single DO scheduled Job is often enough.
- **Adopting Better Auth on top of an existing identity provider that already works (Auth0, Clerk, Cognito)** — only swap if there's a concrete reason ($, lock-in, missing feature). Otherwise add an adapter and Keep.
- **Migrating a healthy production Postgres "because the seed uses DO Managed PG"** — keep it where it is. The `databases:` binding is for new clusters; for an external DB use a `${EXTERNAL_DATABASE_URL}` secret.
- **Skipping Step 0.2 constraint capture** — every "we should have asked" failure mode in migrations starts here.
