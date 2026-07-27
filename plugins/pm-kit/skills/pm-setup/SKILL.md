---
name: pm-setup
description: >-
  Install pm-kit's Python runtime and authenticate against Asana — the one-time
  setup the board skills need. Creates a virtualenv at ~/.devhawk/pm, installs the
  MCP SDK, and walks the Asana OAuth flow (or accepts a PAT). Run this right after
  installing pm-kit, or whenever a skill reports "no Asana credential", "the mcp
  package is missing", or the Asana MCP server fails to start. Triggers on "set up
  pm-kit", "install the PM tools", "connect Asana", "authenticate Asana", "asana
  not connected", "/pm-setup".
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/pm-setup.sh:*)
---

# pm-kit setup

Everything else in this kit installs with the plugin. This is the exception: a plugin can ship a
Python MCP server but cannot build the environment to run it, so that one step stays explicit.

## Steps

1. **Check what's actually missing** before changing anything:

   ```bash
   ${CLAUDE_SKILL_DIR}/scripts/pm-setup.sh --check
   ```

   Reports three lines — interpreter, runtime, credential. If all three are `✓`, say so and stop;
   the likely real problem is that Claude Code hasn't been restarted since the plugin install.

2. **Run the setup** for whatever is missing:

   ```bash
   ${CLAUDE_SKILL_DIR}/scripts/pm-setup.sh
   ```

   Idempotent — it skips work already done. Flags: `--deps-only` (skip auth, e.g. when a PAT
   comes from the environment), `--reauth` (replace an existing credential).

3. **Tell the user to restart Claude Code.** The Asana MCP server is registered by the plugin's
   `.mcp.json` and is only started at session start, so it will not appear in the current session
   no matter what this script does. Skipping this line is the single most common reason setup
   "didn't work".

4. **Confirm** by asking the user to run `/asana-hygiene` or `/add-card` in the new session.

## Auth options

- **OAuth (default)** — opens a browser, stores a refreshable token at
  `~/.devhawk/pm/asana-token.json` (0600). Right for a normal user account.
- **PAT** — `export ASANA_PAT=<token>`; the setup detects it and skips OAuth. Right for guest or
  service accounts, and for headless machines where no browser can open.

Credentials are written to `~/.devhawk/pm/`, never inside the plugin — the plugin directory is
content-hash addressed and is replaced on every update, which would silently discard a token
stored there. A credential left over from the pre-plugin installer at `~/.claude/.asana-token.json`
is still read, so an existing user does not have to re-authenticate.

### Hard rules

- **Never print, echo, or log the token**, and never include it in an error message, a URL, or a
  command you show the user. If a command would surface it, redirect that output.
- Don't run this unprompted as a fix for an unrelated failure. If a board skill fails, run
  `--check` first and report what it says — reinstalling a working runtime hides the real error.
- Don't offer to `pip install --user` or otherwise write outside `~/.devhawk/pm`.

### Success looks like

`--check` reports `✓` for interpreter, runtime and credential; the user has restarted Claude Code;
a board skill completes a real call against their workspace.
