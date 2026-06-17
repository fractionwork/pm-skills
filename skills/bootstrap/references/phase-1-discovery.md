# Phase 1 — Discovery + architecture (single flow)

Discovery and architecture review run as one continuous conversation. Each step asks what's needed, then **immediately shows what those answers produce** (schema, routes, queues). The builder reviews real output at every step. By the final "Generate?" gate, there's nothing left to re-review.

**AskUserQuestion visibility:** always output questions and options as regular text first (readable on any terminal), then call AskUserQuestion as the interactive picker. The builder can answer via either.

If the builder provides a spec or PRD, acknowledge what it covers rather than re-asking. But confirm every architectural decision — specs omit multi-tenancy, auth, async, observability, and aesthetics.

Do NOT ask about tech stack, hosting, or architecture — those are decided.

### Step 1: Open

Read whatever the builder provided. Respond with:
- **What I'm hearing** — 2-3 sentences
- **Feature map** — bulleted guess at major features
- **Stack conflicts** — flag any tech that differs from DevHawk

Then AskUserQuestion (2 questions):
- header: "User type" — Internal tool / B2B SaaS / Consumer / Marketplace
- header: "Multi-tenant" — Yes (orgId on all tables) / No / Not sure

Follow up: *"Walk me through the main thing a user does — 3-5 steps."*

### Step 2: Data model + auth

From the workflow, **derive and show the schema**:

> | File | Table | Key fields | Relations |
> |------|-------|------------|-----------|
> | `product.ts` | `product` | name, price, active | → org, → user |
> | `order.ts` | `order` | status, total | → org, → product |
> | *(seed auth tables: user, session, account, org, member)* |

Then AskUserQuestion (2 questions):
- header: "Schema" — Looks good / Change / Add table
- header: "Auth" (multiSelect) — Email+pw / Google / SSO / 2FA

The builder sees concrete tables immediately after describing their workflow.

### Step 3: Server surface + integrations

From the schema, **derive and show actions + routes**:

> **Actions:** `createProduct`, `updateOrder`, `inviteMember`
> **Routes:** `/api/webhooks/stripe`, `/api/auth/[...all]`, `/api/bootstrap`
> **Protected:** `/dashboard/*`

Then AskUserQuestion (2 questions):
- header: "Server" — Looks good / Change / Go back
- header: "Integrations" (multiSelect) — Stripe / Resend / Other / None

### Step 4: Async + AI

From integrations + workflow, **derive and show queues**:

> **Queues:** `email` → transactional, `webhook` → Stripe events
> **AI:** none *(or: Anthropic, chat pattern, streamed)*

Then AskUserQuestion (2 questions):
- header: "Async" — Looks good / Change / Go back
- header: "AI" — None / Chat / Analysis / Agent

### Step 5: Infrastructure

Most answers follow from earlier choices. Show the derived plan:

> **Envs:** prod + staging shared ($60/mo)
> **Compute:** web basic-xs · worker basic-xxs · migrate basic-xxs
> **Clusters:** PG `[slug]-db` · Valkey `[slug]-valkey` · nyc3
> **PG users:** `[slug]_prod` → defaultdb · `[slug]_staging` → `[slug]_staging`
> **Branches:** main=prod · develop=staging
> **Local:** PG :[port] · Valkey :[port] · compose: `[slug]`
> **Observability:** no
> **DO Project:** `[ProductName]`

AskUserQuestion (1 question):
- header: "Infra" — Looks good / Change / Go back

### Step 6: UX direction

AskUserQuestion (3 questions):
- header: "Aesthetic" — Minimal / Refined / Playful / Industrial (Other for rest)
- header: "Dark mode" — Light / Dark / Both
- header: "Nav" — Sidebar / Top nav

Follow up: *"Colors? Fonts? (describe, hex, or 'pick for me')"*

### Step 7: Scope + generate

Show the full summary — every section assembled. No new information; everything was already approved as it was derived:

> **[Name]** — [one-liner] · `[slug]` · `[ProductName]`
> **Users:** [roles] · **Multi-tenant:** yes/no · **Auth variant:** org/solo · **Auth:** [list]
> **Schema:** [N] tables · **Actions:** [N] · **Routes:** [N]
> **Queues:** [list] · **AI:** [summary] · **Services:** [list]
> **Infra:** [env choice] · **UX:** [vibe], [fonts], [colors]
> **MVP:** [items] · **v2:** [deferred items]

AskUserQuestion (1 question):
- header: "Generate" — Generate scaffold / Move scope / Change something / Go back

"Generate scaffold" → Phase 2 starts.
