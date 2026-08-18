# Changelog — pm-kit

## Unreleased

- **feat: `milestone-mapper`.** Generates a standalone, self-contained HTML milestone
  tracker — Release Notes, a Gantt, the priority roadmap, what is on the radar and what is
  blocked — from the project board and, where connected, Fireflies transcripts. Written by
  Alyssia and previously a project-level skill in her own workspace; promoted here so the
  team installs it the same way as everything else.

  Ported from `fractionwork/pm-skills#1`, which could not have survived: pm-kit is authored
  here and MIRRORED to that repo by `pm-kit-publish.yml`, whose own commit message says
  direct edits there are overwritten. Adapted on the way in — it now resolves the factory
  vs Asana-direct surface like every other board skill, reads **Asana and Linear** and
  claims nothing else, groups by the factory's `pm.themes` rather than scraping a custom
  field, and opens a PR instead of pushing generated output to `main`.

Initial extraction from `devhawk-seed` as a Claude Code plugin. The five board skills are
unchanged in substance; what changed is how they are distributed, how they find their runtime,
and which of the operating rules are enforced rather than merely written down.

- **feat: `add-card` says whether the factory will actually pick the card up.** It does NOT create
  a second card — the factory intakes from the board, and a second create is the duplication the
  dedup step exists to prevent. It reports the intake gate instead, which is the common surprise:
  a card sits on the board looking fine and nothing ever happens to it because it carries no
  `Release` value. Registration is the opt-in; unregistered projects see no change.

- **feat: ship as a plugin instead of an installer.** `/plugin install pm-kit@pm-skills` replaces
  a 817-line `install.sh` that reimplemented config-dir resolution, legacy symlink migration,
  Python discovery, venv bootstrap, profile filtering, and marker-splicing into
  `~/.claude/CLAUDE.md`. The `profiles: [pm, engineer]` frontmatter that drove the filtering is
  gone too — installing a plugin *is* the profile choice. What survives is `pm-setup` (~120
  lines), which does the one thing a plugin genuinely cannot: build a Python environment.

- **feat: bundle the Asana MCP via `.mcp.json`** pointing at `${CLAUDE_PLUGIN_ROOT}`, so the
  server arrives with the plugin instead of needing `claude mcp add --scope user`.
  **Its tools are namespaced `mcp__plugin_pm-kit_asana__*`, not the old `mcp__asana__*`.**
  Accordingly, no SKILL.md names a fully-qualified tool id any more — they refer to tools by
  bare name ("the Asana MCP's `add_comment`"), which is also what lets the same skills keep
  working against a Shortcut or Linear MCP. A test enforces the absence of `mcp__…__` ids,
  because this failure mode is silent: the model simply cannot find the tool.

- **feat: enforce operating Rules 1 and 3 in the MCP server, not just in prose.** The rules used
  to live only as text spliced into `~/.claude/CLAUDE.md`, which a direct tool call with no skill
  loaded never saw — the exact path that once produced an unauditable batch of card edits.
  Now `move_task_to_section`, `assign_task` and `capture_inbox_idea` **require a `source`
  argument** and post it to the card as a comment, and writes past a threshold
  (`ASANA_BULK_THRESHOLD`, default 5) automatically pass Asana's `silent=true`.
  `add_comment` deliberately takes no `source` — a comment *is* the audit trail, so requiring
  attribution in order to leave attribution would be circular.

  > **Breaking for callers.** `move_task_to_section` and `assign_task` gained a required
  > parameter. The callers are `next-task`, `card-done` and `create-pr`, which are moving to
  > `ship-kit` — they must pass `source` when they land there.

- **feat: `SessionStart` hook** injects a ~1,000-character summary of the operating rules as
  session context, replacing the installer's `~/.claude/CLAUDE.md` splice. The rules now version
  and roll back with the plugin that owns them, and uninstalling the plugin removes them instead
  of leaving prose behind. Rule 2 ("card creation runs full hygiene") was **deleted** rather than
  ported: it is already stated by `add-card`'s own description, and a second copy is a copy that
  drifts.

- **fix: credential paths are absolute.** `TOKEN_FILE` defaulted to the *relative*
  `.asana-token.json`, which was fine for a repo-rooted script and wrong for a plugin — it
  resolves to a different file in every directory, so the user appears logged out whenever they
  `cd`. Now `~/.devhawk/pm/`, deliberately outside `${CLAUDE_PLUGIN_ROOT}` because the plugin
  directory is content-hash addressed and replaced wholesale on every update, which would discard
  the token. A credential left by the old installer at `~/.claude/scripts/.asana-token.json` is
  still read, so existing users are not logged out. Run artifacts (`asana_cleanup.log`,
  `asana_cleanup_report.md`) moved out of the cwd for the same reason.

- **fix: credentials are written 0600.** Writes route through one `_write_private` helper that
  creates the parent directory and chmods. The installer did the chmod separately and missed
  paths — tokens written by it are sitting on disk at 0644.

- **fix: a missing Python runtime fails legibly.** `.mcp.json` cannot probe for a venv, so a
  `pm-python.sh` wrapper resolves the interpreter (explicit override → `~/.devhawk/pm/venv` →
  a system python that can already `import mcp, requests`) and otherwise prints the one-line fix.
  Previously this surfaced as a `ModuleNotFoundError` buried in MCP startup logs, which Claude
  Code shows only as "server exited". `pm-setup` also checks for Python **≥ 3.10** by version
  rather than trusting `python3`, since several distros still ship 3.9 there and the MCP SDK
  fails on it with an opaque syntax error.

- **change: the board conventions moved into the kit.** `asana-best-practices.md`,
  `shortcut-best-practices.md` and `backlog-format.md` were filed under the seed's `docs/` as if
  they were project documentation, but no project ever read them — they are skill references.
  They now live in `skills/_shared/` as `asana-conventions.md`, `shortcut-conventions.md` and
  `backlog-format.md`. Kept as three files rather than merged so the `→ "Section"` anchors the
  skills cite still resolve.

- **change: `ado-asana-sync` is not carried over.** The Azure DevOps → Asana mirror (the skill
  plus `ado_asana_sync.py` and `ado_auth.py`, ~895 lines) was added mid-2026 for one engagement,
  is one-way only, and is scoped to a hand-configured set of people. It is a separate concern from
  board hygiene, and bundling it made every pm-kit user carry an ADO PAT store they had no use
  for. Recoverable from `devhawk-seed@7242804` if it needs to come back as its own plugin.

- **test: a harness, where there was none.** 53 tests covering credential resolution (including
  the legacy path and the 0600 mode), the Rule 1/3 guards, the hook's output contract and size,
  manifest validity, and skill-frontmatter hygiene. The distribution machinery this replaces had
  2,135 lines and zero tests.
