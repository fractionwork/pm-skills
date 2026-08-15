---
name: pm-setup
description: >-
  ASANA-DIRECT setup — install pm-kit's Python runtime and authenticate with YOUR
  OWN Asana account. Creates a virtualenv at ~/.devhawk/pm, installs the MCP SDK,
  and walks the Asana OAuth flow (or accepts a PAT). Needed for asana-bootstrap
  and asana-hygiene, and for any Asana board a factory does not manage. NOT needed
  to manage a board through a factory engine — that is /factory-connect, which
  needs no Python and works on Linear and Azure DevOps too. Run this whenever a
  skill reports "no Asana credential", "the mcp package is missing", or the Asana
  MCP server fails to start. Triggers on "connect Asana", "authenticate Asana",
  "asana not connected", "install the PM tools", "/pm-setup".
allowed-tools: Bash(${CLAUDE_SKILL_DIR}/scripts/pm-setup.sh:*)
---

# pm-kit setup — the Asana-direct path

Everything else in this kit installs with the plugin. This is the exception: a plugin can ship a
Python MCP server but cannot build the environment to run it, so that one step stays explicit.

> **Check this is the path you want first.** This sets up board access under
> **your own Asana account**. If the board belongs to a project registered with a
> factory engine, you want **`/factory-connect`** instead: no Python, no OAuth, no
> credential on this machine, and it works on Linear and Azure DevOps as well as
> Asana. See `${CLAUDE_PLUGIN_ROOT}/skills/_shared/board-surface.md`.
>
> You still need this one for `asana-bootstrap` and `asana-hygiene`, whose
> structural work — creating custom fields, sections, enum options, workspace
> tags — no MCP can do, and for any Asana board no factory knows about.

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

   Idempotent — it skips work already done. Flags: `--deps-only` (skip the app + auth steps),
   `--reauth` (replace an existing credential), `--client-id` / `--client-secret` (supply the
   OAuth app without being asked).

   **It will ask for an Asana OAuth app** unless one is already configured or a PAT is set. The
   app is not shipped with the plugin — hardcoding it once published a client secret to a public
   marketplace and tied the kit to a single Asana app. Point the user at
   <https://app.asana.com/0/my-apps>; the redirect URI must be `http://localhost:8372/callback`.
   It is stored at 0600 in `~/.devhawk/pm/workspace.json`, merged alongside any `requiredFields` /
   `requiredAdmins` already there.

   **Run from here, this asks in a browser, not the terminal.** Your Bash tool gives the script no
   controlling terminal, so it opens a small form on `localhost:8372` and waits (5 min) while the
   user pastes the Client ID and secret into it. Tell them to expect that window. When it closes,
   the Asana sign-in opens straight after.

   > **Never ask for the client secret in chat and pass it as `--client-secret`.** That writes a
   > live credential into the conversation transcript and into the machine's `ps` output. The form
   > exists precisely so the secret goes browser → script → 0600 file and nowhere else. The flags
   > are for scripted installs where the value is already in a secret store.

   If they have no app and don't want to create one, a personal access token skips OAuth
   entirely — `export ASANA_PAT=<token>`.

3. **Tell the user to restart Claude Code.** The Asana MCP server is registered by the plugin's
   `.mcp.json` and is only started at session start, so it will not appear in the current session
   no matter what this script does. Skipping this line is the single most common reason setup
   "didn't work".

4. **Confirm** by asking the user to run `/asana-hygiene` or `/add-card` in the new session.

## Auth options

- **OAuth (default)** — opens a browser, stores a refreshable token at
  `~/.devhawk/pm/asana-token.json` (0600). Right for a normal user account.
- **PAT** — `export ASANA_PAT=<token>`; the setup detects it and skips both the app prompt and
  OAuth. Right for guest or service accounts, and for headless machines where no browser can open.

How the OAuth app itself is collected depends on where the script is run:

| Context | How it asks |
|---|---|
| Inside Claude Code (no TTY) | Browser form on `localhost:8372`, 5-minute wait |
| A real terminal | Prompts inline; the secret is read with `read -s`, no echo |
| Scripted / unattended | Flags or environment, never prompts |

Scripted installs pass the app on the command line or in the environment — appropriate only when
the value already comes from a secret store, since both are visible to `ps`:

```bash
pm-setup.sh --client-id <id> --client-secret <secret>
ASANA_CLIENT_ID=<id> ASANA_CLIENT_SECRET=<secret> pm-setup.sh
```

Credentials are written to `~/.devhawk/pm/`, never inside the plugin — the plugin directory is
content-hash addressed and is replaced on every update, which would silently discard a token
stored there. A credential left over from the pre-plugin installer at `~/.claude/.asana-token.json`
is still read, so an existing user does not have to re-authenticate.

### Hard rules

- **Never print, echo, or log the token or the client secret**, and never include either in an
  error message, a URL, or a command you show the user. If a command would surface one, redirect
  that output. Don't read `workspace.json` back to the user to "confirm" it saved — `--check`
  reports whether an app is configured without revealing it.
- Don't run this unprompted as a fix for an unrelated failure. If a board skill fails, run
  `--check` first and report what it says — reinstalling a working runtime hides the real error.
- Don't offer to `pip install --user` or otherwise write outside `~/.devhawk/pm`.

### Success looks like

`--check` reports `✓` for interpreter, runtime, OAuth app (or "not needed — using a PAT") and
credential; the user has restarted Claude Code; a board skill completes a real call against their
workspace.

A `⊙ workspace config: none` is **not** a failure — the board skills work without it and simply
skip the field/admin policy. Mention it once, point at `workspace.example.json`, and move on.
