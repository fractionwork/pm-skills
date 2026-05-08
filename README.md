# Fraction PM Skills

A small bundle of Claude Code skills + scripts for managing PM cards on Asana, Shortcut, Linear, and Jira — extracted from the [DevHawk seed](https://github.com/fractionwork/devhawk-seed) (Fraction's full engineering reference stack) for use by Project / Product Managers who don't need the dev tooling.

## What's in here

| Component | Purpose |
|---|---|
| `add-card` skill | Create a new card with all Fraction hygiene rules applied at creation time (sections, fields, parent EPIC, source attribution, duplicate detection) |
| `add-comment` skill | Post a comment on a card; converts Markdown to each system's accepted format (Asana's HTML allowlist is enforced — no more silent 400s) |
| `card-done` skill | Close a card with a summary comment; supports both dev-flavored and PM-flavored manual closeouts |
| `asana-hygiene` skill | Audit + fix an Asana project; duplicate-pair detection included |
| `shortcut-hygiene` skill | Same for Shortcut |
| `asana_ops.py` | REST helper for Asana operations the MCP can't do (sections, custom fields, portfolios, comment posting) |
| `shortcut_ops.py` | REST helper for Shortcut |
| Operating-rule memories | Source-attribution discipline, hygiene-at-creation, bulk-notification muting — applied automatically |

## Prerequisites

- **Claude Code** installed and on your PATH. [Installation guide](https://docs.claude.com/en/docs/claude-code/installation).
- **Python 3** with the `requests` module: `pip install --user requests`
- For each PM system you use, an account with permission to read + write cards.

You do **not** need a GitHub account — this bundle is hosted in a public repo so anyone can clone or download.

## Install

One-liner (recommended):

```bash
curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash
```

Or clone first, if you'd like to inspect before running:

```bash
git clone https://github.com/fractionwork/pm-skills.git
cd pm-skills
bash install.sh
```

The installer asks which PM systems you use, copies the relevant skills + scripts into `~/.claude/`, prints the MCP/plugin install commands you need to run, and sets up token storage at `~/.claude/.env` (chmod 600).

Re-run the one-liner (or `bash install.sh` from a clone) after updates — it's idempotent.

### Dry run

```bash
bash install.sh --dry-run
```

Shows exactly what would change without touching anything.

### Skip the prompt

```bash
bash install.sh --systems=asana,shortcut
# or via the one-liner:
curl -sSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/install.sh | bash -s -- --systems=asana,shortcut
```

## Per-system setup

The installer prints the right command for each, but for reference:

| System | Plugin / MCP | Auth |
|---|---|---|
| **Asana** | `claude plugin install asana` | OAuth via Anthropic's Asana app — browser opens on first use |
| **Shortcut** | (no MCP — script only) | Personal token at https://app.shortcut.com/settings/account/api-tokens |
| **Linear** | `claude mcp add linear https://mcp.linear.app/mcp` | OAuth on first use |
| **Jira** | `claude mcp add atlassian-rovo https://mcp.atlassian.com/v1/sse` | OAuth on first use |

## Using the skills

In any Claude Code session, just describe what you want:

- "add a ticket to ELEVAT3 about the failing approver dropdown"
- "comment on card 1234 — tag @Jane and ask for confirmation on the rollout date"
- "close ELEVAT3-87, summary: rolled out 2026-05-08, no incidents"
- "audit the ELEVAT3 project for hygiene issues"

The right skill loads automatically based on what you said.

## Updating

If you used the one-liner: just run it again — the installer always self-fetches the latest version.

If you cloned:

```bash
cd pm-skills
git pull
bash install.sh
```

The installer overwrites the skills + scripts (always-latest wins) and skips memory files that already exist (so your local edits are preserved — delete a memory file before re-installing if you want it refreshed).

## Token rotation

When leaving Fraction or rotating access:

1. Revoke the token at its source (Asana / Shortcut / Linear / Jira settings).
2. Delete the matching line from `~/.claude/.env`.
3. For OAuth plugins, log out via the plugin's settings.

## Troubleshooting

**"Comment failed: 400" when posting to Asana** — the `add-comment` skill should catch this before sending. If it doesn't, the Asana HTML allowlist may have changed. Check https://developers.asana.com/reference/rich-text against `~/.claude/skills/add-comment/SKILL.md` Step 3 and report a mismatch.

**Asana script can't authenticate** — the script defaults to OAuth via Anthropic's app. If that's failing, set `ASANA_PAT=<token>` in `~/.claude/.env` (generate at https://app.asana.com/0/my-apps).

**Skill doesn't trigger on the phrase I tried** — open `~/.claude/skills/<skill>/SKILL.md` and check the trigger phrases in the description. Add your phrase to your own copy if it should match.

**Need a Linear or Jira hygiene skill** — file a request at the source repo. The current bundle has Asana and Shortcut hygiene only; Linear / Jira will follow as those systems get more Fraction usage.

## Source of truth

This bundle is generated from the [DevHawk seed](https://github.com/fractionwork/devhawk-seed) — skills are authored there and projected here via `scripts/build-pm-bundle.sh`. Direct edits to this bundle's contents will be overwritten on the next build. File issues / PRs against the seed.

## License

Internal Fraction tooling. Distributed for use by Fraction Project and Product Managers.
