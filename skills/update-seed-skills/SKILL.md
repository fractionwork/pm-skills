---
name: update-seed-skills
profiles: [engineer]
description: >
  Pull the latest seed-managed PROJECT SUBSTRATE from the DevHawk seed into the
  current project — reference docs, scaffold code, git hooks, CI workflows, the
  project scripts hooks/CI invoke, plus .mcp.json and enabled-plugin keys. Does
  NOT sync skills or agents (those are user-level — update them by re-running the
  installer). Adds/updates seed-managed items, preserves project additions, skips
  anything marked `seed_managed: false`, never touches CLAUDE.md. Also cleans up
  stale project-level skill/agent copies left by the old push fan-out. Triggers on
  "update seed skills", "sync skills", "sync from seed", "refresh from seed", "pull
  latest tooling", "pull latest docs", "refresh conventions", "update-seed".
seed_managed: true
requires_tools: [bash, gh, jq]
requires_files: [scripts/sync-skills.sh]
---

# Update Seed (project substrate)

You pull the project's stack substrate from the DevHawk seed: reference docs,
scaffold, git hooks, CI workflows, the project scripts that hooks/CI/skills
invoke, and the `.mcp.json` / `enabledPlugins` keys. This runs the bundled
`scripts/sync-skills.sh`.

**Two-tier model (read `docs/seed-distribution.md`).** Operator *skills* are
user-level (Tier 1) — they update by re-running the installer one-liner, **not**
here. This skill owns Tier-2 *substrate* only. The script name
(`sync-skills.sh`) is historical; it no longer syncs skills.

## What this skill does (and doesn't)

**Does:**
- Fetches `fractionwork/devhawk-seed@main` via `gh` (the seed is private — `gh auth login` must be done)
- Syncs every top-level `scripts/*.{sh,mjs,ts,py}` the seed ships **except** the exclusions in `seed-manifest.json` (`scriptsExclude`); project-added scripts are preserved
- Syncs every seed **doc** (`docs/**/*.md`; `release-notes/` + `infographics/` skipped); project docs at other names preserved
- Syncs the **scaffold** in `seed-manifest.json` (`scaffold[]` + auto-discovered `scaffoldAutoDirs[]` like `.githooks/`, `scripts/audit/`), swapping in solo-auth variants for solo projects
- Merges seed `mcpServers` into **`.mcp.json`** (seed wins on collision; project servers preserved)
- Merges seed `enabledPlugins` + `extraKnownMarketplaces` into **`.claude/settings.json`**; `permissions.allow` is appended to (consent-gated) when project-local agents/skills declare `requires_permissions:`; `hooks` and other keys untouched
- Backs up everything it overwrites to `.claude/.backup/<timestamp>/`
- Skips any item whose project copy carries `seed_managed: false`

**Does NOT:**
- Sync **skills or agents** — those are user-level (Tier 1). Update them with the installer:
  `curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash -s -- --profile engineer`
- Touch `CLAUDE.md`, schema, app code, or project-owned files outside the synced categories
- Prompt per-item — overwrite-by-default with backups

## Steps

1. **Verify location.** Confirm the cwd is a project root (`.claude/` or `CLAUDE.md`). If not, ask where to run.

2. **Migration cleanup (one-time for former fan-out consumers).** The old push
   fan-out left copies of the now-user-level operator skills/agents in the
   project's `.claude/skills/` and `.claude/agents/`. Those are stale — the
   canonical copies are at `~/.claude/`. Detect and offer to remove the ones
   that are now provided at user level (backing up first). Skip any with
   `seed_managed: false`:

   ```bash
   ts="$(date +%Y%m%d-%H%M%S)"; bak=".claude/.backup/$ts-migrate"
   for d in .claude/skills/*/; do
     [ -d "$d" ] || continue
     n="$(basename "$d")"
     # present at user level AND not deliberately project-owned?
     if [ -d "$HOME/.claude/skills/$n" ] \
        && ! awk '/^---$/{x++;next} x==1' "$d/SKILL.md" 2>/dev/null | grep -Eq '^seed_managed:[[:space:]]*false'; then
       mkdir -p "$bak/skills"; cp -R "$d" "$bak/skills/$n"; rm -rf "$d"
       echo "  removed stale project skill: $n (now user-level; backup in $bak)"
     fi
   done
   ```

   Do the equivalent for `.claude/agents/*.md` vs `~/.claude/agents/`. Report
   what was removed. If `~/.claude/skills/` is empty (user hasn't installed the
   Tier-1 bundle yet), **do not remove anything** — instead tell them to run the
   installer first, or their project would lose those skills entirely.

3. **Dry run — always run the remote script.** Fetch and run the latest
   `sync-skills.sh` from the seed (avoids the one-cycle lag where a stale local
   copy can't propagate its own improvements):

   ```bash
   bash <(gh api "repos/fractionwork/devhawk-seed/contents/scripts/sync-skills.sh?ref=main" --jq '.content | @base64d') --dry-run
   ```

   Use `bash scripts/sync-skills.sh --source <local-seed-clone>` only when iterating on the seed itself.

4. **Show the plan.** Present the dry-run as a categorized summary (scripts / docs / scaffold / mcp.json / settings — no skills/agents).

5. **Run the sync.** Unless told to stop, run the real sync (same gh-fetched form, no `--dry-run`).

6. **Report.** Per-category counts, backup location, and:
   - Restart Claude Code **only if** `.mcp.json` or `enabledPlugins` changed (those load at session start; docs/scripts/scaffold take effect immediately).
   - Reminder that operator **skills** update via the installer, not here.
   - Suggest committing: `git add .mcp.json .claude/settings.json scripts/ docs/ && git commit -m "chore: sync substrate from devhawk-seed"`

## Options

- `--only <name>...` — sync only specific scripts/docs by name
- `--source <path>` — use a local seed clone (when iterating on the seed)
- `--dry-run` — preview without writing
- `--skip-mcp` / `--skip-settings` / `--skip-docs` / `--skip-scaffold` — skip a category
- `--skip-permissions` — skip the `requires_permissions` scan; `--yes` pre-approves it

## When something should NOT be synced

Add `seed_managed: false` to a doc's frontmatter, or in a comment within the
first 30 lines of a script/scaffold file. The sync skips it on future runs.
For `.mcp.json` / `.claude/settings.json`, only the keys the seed declares are
touched — everything else is preserved automatically.

## Important guidelines

- **Always run the remote sync script via `gh api`** — the local copy may be one
  cycle behind. Don't reimplement the sync logic inline.
- **Never delete project-added** scripts/docs/scaffold — they're intentional.
- **Skills/agents are out of scope here.** If the user wants newer skills, point
  them at the installer one-liner. Don't copy skills into the project.
