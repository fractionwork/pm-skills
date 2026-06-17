---
name: bootstrap
profiles: [engineer]
description: >
  Bootstrap a new DevHawk project from a product idea or business problem.
  Runs an interactive discovery conversation, maps features to stack components,
  generates scaffold code on the seed repo, creates CLAUDE.md addendum,
  generates backlog, and optionally provisions GitHub repo + Asana project +
  DO App Platform app. Triggers on phrases like "new project", "bootstrap",
  "start a new app", "build a new product", "scaffold", "set up a project for",
  or any request to create a new application on the DevHawk stack.
requires_tools: [gh, pnpm, node]
---

# DevHawk Project Bootstrap

You are setting up a new project on the DevHawk Reference Stack. The stack is already decided — do NOT evaluate technologies. Focus entirely on understanding the PRODUCT and mapping features to stack components.

The full pipeline runs in up to six phases, all within this single Claude Code session:

0. **Migration discovery** *(only if porting an existing app — see triggers below)* — inventory current architecture, capture constraints, recommend a balanced migration shape (interactive, ~15 min)
1. **Discovery** — Understand the product (interactive, ~10 min)
2. **Scaffold** — Generate code on the seed repo (automated)
3. **Backlog** — Create epics, stories, tasks (automated)
4. **Code + tracking provisioning** — GitHub repo + PM backlog (automated, requires confirmation)
5. **Cloud provisioning** — DO App Platform + Managed PG/Valkey (automated, **gated on local verification**)

Phase 0 is skipped for greenfield projects. Phase 5 only runs **after the app is verified working locally** — see the local verification gate between Phases 4 and 5. Skipping the gate is the single most common cause of "deployed but broken" first deploys.

### Auto-accept mode

If the builder says any of: "auto", "auto-accept", "just run it", "skip confirmations", "don't ask, just do it" — or passes `--auto` as an argument — enable **auto-accept mode**. Acknowledge it immediately:

> **Auto-accept is on.** After the discovery rounds (which still need your input), I'll show the architecture review and each provisioning step but proceed without waiting for approval. Say **"stop"** or **"hold on"** at any point to pause and switch back to interactive mode.

In auto-accept mode:
- **Steps 1-6** — still interactive (need the builder's answers). Derived output is shown but proceeds without the per-step "Looks good" gate. Builder can interrupt anytime.
- **Step 7 (scope + generate)** — shown, then proceeds
- **Phase 2-4** — run without per-step confirmation. Builder sees output but doesn't approve each step.

**Hard pause on failure only** (typecheck error, `doctl` auth issue, `gh` error). On failure, stop and wait.

Default (no auto-accept): all per-step gates remain.

---

## Phases

Each phase has its own reference file with the full detail (steps, templates, code blocks). Load the reference for a phase only when you reach it. Reference files do not link to one another — each is self-contained.

### Phase 0 — Migration discovery

Inventory an existing app's architecture, capture migration constraints, produce a per-layer fit-assessment table, and present three migration shapes (full / strangler-fig / minimal lift). The chosen shape scopes the rest of bootstrap and is written to `MIGRATION.md`.

**Branch condition:** run ONLY for existing-app migrations (triggers: "migrate", "port", "we already have an app", or a path/repo URL passed in). SKIP entirely for greenfield projects. When in doubt, run the cheap auto-detect prompt described in the reference.

→ Read and follow `references/phase-0-migration-discovery.md` before executing this phase.

### Phase 1 — Discovery + architecture

One continuous interactive conversation (Steps 1–7) that understands the product and, at each step, immediately shows the derived output (schema, server surface, queues, infra, UX direction). Ends at a "Generate scaffold" gate. Do NOT ask about tech stack/hosting/architecture — those are decided.

**Branch condition:** always runs. For migrations, its scope is shaped by the Phase 0 choice (done back in Phase 0).

→ Read and follow `references/phase-1-discovery.md` before executing this phase.

### Phase 2 — Scaffold generation

Generate all code on top of the seed repo: Docker isolation, theme/layout via the `frontend-design` skill, DB schema, route stubs, Better Auth config (org vs solo variant), BullMQ queues, AI definitions, optional observability, AppSpec, seed files, test stubs, CLAUDE.md addendum, README. Then run post-scaffold review and local verification (`db:generate`, `db:migrate`, `typecheck`).

**Branch condition:** runs after the Phase 1 "Generate scaffold" gate. Read `docs/conventions.md` before generating any code.

→ Read and follow `references/phase-2-scaffold.md` before executing this phase.

### Phase 3 — Backlog generation

Generate structured epics, stories, and tasks (with story points and acceptance criteria) held in memory for the provision step. Includes the standard E0 / E1 / E-LAST epics every project gets.

**Branch condition:** always runs after scaffold.

→ Read and follow `references/phase-3-backlog.md` before executing this phase.

### Phase 4 — Code + tracking provisioning

Present the scaffold-complete summary, run pre-flight tool checks, then provision the GitHub repo and the PM backlog (Asana / Shortcut / Linear, or `backlog.md` fallback). Ends with the **local verification gate** — the hard pause before any cloud work.

**Branch condition:** interactive mode asks each provision step one at a time; auto-accept runs them sequentially (stop only on failure). The local verification gate is a hard pause in BOTH modes unless `--skip-verify` was passed.

→ Read and follow `references/phase-4-provisioning.md` before executing this phase.

### Phase 5 — Cloud provisioning

Substitute AppSpec placeholders, then hand off DigitalOcean provisioning to the `do-deploy` skill (DO Project, managed PG + Valkey, app shells, first deploy, ingress). Covers the alternative-cloud path and the final ready report.

**Branch condition:** runs ONLY after the local verification gate passes (done back in Phase 4). Skip the `do-deploy` handoff if the project targets a non-DO cloud — generate a `DEPLOY.md` instead.

→ Read and follow `references/phase-5-cloud.md` before executing this phase.

---

## Constraints

- NEVER evaluate or recommend technology — the stack is decided
- NEVER skip discovery — even if the user says "just scaffold it" or provides a complete spec
- NEVER assume answers to discovery questions from a provided spec — always ask explicitly
- ALWAYS flag technology conflicts between a provided spec and the DevHawk stack, and discuss before proceeding
- ALWAYS wait for checkpoint confirmation before generating code
- ALWAYS run typecheck after scaffold generation before proceeding
- ALWAYS include organizationId on tenant-scoped tables
- ALWAYS generate test stubs alongside feature code
- ALWAYS follow patterns in the docs/ directory
- In interactive mode: ALWAYS ask about each Phase 4 + Phase 5 provision step individually — do NOT batch them
- In interactive mode: ALWAYS wait for an explicit yes/no on each provision step before proceeding
- In auto-accept mode: run all steps sequentially, show output, stop only on failure or builder interruption
- ALWAYS hard-pause at the local verification gate (between Phase 4 and Phase 5). Auto-accept mode does NOT bypass this gate unless `--skip-verify` was passed explicitly
- NEVER provision DO clusters, apps, or any cost-incurring cloud resource before the local verification gate passes
- NEVER push to a repo that already has commits (safety check: verify remote is empty or non-existent)
- NEVER put secrets in shell commands, commit messages, or backlog files
