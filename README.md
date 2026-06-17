# Fraction DevHawk Skills

Claude Code skills, scripts, agents, and MCP wiring for Fraction's workflow —
board/PM management and (for engineers) PR/fix-merge, build/test, and ops —
installed at the **user level** (`~/.claude/`) so they're consistent across every
project and update in one place.

> This repo is **auto-built** from the [DevHawk seed](https://github.com/fractionwork/devhawk-seed)
> (Fraction's engineering reference stack) by CI on every change. Don't edit it
> directly — edits here are overwritten on the next publish. See the seed's
> `docs/seed-distribution.md` for the full two-tier distribution model.

## Profiles

The installer is role-aware — pick the profile that fits you:

| Profile | Who | Skills installed |
|---|---|---|
| `pm` | Project / Product Managers | Board management only: `add-card`, `add-comment`, `card-done`, `asana-bootstrap`, `asana-hygiene`, `shortcut-hygiene` |
| `engineer` | Fraction engineers | Everything: the PM set **plus** PR/workflow (`create-pr`, `pr-review`, `pr-watch`, `next-task`), build/test (`feature-build`, `test-gen`, `seed-data`), and ops (`do-deploy`, `cost-estimate`, `security-brief`, `bootstrap`, `migrate`, `stack-audit`, …) |

`full` is an alias for `engineer`.

## Prerequisites

- **Claude Code** installed and on your PATH. [Installation guide](https://docs.claude.com/en/docs/claude-code/installation).
- **Python 3** (≥ 3.10 for the Asana MCP). The installer checks this and prints the fix if missing.
- For each PM system you use, an account with permission to read + write cards.

You do **not** need a GitHub account — this bundle is hosted in a public repo.

## Install

One-liner (recommended):

```bash
# PM profile (board management only):
curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash

# Engineer profile (everything):
curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash -s -- --profile engineer
```

Or clone first, to inspect before running:

```bash
git clone https://github.com/fractionwork/pm-skills.git
cd pm-skills
bash install.sh --profile engineer
```

The installer prompts for the profile (if not passed) and which PM systems you
use, copies the relevant skills/scripts/agents into `~/.claude/`, registers the
MCP servers at **user scope**, writes the operating-rules + skill-index block into
`~/.claude/CLAUDE.md` (between managed markers — your own content is preserved),
and sets up token storage at `~/.claude/.env` (chmod 600).

Re-run anytime to update — it's idempotent.

### Useful flags

```bash
bash install.sh --dry-run                       # show what would change, do nothing
bash install.sh --profile pm --systems=asana    # skip both prompts
bash install.sh --profile engineer --systems=asana,shortcut,linear
```

## What gets installed where

- **Skills** → `~/.claude/skills/`
- **Operator scripts** (`asana_ops.py`, `asana_mcp.py`, `shortcut_ops.py`, …) → `~/.claude/scripts/`
- **Agents** (engineer profile, e.g. `pr-watch-reviewer`) → `~/.claude/agents/`
- **MCP servers** (asana / shortcut / linear / atlassian-rovo) → user scope (`claude mcp list`)
- **Operating rules + skill index** → `~/.claude/CLAUDE.md` (between `<!-- BEGIN/END: fraction-pm-skills -->` markers)
- **Tokens** → `~/.claude/.env` (chmod 600 — never commit, never share)

## Two tiers (engineers)

These skills are **operator capability** and live at the user level. The
stack-specific *substrate* they act on — reference docs, scaffold code, git
hooks, CI workflows, and the project scripts (`pnpm pr:audit`, `db-migrate`, …)
— lives **inside each project repo**, not here. Pull the latest substrate into a
project with the `update-seed` skill ("sync from seed"). Operator skills update
here (re-run the installer); project substrate updates there (the pull).

## Token rotation

1. Revoke the token at the source (Asana / Shortcut / Linear settings).
2. Delete the matching line from `~/.claude/.env` (and for Asana OAuth, delete `~/.claude/scripts/.asana-token.json`).
3. Re-run the installer if you want to set a fresh one up.
