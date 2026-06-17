---
name: stack-audit
profiles: [engineer]
description: >
  Two-layer audit: project code vs the seed's documented guidelines, AND those
  guidelines vs external best practice. Walks each finding with the operator
  (code drifts from docs / docs drift from best practice / aligned), offering
  code refactors or doc updates. Scope to one dimension (`/stack-audit
  migrations`) or whole-stack. Triggers on "audit the stack", "audit our
  conventions", "check best practices", "are we following our docs", "convention
  audit", "audit project against seed".
seed_managed: true
requires_tools: [gh, jq, pnpm, node]
requires_files:
  - scripts/audit/stack-inventory.mjs
  - scripts/audit/check-add-card-alignment.mjs
  - scripts/pr-audit.mjs
requires_mcp_any_of: [context7, plugin:context7:context7]
---

# Stack Audit

A two-layer alignment review. The same finding can have two failure modes — code drift from docs, OR docs drift from best practices — and they get treated differently.

```
┌─────────────────────────┐         ┌─────────────────────────┐
│ Layer 1                 │         │ Layer 2                 │
│ Project code vs docs    │         │ Docs vs external best   │
│                         │         │ practices               │
│ Finding: code !== rule  │         │ Finding: rule !== best  │
│ Default: refactor code  │         │ Default: ASK first      │
│ to match documented     │         │ (rule may be deliberate │
│ guideline               │         │ — only offer doc update │
│                         │         │ when not intentional)   │
└──────────┬──────────────┘         └──────────┬──────────────┘
           │                                   │
           └────────────► interactive walkthrough ◄─────────────┘
                          (per-finding decision)
                                   │
                                   ▼
                       apply approved changes
                       emit audit summary
```

## Invocation modes

| Invocation | Scope |
|---|---|
| `/stack-audit` | whole stack — every dimension below |
| `/stack-audit <dim>...` | one or more named dimensions (space-separated) |
| `/stack-audit --report-only` | walk findings, write `STACK-AUDIT.md`, do NOT apply changes |
| `/stack-audit --layer1` | only project-vs-docs (skip best-practice cross-checks — faster) |
| `/stack-audit --layer2` | only docs-vs-best-practice (skip project code reads) |

Dimensions (`<dim>` values):

`schema` · `queries` · `server-actions` · `api-routes` · `auth` · `bullmq` · `ai` · `testing` · `deployment` · `provisioning` · `migrations` · `secrets` · `security-scanning` · `skill-deps` · `pm-skills` · `branching` · `ui`

Default scope (whole-stack) covers all dimensions in order.

## Phase 1 — Inventory the rules

Read the seed's stated rules — every rule the project commits to following.

```bash
node scripts/audit/stack-inventory.mjs --json > /tmp/stack-rules.json
```

The inventory script walks:
- `CLAUDE.md` (root + any addenda the project added)
- `docs/conventions.md`, `docs/architecture.md`, `docs/database-patterns.md`,
  `docs/auth-patterns.md`, `docs/background-jobs.md`, `docs/ai-patterns.md`,
  `docs/testing-patterns.md`, `docs/deployment.md`, `docs/secrets.md`,
  `docs/security-scanning.md`, `docs/skill-dependencies.md`,
  `docs/seed-distribution.md`
- `.claude/skills/*/SKILL.md` frontmatter (for `requires_*` declarations)
- `app.yaml` + `app.staging.yaml` (the deploy contract)
- `package.json` `scripts` (the dev contract)

It emits one JSON object per rule with `{dimension, source, rule, kind}` where `kind ∈ {"must", "should", "convention", "default"}`. "must" rules are non-negotiable (e.g. "every multi-tenant query MUST filter by organizationId"); "should"s and "convention"s are softer.

Report the rule count per dimension before continuing — gives the operator a sense of scope.

## Phase 2 — Pick the audit scope

If args were passed, use those. Otherwise, AskUserQuestion:

> **Scope?** Whole stack (slow but thorough) / Pick dimensions / Just migrations / Just deployment

If the operator picks multiple dimensions, run them sequentially — one section per dimension in the eventual report, no interleaving.

## Phase 3 — For each dimension: dual-check

### Layer 1: code drift from docs

For each rule in the dimension:
1. Identify the relevant project surface (schema files, server actions, etc.)
2. Read those files
3. Verify the rule holds

| Dimension | Where to look | Sample rules to verify |
|---|---|---|
| `schema` | `lib/db/schema/*.ts` | timestamps use `withTimezone: true`; `updatedAt` has `$onUpdate`; id columns match documented pattern; relations declared if `db.query.*` is used elsewhere |
| `queries` | grep `db.query` + `db.select` in `app/` + `lib/` | reads use `db.query.*` with relations, writes use `db.insert/update/delete`; multi-tenant queries filter by `organizationId` (org variant) |
| `server-actions` | `app/**/actions.ts` + grep `"use server"` | `ActionResult` shape; Zod input validation; auth gate; no exports other than async functions from `use server` files; cross-resource binding checks present where multiple IDs are accepted |
| `api-routes` | `app/api/**/route.ts` | only webhooks / external consumers / auth callbacks — no internal mutations |
| `auth` | `lib/auth.ts`, `lib/auth-client.ts`, middleware | matches the documented org-vs-solo variant; `CLAUDE.md`'s `**Auth variant:**` marker matches the installed plugin |
| `bullmq` | `lib/jobs/**` | queue names kebab-case; failed listener resets in-flight status; `runJob` integration test exists for each processor |
| `ai` | grep `generateObject`, `streamText`, `generateText` | prompt-injection guard with `<data>` delimiters; error-handling sets status `"error"` not silent fallback |
| `testing` | `tests/unit`, `tests/integration`, `tests/e2e` | unit has no `next/*` imports; new Server Actions have auth-gate + access-control integration coverage; E2E scope matches documented allowlist (auth, core workflow, payments) |
| `deployment` | `app.yaml`, `app.staging.yaml`, `docker/*` | `db-migrate` PRE_DEPLOY uses `predeploy-migrate.sh`; `db-seed` POST_DEPLOY exists; `databases:` block uses `production: true` + `cluster_name`; no hardcoded `private-<host>` URLs |
| `provisioning` | `scripts/provision-db-user.sh` usage history (git log), drift cron status | drift workflow is enabled; dedicated DB user matches `app.yaml`'s `db_user` |
| `migrations` | `lib/db/migrations/*`, `lib/db/migrations/meta/_journal.json` | journal sequence integrity (already covered by `scripts/audit/migrations.mjs`); programmatic migrator in use, not raw `drizzle-kit migrate` in predeploy |
| `secrets` | `app.yaml`, `app.staging.yaml`, `.github/workflows/spec-drift.yml` | every `type: SECRET` env, no plaintext secrets; spec-drift workflow present |
| `security-scanning` | `.github/workflows/trivy-scan.yml`, `security/*.json` | workflow present; `accepted-risks.json` entries past `reEvaluateAt` flagged |
| `skill-deps` | every `.claude/skills/*/SKILL.md` + `.claude/agents/*.md` | `requires_*` declared; project additions have the right `requires_*` for what they invoke |
| `pm-skills` | `.claude/skills/add-card/SKILL.md` vs `docs/asana-best-practices.md` | run `node scripts/audit/check-add-card-alignment.mjs --strict` — the field-requirements tables must agree on INBOX + BACKLOG values for every shared field |
| `branching` | `.github/workflows/pr-base-enforcement.yml`, branch protection | enforcement workflow present; main + develop have required-check rules |
| `ui` | `app/`, `components/` | distinctive typography (not Inter/Roboto/Arial by default); shadcn primitives used; intentional palette |

For each rule that fails: record a **L1 finding** with `{rule, location, observed, recommendation}`.

### Layer 2: docs drift from best practice

For each rule in the dimension that's worth cross-checking:
1. Use Context7 MCP to pull the upstream library's current best-practice docs
2. Compare the seed's documented guideline to the upstream guidance
3. Identify drift

Use Context7 sparingly (max 3 queries per dimension). The high-value cross-checks:

| Dimension | Library / surface | What to look for |
|---|---|---|
| `schema` | drizzle-orm-docs | timestamp w/ tz, `$onUpdate`, relations API (v1 vs v2 / `defineRelations`), `$inferSelect`/`$inferInsert` vs Zod `.infer` vs `._output` |
| `queries` | drizzle-orm-docs | preferred query API for the use case; avoid raw SQL when query builder fits |
| `server-actions` | nextjs canary docs | `useActionState` patterns; `revalidatePath` / `revalidateTag` conventions |
| `auth` | better-auth docs | plugin signatures, session schema (does our hand-maintained schema lag upstream?) |
| `bullmq` | bullmq docs | `runJob` patterns; flow producer; `removeOnComplete` defaults |
| `ai` | ai-sdk docs | provider naming, structured output schema, max steps for agents |
| `migrations` | drizzle-orm-docs | `drizzle-kit check`, custom migrations for seed data, expand/contract pattern |
| `deployment` | DigitalOcean App Platform docs | PRE_DEPLOY / POST_DEPLOY semantics; PgBouncer mode defaults; named connection pools |

For each drift: record an **L2 finding** with `{rule, doc-says, upstream-says, source-url}`. **Do not auto-recommend** — these get the "was this deliberate?" treatment in Phase 4.

## Phase 4 — Interactive walkthrough

Present findings in priority order: L1 must-rules first, then L1 should/conventions, then L2 drifts. For each finding, render a compact table:

> **L1 · schema** — `lib/db/schema/auth.ts:14`
>
> | | |
> |---|---|
> | Rule | `updatedAt` columns must use `$onUpdate(() => new Date())` (docs/database-patterns.md line 25) |
> | Observed | `timestamp("updated_at").notNull().defaultNow()` — no `$onUpdate` |
> | Recommendation | Add `.$onUpdate(() => new Date())` and re-generate migration |
>
> AskUserQuestion — header: "L1 finding", question: "How to handle?"
> options:
>   - Apply fix (Recommended) — edits the schema, runs `pnpm db:generate`
>   - Document deviation — add a note in CLAUDE.md addendum explaining why this is OK
>   - Skip for now — log in the report, decide later

For **L2 findings**, the question is different:

> **L2 · schema** — `docs/database-patterns.md:24`
>
> | | |
> |---|---|
> | Documented rule | `timestamp("created_at").notNull().defaultNow()` |
> | Upstream best practice | `timestamp("created_at", { withTimezone: true }).notNull().defaultNow()` (drizzle-orm tutorial, postsTable example) |
> | Source | https://orm.drizzle.team/docs/... |
>
> AskUserQuestion — header: "L2 drift", question: "Was this guideline deliberate?"
> options:
>   - No — update doc to match best practice (Recommended) — edits docs/database-patterns.md
>   - Yes — capture the rationale — appends a `**Why:** ...` line under the rule explaining why we diverge
>   - Skip — log in the report

The "capture the rationale" path is critical: the operator's rationale gets written into the doc so the next audit knows this is deliberate and doesn't re-surface the finding.

## Phase 5 — Execute approved changes

Group by file. For each file:
1. Read it once
2. Apply all approved edits in one shot
3. Run the relevant lint/test:
   - Schema changes → `pnpm db:generate` (review the diff before committing) + `pnpm lint` + `pnpm typecheck`
   - Code changes → `pnpm lint` + `pnpm typecheck` + `pnpm test:unit`
   - Doc changes → no further validation needed
4. Stage the change

Do NOT commit yet — the operator reviews the staged diff at the end. (Skill must respect "Never create commits unless the user explicitly asks".)

## Phase 6 — Summary

Print a final table:

| Dimension | L1 found | L1 fixed | L1 skipped | L2 found | L2 docs updated | L2 documented-as-deliberate |
|---|---:|---:|---:|---:|---:|---:|
| schema | 2 | 2 | 0 | 1 | 1 | 0 |
| queries | 1 | 0 | 1 | 0 | 0 | 0 |
| … | | | | | | |

Then:

> Staged: N files. Review with `git diff --cached`. To commit: `git commit -m "audit: stack alignment — <one-line summary>"`.

If `--report-only` was passed (or nothing was approved), write `STACK-AUDIT.md` capturing all findings + decisions, leaving no staged changes.

## Cadence

- **First run on a new project**: expect a flood of L2 findings (the seed's docs haven't been cross-checked against upstream for that project's specific stack). Treat it as a one-time investment — most findings either get documented as deliberate or applied once.
- **Routine cadence**: monthly is plenty. The drift the audit catches is slow-burn — accumulated convention violations from feature work, doc gaps that only appear after a library upgrades.
- **After a major library bump**: re-run the L2 layer for that library's dimensions. A drizzle major version often invalidates several documented patterns at once.
- **Before a release**: scope to L1 only (`--layer1`) — surfaces "we documented a rule, the code doesn't follow it" before it ships.

## Skipping & suppressions

The L2 path writes a `**Why:** ...` line under the documented rule when the operator confirms divergence is deliberate. The audit reads those `**Why:**` lines in Phase 3 and skips the finding entirely if one matches the L2 mismatch. No silent skip — the rationale is in the doc, auditable forever.

For L1, the rule is: if the project code has a `// audit-skip: <dim> — <reason>` comment within 5 lines of the violation, treat as documented exception and report INFO (not BLOCK). Mirrors the existing `pr-audit` convention.

## Output discipline

- Silent when everything aligns. No final report.
- Loud when broken. Tables, file:line refs, before/after snippets.
- One question per finding — never bundle ("should I refactor these 5 things?"). Each gets its own AskUserQuestion so the operator can pick selectively.
- For multi-PR or multi-project audits (e.g. running across a whole org), use the Agent tool to dispatch one subagent per project with the appropriate scope arg.
