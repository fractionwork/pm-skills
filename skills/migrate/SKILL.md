---
name: migrate
profiles: [engineer]
description: >
  Migrate an existing codebase to the DevHawk reference stack. Inspects the current
  stack, maps components to DevHawk equivalents, plans migration epics, then executes
  each epic immediately — committing at each boundary. This is replatforming, not
  scaffolding. Triggers on "migrate this app", "move to devhawk", "migration plan",
  "convert this codebase", "port this to our stack", "replatform", or any request to
  bring an existing application onto the DevHawk stack.
seed_managed: true
requires_tools: [gh, pnpm, node, git]
---

# DevHawk Migration

You migrate an existing codebase to the DevHawk stack. This is execution, not planning — you inspect, plan the epics, then implement each one in sequence, committing at every epic boundary.

Read before starting:
- docs/conventions.md — target patterns
- docs/architecture.md — target components
- docs/database-patterns.md — Drizzle schema
- docs/auth-patterns.md — Better Auth
- docs/background-jobs.md — BullMQ
- docs/deployment.md — Docker, DO App Platform

## Phase 1: Inspect

Analyze the existing project. Build a complete inventory:

| Layer | What to identify |
|-------|-----------------|
| Framework | React/Vue/Angular/Express, SPA/SSR/SSG, router type |
| Database | ORM, engine, schema location, table count, multi-tenancy |
| Auth | Provider, social logins, session strategy, roles, orgs |
| State | Client state lib, data fetching, real-time |
| Jobs | Queue system, cron, long-running tasks |
| UI | Component lib, CSS approach, theme system |
| AI | Providers, SDKs, patterns |
| Services | Payments, email, storage, third-party APIs |
| Infra | Hosting, CI/CD, Docker, env management |
| Tests | Framework, coverage, E2E |
| Health | TS/JS, strict mode, linting, package manager, size |

## Phase 2: Assessment

Present findings:

> **Current → Target**
> | Layer | Current | DevHawk target | Complexity |
> |-------|---------|----------------|------------|
> | Framework | [current] | Next.js 16 App Router | High/Med/Low |
> | Database | [current] | Drizzle + PG 16 | ... |
> | Auth | [current] | Better Auth | ... |
> | ... | ... | ... | ... |
>
> **Preservable:** [business logic, DB data, API contracts that transfer cleanly]
> **High-risk:** [areas that could break]
> **Epics:** [N] phases

AskUserQuestion — header: "Assess", question: "Assessment correct? Any priorities or constraints?", options: "Looks right" / "Change priorities" / "Skip a layer"

## Phase 3: Plan epics

Order:
1. **M1: Infrastructure** — Docker, CI/CD, env vars, DB connection
2. **M2: Data layer** — Drizzle schema from existing tables, migration scripts
3. **M3: Auth** — Better Auth, user migration, session strategy
4. **M4: App shell** — Next.js layout, nav, routing
5. **M5: Feature pages** — convert page by page, highest-traffic first
6. **M6: Background jobs** — BullMQ for existing async patterns
7. **M7: Cleanup** — remove old deps, dead code, legacy patterns

For each epic show:
> **M[N]: [Name]** — [goal, 1 line]
> Steps: [numbered list of concrete changes]
> Validates: [how to verify it works]

Present the full epic list. AskUserQuestion — header: "Plan", question: "Execute this plan?", options: "Execute all" / "Reorder" / "Skip an epic" / "Change something"

## Phase 4: Execute

For each epic, in order:

### 1. Announce
> Starting **M[N]: [Name]**. [step count] changes.

### 2. Implement
Execute every step in the epic: create files, convert schemas, rewrite components, update configs. Follow docs/conventions.md for all generated code.

**Data layer specifics (M2):**
- Generate Drizzle schema files from existing tables (DevHawk naming: snake_case singular)
- **Auth-variant decision (early in M1):** ask the user if the source app is multi-tenant (org variant) or single-tenant (solo variant). If solo, run `bash scripts/switch-to-solo-auth.sh` before generating schema. Org variant: include `organizationId` on tenant-scoped tables. Solo variant: no `organizationId` columns.
- Create Zod validation schemas with drizzle-zod
- Write a data migration script if engine is changing (pg_dump/restore if same PG)
- Handle FK relationships during cutover

**Auth specifics (M3):**
- Map existing users into Better Auth's user/account/session tables
- bcrypt hashes are portable; other algorithms → rehash on next login
- Reconfigure social login providers in lib/auth.ts
- Force re-login on cutover (simplest; parallel auth adds complexity)

**UI specifics (M5):**
- Server Components by default
- Use `frontend-design` skill for user-facing pages
- Match or improve existing aesthetics
- Use shadcn/ui primitives, Tailwind v4

### 3. Verify
```bash
pnpm typecheck
pnpm lint
pnpm test:run  # if tests exist
```
Fix any failures before committing.

### 4. Commit
```bash
git add -A
git commit -m "migrate(M[N]): [epic name]

[1-line summary of what changed]

Co-Authored-By: Claude Opus 4.6 (1M context) <noreply@anthropic.com>"
```

### 5. Report + continue
> **M[N] complete.** [summary]. Moving to M[N+1].

Continue to the next epic. Do NOT wait for approval between epics unless the builder interrupts (or auto-accept is off — see below).

## Interactive vs auto-accept

**Default (interactive):** pause after each epic's commit. Show what was done, ask "Continue to M[N+1]?"

**Auto-accept:** execute all epics in sequence without pausing. Stop only on failure.

## Guidelines

- **Preserve business logic.** Change the technical substrate, not the business rules.
- **Data is sacred.** Production data migration gets a dry-run against a copy first. Never touch prod data without explicit confirmation.
- **Each epic leaves the app working.** No intermediate broken states.
- **Feature parity before new features.** Achieve parity first. New features come after.
- **Commit at every epic boundary.** Progress is saved, reviewable, revertable.
- **Use `create-pr` when done.** After the final epic, offer to create a PR with all migration commits.
