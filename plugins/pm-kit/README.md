# pm-kit

A Claude Code **plugin** for project-board management, with Fraction hygiene applied at the moment
a card is written rather than cleaned up afterwards.

**New here?** See **[docs/getting-started.md](docs/getting-started.md)** — install → connect Asana
→ first card, end to end.

It ships a first-party Asana MCP server, so the skills work against a curated, project-scoped tool
surface that keeps the token in our own code. No repository or GitHub account is needed to use it.

## Install

pm-kit is published to a **public** marketplace, so it installs with no git credentials — no SSH
key, no `gh auth login`:

```
/plugin marketplace add fractionwork/pm-skills
/plugin install pm-kit@pm-skills
```

Then restart Claude Code and run `/pm-setup` once to build the Python runtime and authenticate.

From this monorepo instead (engineers, who have access anyway):

```
/plugin marketplace add fractionwork/software-factory-tools
/plugin install pm-kit@software-factory-tools
```

Symlink fallback — no plugin system at all:

```bash
projects/pm-kit/install.sh            # --uninstall to remove
```

> The symlink path does **not** register the MCP server — `.mcp.json` is read by the plugin
> loader. Skills fall back to `asana_ops.py`, which is the documented "MCP not connected"
> behaviour.

### Runtime

`/pm-setup` creates a virtualenv at `~/.devhawk/pm/`, installs the MCP SDK, and walks Asana OAuth
(or accepts `ASANA_PAT` for guest/service accounts and headless machines). It is idempotent, and
`--check` reports status without changing anything.

Everything it writes lives **outside** the plugin directory on purpose: the plugin root is
content-hash addressed and replaced wholesale on every update, so a venv or token stored there
would be destroyed by the next `/plugin marketplace update`.

## Skill catalog

| Skill | Purpose |
|---|---|
| `add-card` | Create ONE card correctly — INBOX vs BACKLOG, Feature, standard fields, duplicate check, source attribution, audit marker. Never a subtask. |
| `add-comment` | Post a comment in the format each system accepts — Asana's narrow HTML allowlist is validated before the call, so no silent 400 |
| `asana-bootstrap` | Stand up a new Asana project already compliant: admins, 8 custom fields, 8 sections, metadata, optional EPIC scaffold |
| `asana-hygiene` | Audit an existing board and fix what can be fixed; report the rest |
| `pm-setup` | Build the Python runtime and authenticate — run once after install |

`skills/_shared/` (no `SKILL.md` — not itself a skill) holds the runtime the skills share:
`asana_ops.py`, the `asana_mcp.py` server, the board
conventions (`asana-conventions.md`, `backlog-format.md`) and
`operating-rules.md`.

## Rules enforced in code, not just written down

The operating rules used to be prose spliced into `~/.claude/CLAUDE.md`, which a direct tool call
with no skill loaded never saw. The two that can be enforced now are:

- **Rule 1 — source attribution.** `move_task_to_section`, `assign_task` and `capture_inbox_idea`
  require a `source` argument and post it to the card as a comment, so a state change carries its
  own audit trail. `add_comment` deliberately doesn't: a comment *is* the trail.
- **Rule 3 — bulk muting.** Past `ASANA_BULK_THRESHOLD` writes (default 5), the server sets
  Asana's `silent=true` automatically. Singles still notify, so a real assignment reaches someone.

A `SessionStart` hook injects a short summary of both as session context; the full text is read on
demand from `skills/_shared/operating-rules.md`.

## Layout

```
.claude-plugin/plugin.json     # manifest (deliberately unversioned — see below)
.mcp.json                      # the first-party Asana MCP server
hooks/                         # SessionStart operating-rules injection
skills/<skill>/SKILL.md        # the skill definitions (this is what installs)
skills/_shared/*               # shared runtime + board conventions + operating rules
packages/harness/              # monorepo-only: vitest tests for the wiring and runtime
docs/                          # getting-started
```

`packages/harness` exists so `moon check --all` covers the kit's deterministic behaviour in CI; it
is not part of the installed plugin and the skills never reference it.

## Compatibility

macOS and Linux. Shell scripts are bash with no bash-4 features (macOS still ships 3.2) and no
GNU-only utility flags — script directories resolve through a portable symlink-following idiom
rather than `readlink -f`, and direct, file-symlink and directory-symlink invocation are all
tested. Python is ≥ 3.10, checked by version rather than by the name `python3`.

## Updating & versioning

`plugin.json` intentionally **omits a pinned `version`**, so Claude Code resolves it from the git
commit and every merged change propagates. (A pinned version freezes installed copies at that
string until it's bumped — updates would silently not reach users.)

```
/plugin marketplace update pm-skills      # there is no /plugin update
```

Re-run `/pm-setup` after an update if the dependencies changed; it's idempotent.

**Migrating from the `curl | bash` installer?** Run the cleanup script this kit ships — it removes
the installer's 24 skills, its agent, its Python runtime, the stale `SessionStart` hook and the
block it spliced into `~/.claude/CLAUDE.md`, backing everything up first:

```bash
skills/_shared/migrate-from-installer.sh            # dry run
skills/_shared/migrate-from-installer.sh --apply
```

It removes **by name**, so it can't take out skills the installer never put there, and it keeps
`.asana-token.json` — you stay logged in. Full walkthrough in
[docs/claude-plugins.md](../../docs/claude-plugins.md#migrating-off-the-old-installer).

You will need to re-authenticate regardless: the Asana OAuth client secret was rotated, so run
`/pm-setup --reauth` afterwards.
