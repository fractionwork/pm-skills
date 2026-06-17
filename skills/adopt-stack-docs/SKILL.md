---
name: adopt-stack-docs
profiles: [engineer]
description: >
  Phase 2 of stack-aware adoption. After `adopt-tooling.sh --stack-aware`
  carries the agnostic tooling and writes `.devhawk-adopt-rewrite.json`, this
  regenerates the stack-specific reference docs (conventions, architecture,
  database, auth, jobs, testing, deployment, secrets, ai) against the project's
  DETECTED stack — keeping the seed's process discipline while swapping
  framework/ORM/host specifics. Confirms the stack, fetches current idioms via
  Context7, stamps each doc `seed_managed: false`, then removes the manifest.
  Triggers on "adopt-stack-docs", "rewrite the docs for my stack", "finish
  stack-aware adopt", "generate stack docs", "phase 2 adopt".
seed_managed: true
requires_tools: [gh, jq, node]
requires_files:
  - scripts/detect-stack.mjs
  - scripts/adopt-classification.json
requires_mcp_any_of: [context7, plugin:context7:context7]
---

# Adopt stack docs (stack-aware adoption — phase 2)

Stack-aware adoption is two phases. Phase 1 (`scripts/adopt-tooling.sh
--stack-aware`) is deterministic: it carries the stack-agnostic skills/docs/CI
and writes a manifest. Phase 2 — this skill — is the judgment-heavy part: it
**rewrites the stack-specific docs against the project's real stack**.

```
  adopt-tooling.sh --stack-aware              this skill (/adopt-stack-docs)
  ┌──────────────────────────────┐            ┌──────────────────────────────┐
  │ detect stack                 │            │ confirm/correct detected stack│
  │ carry agnostic skills+docs+CI│   writes   │ for each queued doc:          │
  │ skip DevHawk-stack skills     │ ─manifest─►│   · fetch seed original (ref) │
  │ write .devhawk-adopt-         │            │   · fetch target idioms (C7)  │
  │   rewrite.json                │            │   · rewrite for detected stack│
  └──────────────────────────────┘            │   · stamp seed_managed: false │
                                               │ delete manifest when all done │
                                               └──────────────────────────────┘
```

The whole point: a Django/Rails/Go project shouldn't be handed `conventions.md`
that describes Next.js Server Actions and Drizzle. This skill makes the docs
describe the stack the project actually runs — while keeping the *discipline*
the seed docs encode, which is stack-independent.

## Preconditions

1. **The manifest must exist.** Read `.devhawk-adopt-rewrite.json` at repo root.
   If it's absent, stop and tell the operator:
   > No rewrite manifest found. Run phase 1 first:
   > `bash scripts/adopt-tooling.sh --stack-aware` (or fetch + run it via the
   > `gh api … adopt-tooling.sh` one-liner), then re-run `/adopt-stack-docs`.
2. **Context7 MCP** should be available (`requires_mcp_any_of`). If it isn't,
   proceed but warn that idioms come from training data only and the operator
   should sanity-check version-specific API surface.
3. **`gh` authenticated** — used to fetch the original seed docs as structural
   references.

## Step 1 — Load the manifest and confirm the stack

Read `.devhawk-adopt-rewrite.json`. Show the operator:

- `detectedStack` (language, framework, orm, testRunner, jobSystem, validation,
  auth, ui, host, ai) and the detection `confidence`.
- The `docsToRewrite` list (doc + topic).

**Detection is heuristic — confirm before rewriting.** Ask the operator to
confirm or correct the stack. A wrong `framework` or `orm` produces wrong docs.
Use AskUserQuestion when any field is `null` on a project that clearly has one,
or when `confidence` is not `high`. Example corrections to invite:

- framework `react` but it's actually **Remix** / **TanStack Start**
- orm `null` but they use **raw SQL** / a query builder
- jobSystem `null` but they run **cron** / a custom worker
- host `docker` but they actually deploy to **ECS** / **Cloud Run** / **k8s**

Record the corrected values — they override `detectedStack` for the rest of the
run. (Optionally re-run `node scripts/detect-stack.mjs` to show the raw
evidence behind a call the operator doubts.)

If the operator wants to limit scope ("just conventions and database-patterns"),
filter `docsToRewrite` to those entries.

## Step 2 — For each queued doc, rewrite it

Process `docsToRewrite` in array order. Skip entries already marked
`status: "done"` (so the run is resumable after an interruption). For each:

### 2a. Fetch the seed original as a structural reference

```bash
gh api "repos/fractionwork/devhawk-seed/contents/docs/<doc>?ref=main" \
  --jq '.content | @base64d'
```

This is the DevHawk version. **You are not copying it** — you are reading it to
extract the *transferable discipline* called out in the manifest entry's
`preserve` field (e.g. expand/contract migrations, server-side re-validation,
fail-loud AI error handling, prompt-injection guards, the "what to always test
/ never test" split). Those rules are stack-independent and must survive into
the rewrite. The framework/ORM/host *mechanics* around them get replaced.

For `deployment.md` (entry has `includesSubdir: "deployment"`), also list the
seed's subpages so you know what topics it splits out:

```bash
gh api "repos/fractionwork/devhawk-seed/contents/docs/deployment?ref=main" \
  --jq '.[].name'
```

Decide whether the target host warrants subpages (a managed PaaS usually folds
into one doc; a k8s/Terraform setup may want its own split). Do not carry the
DO-specific subpages verbatim.

### 2b. Fetch current idioms for the target stack (Context7)

For the field named by the entry's `key` (`framework` / `orm` / `auth` /
`jobSystem` / `testRunner` / `host`; `stack` for architecture), query Context7
for the current API surface so the rewrite uses today's idioms, not stale
training data. Cap at ~3 Context7 queries per doc (mirror `/stack-audit`'s
budget). Examples:

| Doc | key | Context7 target |
|---|---|---|
| conventions.md | framework | the framework's project-structure + conventions guide |
| database-patterns.md | orm | the ORM's schema + migration docs |
| auth-patterns.md | auth | the auth library's session + middleware docs |
| background-jobs.md | jobSystem | the queue/worker library's docs |
| testing-patterns.md | testRunner | the test runner's docs |
| deployment.md / secrets.md | host | the host's deploy + secrets/config docs |

If a `key` value is `null` (e.g. no ORM, no job system), write the doc to say
so explicitly and document the gap / the project's actual approach — don't
invent a tool the project doesn't use.

### 2c. Write the rewritten doc — with the opt-out stamp

Write `docs/<doc>` with this exact frontmatter as the first lines:

```markdown
---
seed_managed: false
---

# <Doc title for the target stack>

…rewritten content…
```

**The `seed_managed: false` stamp is mandatory and is the whole reason this is
safe.** Without it, the next `update-seed` pull (`bash scripts/sync-skills.sh`)
sees the seed has `docs/<doc>` and overwrites your stack-matched version with
the DevHawk one. `sync-skills.sh` only preserves docs
whose frontmatter carries `seed_managed: false` (it scans the first `---`
block). Add a one-line HTML comment under the title noting the doc was
generated for the detected stack and is project-owned, e.g.:

```markdown
<!-- Rewritten for <framework>/<orm> by adopt-stack-docs on <date>. Project-owned;
     not synced from the seed. Edit freely. -->
```

Content rules:
- Match the seed doc's **structure and voice** (section headings, tables,
  fenced examples) but with the target stack's real code.
- Keep every `preserve` discipline from the manifest entry, re-expressed for the
  target stack.
- Code blocks must be runnable-looking for the target stack (right imports,
  right function names) — use the Context7 result, not guesses.
- Don't reference Next.js/Drizzle/Better Auth/BullMQ/DO unless the project
  actually uses them.

### 2d. Mark the entry done

Update the entry's `status` to `"done"` in `.devhawk-adopt-rewrite.json` (so a
re-run resumes cleanly):

```bash
jq '(.docsToRewrite[] | select(.doc == "<doc>") | .status) = "done"' \
  .devhawk-adopt-rewrite.json > .tmp && mv .tmp .devhawk-adopt-rewrite.json
```

## Step 3 — Finish

When every entry is `status: "done"`:

1. **Remove the manifest:** `rm .devhawk-adopt-rewrite.json` (and drop its line
   from `.gitignore` if you like — harmless either way).
2. **Offer (don't force) CLAUDE.md wiring.** The project's `CLAUDE.md` is
   project-owned and never touched automatically. Offer to add `docs/…`
   references to the rewritten docs (mirroring how the seed's CLAUDE.md links
   its reference docs by plain path — NOT `@`-imported, so they're discoverable
   but read on demand, not preloaded into every session). Ask first.
3. **Summarize:** list the docs rewritten, the stack they target, and remind the
   operator the docs are now `seed_managed: false` (project-owned; future syncs
   skip them). Note that the carried agnostic docs (`security-scanning.md`,
   `seed-distribution.md`, etc.) remain seed-managed and *will* update on future
   `update-seed` pulls.
4. Suggest a commit:
   `git add docs/ CLAUDE.md && git commit -m "docs: stack-matched reference docs (<framework>)"`

## Notes & edge cases

- **Resumable.** Interrupted mid-run? Re-invoke — entries marked `done` are
  skipped; the manifest is the source of truth for what's left.
- **Operator overrides win.** If the operator corrects the stack in Step 1, use
  the corrected values everywhere, including the Context7 queries.
- **`ai-patterns.md`** is only in the manifest when phase 1 detected an AI SDK
  (`onlyIf: "ai"`). If the project later adds AI, re-run phase 1 to requeue it.
- **Already on the DevHawk stack?** Phase 1 refuses (`matchesDevhawkStack`) and
  tells the operator to use plain adopt — so this skill never runs against a
  DevHawk-stack project.
- **No manifest, operator insists on rewriting anyway?** Have them run phase 1
  first; this skill is deliberately driven by the manifest so the carried/
  skipped/rewritten split stays consistent with `adopt-classification.json`.
