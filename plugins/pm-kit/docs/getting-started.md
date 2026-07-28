# Getting started with pm-kit

Install → connect Asana → create your first card, end to end. No repository or GitHub account is
required; this kit manages boards, not code.

---

## 1. Prerequisites

- **Claude Code.**
- **Python ≥ 3.10** — the Asana MCP server needs it. `python3 -V` to check. Several distributions
  still ship 3.9 as `python3`; the setup detects that and tells you.
  - macOS: `brew install python@3.12` (the Xcode command-line tools' python3 also works if it's
    3.10+)
  - Debian / Ubuntu / **WSL**: `sudo apt install python3 python3-venv`
- **An Asana account** with access to the boards you want to manage. A regular user account gets
  OAuth; guest and service accounts use a personal access token.

You do **not** need `git`, `gh`, or an SSH key. pm-kit is published to a public marketplace, which
Claude Code fetches without credentials.

### On WSL

Two packages that aren't there by default, both of which fail confusingly:

- **`python3-venv`** — Ubuntu splits the `venv` module out of `python3`. Without it `/pm-setup`
  dies at `python3 -m venv` with "ensurepip is not available", which reads like a Python bug.
- **A way to open a browser** — with neither `wslview` (from `wslu`) nor a desktop, Python's
  `webbrowser.open()` finds no handler and returns quietly, so the OAuth step looks like a hang.
  `/pm-setup` handles this for you: on WSL with no `wslview` it points `BROWSER` at
  `explorer.exe`, which interop always puts on `PATH`. WSL2 forwards `localhost:8372` back to
  Linux on its own, so the callback works once a browser opens.

  Want `wslview` anyway? It's in Ubuntu's **universe** component, so
  `E: Unable to locate package wslu` means universe isn't enabled rather than the package being
  gone: `sudo add-apt-repository universe && sudo apt update && sudo apt install -y wslu`.

Either way, a personal access token skips the browser entirely:

```bash
export ASANA_PAT=<token>     # app.asana.com → My settings → Apps
```

You may also see pip refuse to install anything system-wide (`externally-managed-environment`,
PEP 668) on Ubuntu 24.04+. That's expected, and it's exactly why `/pm-setup` builds a venv at
`~/.devhawk/pm/venv` instead of installing globally. Nothing to fix.

---

## 2. Install

```
/plugin marketplace add fractionwork/pm-skills
/plugin install pm-kit@pm-skills
```

Then **restart Claude Code**. The Asana MCP server is registered by the plugin and is only started
at session start.

<details>
<summary>From a local checkout instead</summary>

```
/plugin marketplace add /path/to/software-factory-tools
/plugin install pm-kit@software-factory-tools
```

Or without the plugin system at all — symlinks the skills into `~/.claude/skills`:

```bash
projects/pm-kit/install.sh          # --uninstall to remove
```

The symlink path does not register the MCP server; skills fall back to `asana_ops.py`, which is
the documented behaviour for "MCP not connected".
</details>

---

## 3. Connect Asana

```
/pm-setup
```

This builds a Python environment at `~/.devhawk/pm/`, asks for your Asana OAuth app, and opens a
browser to log in. Idempotent — re-run any time to upgrade or re-check state.

**The OAuth app.** Get it from <https://app.asana.com/0/my-apps>; the redirect URI must be
`http://localhost:8372/callback`. The setup stores it at 0600 in `~/.devhawk/pm/workspace.json`
and reads the secret without echoing it. It is deliberately not shipped with the plugin — a
hardcoded one would be published to a public marketplace, and would tie the kit to a single Asana
app.

Supply it up front to skip the prompt:

```
/pm-setup --client-id <id> --client-secret <secret>
```

To see what's missing without changing anything:

```
/pm-setup --check
```

**Restart Claude Code again** after the first run.

**No app, headless machine, or a guest/service account?** A personal access token skips the app
prompt and OAuth entirely:

```bash
export ASANA_PAT=<token>     # app.asana.com → My settings → Apps
```

Credentials are written to `~/.devhawk/pm/` at mode 0600 — never inside the plugin directory,
which is replaced on every update. If you used the old `curl | bash` installer, your existing
token at `~/.claude/scripts/.asana-token.json` is still read; you don't need to re-authenticate.

---

## 4. Your first card

```
add a ticket to <project> about the login page timing out on slow connections
```

`add-card` will resolve the project, check for duplicates before creating anything, ask for
whatever required fields it can't infer, and stamp source attribution. It creates the card
**top-level** — never as a subtask, because Asana cannot move a subtask between board sections, so
a subtask can never flow INBOX → DONE.

---

## 5. What else is here

| Say this | Skill |
|---|---|
| "add a ticket", "log a bug", "track this" | `add-card` |
| "comment on card X", "@mention someone on the ticket" | `add-comment` |
| "clean up the board", "audit the project", "enrich the backlog" | `asana-hygiene` |
| "create an Asana project", "set up a board" | `asana-bootstrap` |
| same, for Shortcut | `shortcut-hygiene` |

The board standard these enforce — required admins, the 8 custom fields, the 8 sections, the
flat-task model — is written down in `skills/_shared/asana-conventions.md`.

---

## 6. The rules that apply automatically

Two standing rules fire on every board operation without being asked, and both are enforced in
the MCP server rather than left to memory:

- **Source attribution** — a card change records what prompted it, as a `Source:` line *and* a
  comment. The server requires a `source` argument on state-changing tools and posts it to the
  card, so the trail exists even if no skill was loaded.
- **Bulk muting** — batches past 5 writes automatically mute notifications, so a bookkeeping sweep
  doesn't land 35 simultaneous emails in the team's inboxes.

Full text: `skills/_shared/operating-rules.md`.

---

## Troubleshooting

**"no Asana credential found" / the MCP server won't start.** Run `/pm-setup --check`. If all
three lines are `✓`, you almost certainly haven't restarted Claude Code since installing.

**"the mcp and requests packages are missing".** The venv didn't build. Re-run `/pm-setup` and
read the pip output — on Debian/Ubuntu this is usually a missing `python3-venv`.

**A skill can't find an Asana tool.** Check whether Anthropic's official `asana` plugin is also
enabled — it registers under the same name and collides. Disable it; pm-kit's server is curated,
project-scoped, and keeps the token in our own code.

**"move_task_to_section requires a `source`".** Working as intended — say what prompted the move.
This is Rule 1 enforced in code.

**You changed directory and everything looks logged out.** That was the pre-plugin behaviour (the
token path used to be relative to the working directory) and is fixed. If you still see it, you're
running the old installer's copy — remove it with the installer's uninstall path.

See also: `../README.md`, `skills/_shared/asana-conventions.md`, `skills/_shared/operating-rules.md`.
