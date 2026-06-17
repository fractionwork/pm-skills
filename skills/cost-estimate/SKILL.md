---
name: cost-estimate
profiles: [engineer]
description: >
  Produce a hosting and infrastructure cost estimate for an application. Inspects the
  project to identify the hosting provider and managed services in use, asks the user
  about expected user count, concurrency, and data volumes, fetches current published
  pricing for the identified provider, then produces Low / Mid / High monthly cost
  estimates with sizing rationale. Also proposes architectural compromises that reduce
  cost without impacting performance or functionality. Triggers on phrases like
  "cost estimate", "how much will this cost", "hosting cost", "infra budget",
  "price this out", "estimate monthly spend", "what will DO / AWS / Vercel cost",
  or any request to forecast infrastructure spend.
---

# Cost Estimation Skill

You are producing a hosting and infrastructure cost estimate for an application. The output is a decision-grade table the user can bring to a budget conversation, plus concrete levers to pull if the number is too high.

Never guess at prices. Pricing changes frequently — always fetch current published pricing before producing the final table. Stale pricing is worse than no estimate.

## Phase 1: Inspect the project

Understand what is actually deployed (or planned to deploy) before asking the user anything. Read the code, not the README.

### What to identify

1. **Hosting provider(s)** — look for:
   - `app.yaml` (DigitalOcean App Platform)
   - `vercel.json` / `.vercel/` (Vercel)

   When detecting a `databases:` block in `app.yaml`, differentiate the deployment shape — the presence and shape of `databases:` is the biggest DO cost signal:
   - **Low estimate**: the app creates new clusters per env (~$15 PG + $15 Valkey per env = $30 base for a one-off project)
   - **Mid estimate**: prod + staging share clusters via dedicated PG users + `db_name`/`db_user` binding (saves ~$15/mo on staging) — recognized by `app.staging.yaml` referencing the same `cluster_name` as prod with different `db_name`/`db_user`
   - **High estimate**: HA standby on PG + Valkey (~$60+ baseline for production-grade)

   - `netlify.toml` (Netlify)
   - `fly.toml` (Fly.io)
   - `render.yaml` (Render)
   - `railway.toml` / `.railway/` (Railway)
   - `serverless.yml` / `sam.yaml` / CDK / Terraform (AWS)
   - `cloudbuild.yaml` / `app.yaml` at root with `runtime:` key (GCP App Engine)
   - `azure-pipelines.yml` + Bicep/ARM (Azure)
   - `Dockerfile` + Kubernetes manifests (self-managed K8s)
   - `docker-compose.yml` as the only deploy artifact (self-hosted / VPS)

2. **Managed services referenced in config or env**:
   - Databases: Postgres, MySQL, MongoDB, DynamoDB, Firestore, PlanetScale, Neon, Supabase, Railway PG
   - Caches/queues: Redis, Valkey, Upstash, Memcached, SQS, PubSub
   - Object storage: S3, R2, GCS, Azure Blob, Spaces
   - Email: Resend, SendGrid, Postmark, SES, Mailgun
   - Error tracking: Sentry, Rollbar, Bugsnag, Datadog
   - Analytics: PostHog, Mixpanel, Amplitude, Segment
   - AI providers: Anthropic, OpenAI, Google (Gemini), Groq, Together, Replicate
   - Auth SaaS: Clerk, Auth0, WorkOS, Stytch (vs. self-hosted like Better Auth)
   - Payments: Stripe, Paddle, Lemon Squeezy
   - CDN / edge: Cloudflare, Fastly

3. **Workload shape** — read the code to understand what actually runs:
   - HTTP request handlers (web tier sizing)
   - Background workers / queue consumers (worker tier sizing)
   - Cron / scheduled jobs
   - WebSockets / SSE / long-lived connections (changes autoscaling math)
   - Heavy AI calls or streaming (latency / memory implications)
   - Large file handling (memory / bandwidth implications)

4. **Environment model** — check for:
   - Branch-based preview envs
   - Explicit staging/UAT configs
   - Any references to multiple envs in CI/CD workflows

### Output of Phase 1

A short internal inventory you can reference. Do not dump this to the user yet — you'll surface the relevant pieces in Phase 3.

If the project has **no identifiable hosting config** (greenfield), ask the user which provider they're targeting before continuing. If multiple providers are in play, estimate each separately and sum.

## Phase 2: Gather sizing inputs

Use the AskUserQuestion tool to collect sizing data. Ask only what you need — skip questions the code already answers (e.g. don't ask if they need a worker if `app.yaml` already declares one).

Ask these in a **single AskUserQuestion call** so the user sees them together. Provide sensible multiple-choice options plus a free-form fallback.

### Required questions

1. **Total user base size** — how many registered/known users total
   - Options: `<50`, `50–500`, `500–5k`, `5k–50k`, `50k+`, free text

2. **Peak concurrent users** — how many simultaneously active during a normal peak
   - Options: `<10`, `10–50`, `50–250`, `250–1000`, `1000+`, free text
   - If the user doesn't know, use a rule of thumb: ~1–5% of daily actives, ~0.1–1% of total users depending on app type

3. **User type** — affects sizing cushion needed
   - Options: `Internal tool (trusted users, predictable load)`, `B2B SaaS (business hours traffic)`, `Consumer (spiky, unpredictable)`, `Public / viral potential`

4. **Environments needed**
   - Options: `Prod only`, `Prod + staging`, `Prod + staging + UAT`, `Prod + preview envs per PR`

5. **Data volume expectations after 12 months** — drives DB + storage sizing
   - Options: `<1 GB`, `1–10 GB`, `10–100 GB`, `100 GB–1 TB`, `1 TB+`, free text

6. **Background job volume** — only if a worker is present
   - Options: `Rare (<100/day)`, `Light (100–10k/day)`, `Heavy (10k–1M/day)`, `Very heavy (1M+/day)`

7. **AI usage** — only if AI SDKs are detected
   - Options: `None`, `Occasional (<1k calls/mo)`, `Regular (1k–100k/mo)`, `Heavy (100k+/mo)`, free text
   - Note: AI API costs are usually separate from hosting and often dominate; flag this explicitly.

8. **Uptime / availability needs**
   - Options: `Best-effort (brief downtime OK)`, `Business-critical (HA required)`, `99.9%+ SLA`

### Optional questions (ask only if relevant)

- Regional requirements (single region vs. multi-region)
- Compliance constraints (HIPAA, SOC2, data residency) — these force premium tiers
- Existing commitments/credits (AWS Activate, GCP credits, DO credits) — affects effective price

## Phase 3: Fetch current pricing

Use WebSearch or WebFetch to pull **current pricing from the provider's own pricing page** for every paid component identified. Do not rely on memory — pricing shifts quarterly.

### What to fetch

For each identified provider, get:
- Compute tiers and their specs (vCPU, RAM, $/mo)
- Managed database tiers (including HA / standby pricing)
- Managed cache/queue tiers
- Bandwidth / egress pricing (often a hidden cost)
- Object storage ($/GB stored + $/GB transferred + per-request fees)
- Any platform fees (e.g. DO App Platform static site tier, Vercel seat pricing)

For third-party SaaS (Resend, Sentry, Stripe, etc.):
- Free tier limits
- Next-tier pricing
- Per-unit pricing (per email, per event, per transaction)

Cite the source URL inline in the final table footer so the user can verify.

### Pricing cache

If multiple cost estimates are done in the same session for the same provider, cache the numbers in conversation context — don't re-fetch. But always re-fetch across sessions.

## Phase 4: Produce the estimate

Build a **single comparison table** with three columns: **Low**, **Mid**, **High**.

### Sizing philosophy

- **Low** — smallest viable configuration. Assumes best-effort uptime, shared managed services where safe, minimum instance sizes. Target: pre-launch, internal tools, or "prove it works" stage.
- **Mid** — recommended launch configuration. Prod has appropriate headroom; staging is real but downsized; managed services sized for 12-month data growth; no HA unless required.
- **High** — sized for the peak concurrency the user gave you, with HA on critical tiers. This is the "we hit our numbers" configuration.

### Table structure

```markdown
| Component | Low | Mid | High |
|---|---|---|---|
| **PRODUCTION** | | | |
| Web / app tier | [size] — $X | [size] — $X | [size] × N (HA) — $X |
| Worker tier | [size] — $X | [size] — $X | [size] × N — $X |
| Scheduled jobs | per-run — ~$X | per-run — ~$X | per-run — ~$X |
| Database (managed) | [tier] — $X | [tier] — $X | [tier] + standby — $X |
| Cache / queue | [tier] — $X | [tier] — $X | [tier] — $X |
| Object storage | $X | $X | $X |
| Bandwidth / egress | included | ~$X | ~$X |
| **STAGING / UAT** (if requested) | | | |
| ... | ... | ... | ... |
| **THIRD-PARTY SAAS** | | | |
| Email (Resend/etc.) | free tier — $0 | $X | $X |
| Error tracking | free tier — $0 | $X | $X |
| AI API (variable) | ~$X | ~$X | ~$X |
| **TOTAL** | **~$X/mo** | **~$X/mo** | **~$X/mo** |
```

### Rationale section

Below the table, include a short section per tier explaining **why** that sizing was chosen. Call out:
- What drove the size decision (user count? concurrency? data volume?)
- What would force an upgrade to the next tier
- What scales linearly vs. what scales in jumps (managed DB tiers are often 2× jumps; compute is more granular)

### Hidden / variable costs

Always end with a "not in the table" section covering:
- AI API token costs (can dwarf hosting at scale — show estimate based on volume given)
- Payment processor fees (Stripe: 2.9% + $0.30; not a fixed line but large at volume)
- Domain registration (~$12/year)
- Third-party integrations not yet chosen
- Data egress beyond free tier (especially AWS — can be a nasty surprise)
- Backup storage if not included
- DDoS / WAF protection at scale

## Phase 5: Cost-saving architectural compromises

This is the most valuable part of the output. Propose concrete changes that reduce cost **without** hurting the user experience or removing features.

### Good compromises (suggest these)

- **Shared managed services across non-prod envs.** One PG cluster with multiple logical DBs, one Redis with multiple DB indexes. Safe if staging/UAT load is minimal. Saves $15–30/mo per extra env on most providers.
- **Preview envs instead of permanent staging.** Branch-based ephemeral envs cost only during PR lifetime. Works well for internal tools.
- **Downsized non-prod compute.** Staging doesn't need prod-sized instances to validate functionality. Halve or quarter the tier.
- **Deferred HA until measurable traffic.** Launch on single-node managed DB; upgrade to standby once there are real users to protect.
- **Object storage instead of DB for large blobs.** Storing files/attachments in DB inflates backup size and premium tier requirements. Move to S3/R2/Spaces.
- **Cloudflare R2 instead of S3** for frequently-read storage (no egress fees). Saves massively if bandwidth is a factor.
- **Single region unless needed.** Multi-region doubles infra cost and adds complexity. Only needed for latency-sensitive global apps or compliance.
- **Autoscaling min=1.** Pay for one instance baseline, scale up on load rather than provisioning for peak 24/7.
- **Cached read replicas for analytics.** Move heavy read queries off the primary so you don't need to oversize the primary.
- **Use platform free tiers fully.** Sentry, Resend, PostHog, Cloudflare all have meaningful free tiers for small apps.
- **Spot / preemptible instances for workers.** If jobs are retryable (they should be with BullMQ), workers can run on spot instances at 60–80% discount.

### Bad compromises (do NOT suggest)

Never propose compromises that hurt users or violate the project's conventions:
- ❌ Skipping backups to save on DB tier
- ❌ Disabling HA on prod once you have real users
- ❌ Eliminating the worker tier and running jobs inline in request handlers
- ❌ Shared prod DB between unrelated apps (security + blast radius)
- ❌ Undersizing RAM to the point of OOM restarts
- ❌ Dropping error tracking or observability to save $26/mo
- ❌ Moving to a cheaper but unvetted provider for core services

### Format the compromises as a menu

Present each compromise as:

```markdown
**[Compromise name]** — saves ~$X/mo
**What changes:** [concrete config delta]
**Impact on users:** None / Minimal / [specific impact if any]
**When to reconsider:** [condition that should trigger undoing this]
```

This lets the user pick from the menu rather than accepting a single opinionated plan.

## Phase 6: Summary and recommendation

End with:
1. A one-line headline: "Realistic launch cost: **~$X/mo**, growing to **~$Y/mo** at [specified concurrency]."
2. Which of the three tiers you'd actually recommend the user start with, given their answers.
3. The top 2–3 cost-saving compromises from Phase 5 that fit their context.
4. The cost drivers to watch — which line item grows fastest with scale and when to re-evaluate.

## Important guidelines

- **Always fetch live pricing.** Memory-based numbers are outdated. Use WebSearch/WebFetch and cite URLs.
- **Be honest about ranges.** "$X–$Y" is more useful than a false-precision single number. Compute can be exact; bandwidth and AI are ranges.
- **Separate fixed from variable costs.** Fixed (compute, DB tier) vs. variable (bandwidth, AI tokens, emails sent). Users budget differently for each.
- **Call out the dominant cost.** At small scale it's usually DB floor prices. At mid-scale it's compute. At large scale it's often AI API calls or bandwidth. Name the dominant cost explicitly so the user knows where to focus optimization.
- **Don't over-engineer the estimate.** A reasonable ±20% estimate delivered quickly beats a perfect estimate delivered late. Users want decision-grade numbers, not accounting-grade.
- **Respect existing architecture decisions.** Do not propose wholesale stack changes in the compromises section. Work within the chosen stack. Stack migration is a separate conversation (see the `migrate` skill).
- **Flag AI API costs prominently.** For AI-heavy apps, token costs can be 5–10× the hosting bill. Users are often surprised. Show a rough estimate based on expected call volume and typical token counts.
- **Show the math on concurrency sizing.** If the user says "250 concurrent," explain why that maps to N instances of tier M. The reasoning is as valuable as the number.
- **Update, don't restart.** If the user asks to adjust a parameter (e.g. "flip low and mid", "add staging", "what if we went to 500 concurrent"), keep the existing structure and adjust — don't rebuild the table from scratch.
