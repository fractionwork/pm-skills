# Phase 5 — Cloud provisioning

Runs only after the local verification gate passes. This phase touches DigitalOcean and is the first phase whose actions are not trivially reversible (managed clusters cost money the moment they're created, and the bound GitHub repo starts auto-deploying on every push to `main`).

### Step 1: Update AppSpec placeholders

Ask:
> **Would you like me to replace the `<PROJECT_NAME>` placeholder in the AppSpec files and CI workflow?**
> This substitutes `[project-name]` into `app.yaml`, `app.staging.yaml` (if kept), and `.github/workflows/ci.yml`.

If yes:
```bash
sed -i "s|<PROJECT_NAME>|[project-name]|g" app.yaml
[ -f app.staging.yaml ] && sed -i "s|<PROJECT_NAME>|[project-name]|g" app.staging.yaml
sed -i "s|<PROJECT_NAME>|[project-name]|g" .github/workflows/ci.yml
sed -i 's/"name": "devhawk-app"/"name": "[project-name]"/' package.json
# Also update the github.repo owner if it differs from `fractionwork`
sed -i "s|fractionwork/[project-name]|[owner]/[project-name]|g" app.yaml
[ -f app.staging.yaml ] && sed -i "s|fractionwork/[project-name]|[owner]/[project-name]|g" app.staging.yaml
git add app.yaml app.staging.yaml .github/workflows/ci.yml package.json 2>/dev/null
git commit -m "chore: update AppSpec for [project-name]"
git push
```

### Step 2: DO App Platform app

Ask:
> **Would you like me to provision the DigitalOcean App Platform app now?**
> This creates the DO Project, managed PG + Valkey clusters, both app shells (prod and, if configured, staging), triggers the first deploy, and captures the ingress URL.
> *(Requires: `doctl` CLI authenticated, DO ↔ GitHub org OAuth granted. You can skip and do it later.)*

If yes: defer the entire DigitalOcean flow to the `do-deploy` skill. It walks through DO Project creation, cluster provisioning, app creation, secret seeding, first deploy, and ingress capture in a single guided flow with the diagnostics that save time when things go wrong. Say:

> I'll hand off to the `do-deploy` skill now — it'll walk the DO provisioning end-to-end.

Then invoke the `do-deploy` skill with the project's `<PROJECT_NAME>` and `<ProductName>` values.

If no or `doctl` unavailable: tell the user to run **"deploy to DO"** later when they're ready — that triggers the `do-deploy` skill. No partial inline provisioning from this skill.

#### Alternative cloud target

If the project chose a non-DO cloud target during Phase 0 (migration with Constraint capture flagged a different cloud) or during Phase 1 (rare — the seed defaults to DO), do NOT invoke `do-deploy`. Instead:

1. State explicitly: "This project targets `<cloud>`, not DO. The seed's bundled IaC (app.yaml, app.staging.yaml, db-migrate job) is DO-specific."
2. Generate a `DEPLOY.md` checklist for the chosen cloud covering: managed PG provisioning, managed Redis/Valkey, container registry + service deploy, secret management, env vars (mapping the seed's expected names), pre-deploy migration job, monitoring.
3. Note that the seed's `databases:` binding magic (auto-injected `${db.DATABASE_URL}`) does NOT translate — the alternative cloud needs explicit secret env vars.
4. Defer execution to the builder; the seed's bootstrap does not script non-DO provisioning.

### Step 3: Report

After all steps (whether completed or skipped), give a final summary:

> **[Project Name] — Ready**
>
> **GitHub:** [link, or "create manually"]
> **Backlog:** [Asana link, Shortcut link, Linear link, "see backlog.md", or whichever was used]
> **DO App:** [link, or "create later"]
>
> **What's ready:**
> - [List what was actually provisioned]
>
> **What to do manually:**
> - [List anything that was skipped, with instructions]
>
> **Start building:**
> ```
> pnpm dev
> ```
> Pick a story from Asana (or backlog.md) and say **"build E1-S1"**.
