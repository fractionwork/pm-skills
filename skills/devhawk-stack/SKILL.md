---
name: devhawk-stack
profiles: [engineer]
description: >
  DevHawk Reference Stack knowledge base. Use when Claude needs to answer
  questions about WHY a specific technology was chosen, what alternatives
  were considered, pricing comparisons, or architectural rationale. Triggers
  on questions like "why do we use Drizzle", "how much does this cost",
  "should we use X instead of Y", "what's the architecture", or any
  stack-level decision question.
---

# DevHawk Reference Stack

This skill contains the architectural rationale behind every stack decision.
Read `docs/architecture.md` for the full decision table.

## Quick reference

| Decision | Chosen | Rejected | Key reason |
|----------|--------|----------|------------|
| Hosting | DO App Platform | Vercel, Railway, Fly.io | Component model (Service/Worker/Job), no Worker timeout, MCP server |
| Framework | Next.js 16 | Remix, SvelteKit, Nuxt | Deepest Claude training data, ecosystem dominance |
| ORM | Drizzle | Prisma, Kysely, TypeORM | SQL-first (Claude accuracy), no codegen, 7.4KB, native RLS |
| Auth | Better Auth | Clerk, Auth0, NextAuth | $0 at any scale, your DB, Drizzle adapter, org plugin |
| UI | shadcn/ui | Chakra, Mantine, MUI | Owned code, highest Claude accuracy, Radix primitives |
| Queues | BullMQ | Inngest, Trigger.dev, Temporal | Stays in DO ecosystem, MIT license, no external SaaS |
| Redis | DO Managed Redis | Upstash, ElastiCache | Same VPC, predictable pricing, no external dependency |
| State | Zustand + TanStack Query | Redux, Jotai, SWR | Minimal API, RSC-compatible, tiny bundle |
| Validation | Zod | Yup, Valibot, ArkType | AI SDK integration, drizzle-zod, ecosystem standard |
| AI | Vercel AI SDK 6 | LangChain, custom | Provider-agnostic, streaming, structured outputs, 20M+ downloads |

## Cost summary

| Component | Monthly cost |
|-----------|-------------|
| Service (pro-xs) | $12 |
| Worker (basic-xs) | $10 |
| Jobs (per-run) | ~$1-3 |
| Managed PG 16 | $15 |
| Managed Redis 7 | $15 |
| **Total infrastructure** | **~$53-55** |
| Open-source tools | $0 |
| Better Auth (any scale) | $0 |

## Auth pricing comparison

Better Auth: $0 at 1K, 10K, 50K, 100K MAU
Clerk: $0 → $0 → $825/mo → $1,825/mo at same thresholds
Clerk adds: $1/MAO after 100 orgs, $50/SAML connection, $100/mo for MFA add-on

## When to deviate from the stack

These are per-product decisions, NOT stack-level changes:
- **Supabase instead of DO PG**: When a product needs realtime subscriptions, auto-generated APIs, or built-in file storage
- **Neon instead of DO PG**: When a product needs database branching for preview environments
- **Inngest on top of BullMQ**: When a product needs multi-step durable workflows with sleep/wake spanning days
- **Clerk instead of Better Auth**: Never for DevHawk projects. The cost and vendor lock-in don't justify the DX convenience.
