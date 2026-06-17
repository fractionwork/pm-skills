---
name: feature-build
profiles: [engineer]
description: >
  Guides implementation of a feature or user story on a DevHawk project.
  Use when building a specific feature, implementing a story from the backlog,
  or adding new functionality. Triggers on phrases like "build [feature]",
  "implement [story]", "add [capability]", "work on E2-S3", or any request
  to implement application functionality. Ensures code follows stack conventions
  and includes tests.
requires_tools: [pnpm, node, git]
---

# Feature Build Guide

You are implementing a feature on a DevHawk stack project. Before writing any code:

1. Read `docs/conventions.md` (if not already loaded)
2. Identify which reference docs are relevant to this feature
3. Plan the implementation, then execute

### PM card awareness

Check for `.devhawk-work.json` in the project root. If it exists with an active card:
- Note the card ID, PM system, and card URL
- **After each git commit**, post a comment on the PM card with the commit message + key files changed:
  - **Asana:** `add_comment(task_id, text: "Commit: [message]\nFiles: [list]")`
  - **Jira:** `addCommentToJiraIssue(issueIdOrKey, commentBody: "Commit: [message]\nFiles: [list]")`
  - **Shortcut:** `POST /stories/{id}/comments` with `text: "Commit: [message]\nFiles: [list]"` (via REST or MCP)
- If `.devhawk-work.json` doesn't exist, skip PM updates silently — the skill works without it

## Implementation checklist

For every feature, work through these in order:

### 1. Schema (if new data)
- [ ] Define table in `lib/db/schema/[domain].ts`
- [ ] **Org variant:** include `organizationId` if tenant-scoped (most app tables). **Solo variant:** no `organizationId` — see `**Auth variant:**` in CLAUDE.md.
- [ ] Export from `lib/db/schema/index.ts`
- [ ] Create Zod validation schemas with `drizzle-zod`
- [ ] Run `pnpm db:generate` to create migration
- [ ] Review generated SQL migration file
- [ ] Run `pnpm db:migrate` to apply locally
- Reference: docs/database-patterns.md

#### Seed-data convention

If your feature requires reference data (a new role, a new system property, a new pipeline status, default ratios, etc.), add it to `lib/db/seed.ts` using `onConflictDoNothing` against an explicit unique target. **Never use `onConflictDoUpdate`** — the seed runs on every deploy via the pre-deploy job (`drizzle-kit migrate && tsx lib/db/seed.ts`) against prod databases that have been edited via admin UIs. An upsert silently reverts those edits on every deploy.

```typescript
// ✓ additive — leaves admin-UI-edited rows alone
await db.insert(role).values(rows).onConflictDoNothing({
  target: [role.name],
});

// ✗ reverts admin edits on every deploy — never do this in seed.ts
// .onConflictDoUpdate({ target: [...], set: {...} })
```

To change a default value in code, ship a Drizzle migration with an explicit `UPDATE ... WHERE ...` clause. The migration is one-shot, audited via the migrations history, and runs before the seed. If you genuinely need a one-off backfill, write a separate script (e.g. `scripts/backfill-foo.ts`) and run it manually via `doctl apps console` — don't put it in `seed.ts`.

### 2. Server logic
- [ ] Server Actions for user-triggered mutations
- [ ] Return `{ success, error?, data? }` — never throw
- [ ] Validate ALL input with Zod schemas
- [ ] Check session before any data access. **Org variant:** also check `session.session.activeOrganizationId` and filter queries by it. **Solo variant:** check `session.user.role` for admin-gated mutations.
- [ ] API routes only for webhooks or external consumers
- Reference: docs/conventions.md

### 3. Background jobs (if async work)
- [ ] Add queue in `lib/jobs/queues.ts`
- [ ] Create processor in `lib/jobs/processors/`
- [ ] Register worker in `lib/jobs/worker.ts`
- [ ] Enqueue from Server Action or API route
- Reference: docs/background-jobs.md

### 4. UI
- [ ] Server Component by default (data fetching happens here)
- [ ] Client Component only when hooks or event handlers needed
- [ ] Use shadcn/ui primitives from `components/ui/` as foundation
- [ ] Match the project's established aesthetic direction (check `globals.css` theme and existing pages for the design language)
- [ ] Forms use `useActionState` + Server Action
- [ ] Show loading states with Suspense boundaries
- [ ] Add purposeful transitions for state changes (avoid gratuitous animation)
- Use the `frontend-design` skill for pages or components that are user-facing and visually significant
- Reference: docs/conventions.md (UI design principles section)

### 5. Auth (if role-based or protected)
- [ ] Session check in Server Component or Server Action
- [ ] **Org variant:** organization check for tenant-scoped features. **Solo variant:** role check (`session.user.role === "admin"`) for admin-gated features.
- [ ] Middleware route protection if entire route group is protected
- Reference: docs/auth-patterns.md

### 6. Tests (mandatory)

Invoke the `test-gen` skill to generate tests for the code written in Steps 1-5. Do NOT skip this step or leave it as empty stubs.

`test-gen` reads the diff, categorizes changes, and generates:
- **Unit tests** for new schemas, validators, pure logic
- **Integration tests** for new Server Actions, DB queries
- **E2E tests** for critical user flows (auth, core workflow, payment — not every page)

After test-gen completes, verify:
- [ ] `pnpm test:run` passes (unit + integration)
- [ ] `pnpm test:e2e` passes (if E2E specs were generated)
- Reference: docs/testing-patterns.md

### 7. Verify
- [ ] `pnpm typecheck` passes
- [ ] `pnpm lint` passes
- [ ] `pnpm test:run` passes
- [ ] Feature works in browser (`pnpm dev`)
- [ ] Run `pr-review` against the feature branch — lint, code review at 75% confidence, fix findings, PR comments posted automatically

## Common patterns

### Adding a CRUD feature
1. Schema → migration → Zod schemas
2. Server Actions: create, update, delete (each validates input, checks auth)
3. Server Component: list page with data fetching
4. Client Component: form with `useActionState`
5. Tests: schema validation, CRUD operations, E2E flow

### Adding an AI feature
1. Define tools with Zod parameter schemas in `lib/ai/`
2. Create chat route handler or Server Action
3. For long-running: enqueue via BullMQ, show progress
4. Client: `useChat()` hook or custom streaming UI
5. Reference: docs/ai-patterns.md

### Adding a webhook handler
1. API route in `app/api/webhooks/[service]/route.ts`
2. Verify webhook signature (Stripe: `stripe.webhooks.constructEvent`)
3. Enqueue processing via BullMQ (don't do heavy work in the handler)
4. Return 200 immediately
5. BullMQ processor handles the actual work with retries
