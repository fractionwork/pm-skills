#!/usr/bin/env python3
"""
Asana workspace operations — cleanup, hygiene, and admin tasks that
Asana MCP can't do (archive, custom fields, portfolios, sections).

Auth: PKCE OAuth (recommended) or PAT fallback.

Usage:
  # First-time auth (opens browser, stores token locally):
  python3 <pm-kit>/skills/_shared/asana_ops.py --auth
  python3 <pm-kit>/skills/_shared/asana_ops.py --hygiene <PROJECT_GID>

Run with no arguments for the full command list.
"""

import argparse
import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.parse
import webbrowser
from datetime import datetime
from pathlib import Path

import requests

# ── Config ──
BASE = "https://app.asana.com/api/1.0"
# All network calls carry a timeout so a stalled connection (corporate proxy,
# captive portal, DNS hang) can never block forever — critical when this module
# is imported by the stdio MCP server, where a hang stalls Claude Code's startup.
HTTP_TIMEOUT = 30      # token exchange + REST calls
UPLOAD_TIMEOUT = 120   # attachment uploads (larger payloads)
# Fraction DevHawk OAuth app — hardcoded like GitHub CLI does.
# Client ID is public by design; client secret is required by Asana's
# token exchange but is not truly secret in a CLI (source is readable).
# Security comes from the user's browser consent + PKCE verifier.
# The OAuth app identity is NOT shipped. It used to be hardcoded here, which
# meant it travelled into the public pm-skills marketplace — and it also meant
# this module only ever worked against one Asana app.
#
# Resolution: env → ~/.devhawk/pm/workspace.json → absent. Absent is fine: the
# PAT path (ASANA_PAT / ASANA_ACCESS_TOKEN) needs no app registration at all,
# and OAuth reports what to set rather than failing obscurely.
def _oauth_app() -> tuple:
    """(client_id, client_secret) — env wins, then workspace.json, then empty."""
    cfg = _workspace_config().get("oauth", {})
    return (os.environ.get("ASANA_CLIENT_ID") or cfg.get("clientId", ""),
            os.environ.get("ASANA_CLIENT_SECRET") or cfg.get("clientSecret", ""))
ASANA_AUTH_URL = "https://app.asana.com/-/oauth_authorize"
ASANA_TOKEN_URL = "https://app.asana.com/-/oauth_token"
CALLBACK_PORT = 8372
# Where credentials and the persisted workspace choice live.
#
# These MUST default to absolute paths. As a plugin, this module is invoked from
# whatever directory the user happens to be in, and the MCP server (asana_mcp.py)
# is a long-running process whose cwd is not meaningful — a relative default like
# the old ".asana-token.json" silently resolves to a different file per project,
# so the user appears logged out whenever they change directory. It also must not
# live under the plugin root: that directory is content-hash addressed and is
# replaced wholesale on every plugin update, which would discard the token.
#
# Resolution order, highest first:
#   1. the explicit env override (an embedder pointing at its own store)
#   2. the current location, ~/.devhawk/pm/
#   3. the legacy installer location — read-only back-compat so anyone who
#      authenticated before the plugin migration stays logged in
# A fresh login writes to (2).
#
# The legacy path is ~/.claude/scripts/.asana-token.json, NOT ~/.claude/: the
# old installer passed its own SCRIPTS_DIR through ASANA_TOKEN_FILE when it ran
# `claude mcp add` (install.sh:523). Getting this wrong silently logs every
# pre-migration user out, which looks like the plugin being broken.
_PM_HOME = Path.home() / ".devhawk" / "pm"
_LEGACY_HOME = Path.home() / ".claude" / "scripts"


def _write_private(path: Path, text: str) -> None:
    """Write a credential/artifact, creating its directory first.

    Credentials land at 0600. Doing this here rather than at each call site
    means a token can never be written world-readable by a path that forgot to
    chmod — the old installer did the chmod separately and only for some files.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    try:
        path.chmod(0o600)
    except OSError:
        pass  # best-effort: some filesystems (mounted shares) refuse chmod


def _cred_path(env_var: str, filename: str) -> Path:
    override = os.environ.get(env_var)
    if override:
        return Path(override).expanduser()
    current = _PM_HOME / filename
    if current.exists():
        return current
    legacy = _LEGACY_HOME / f".{filename}"
    if legacy.exists():
        return legacy
    return current


TOKEN_FILE = _cred_path("ASANA_TOKEN_FILE", "asana-token.json")
WORKSPACE_CONFIG = _cred_path("ASANA_WORKSPACE_CONFIG", "workspace.json")


def _workspace_config() -> dict:
    """Workspace-specific settings, loaded once from ~/.devhawk/pm/workspace.json.

    Custom-field GIDs, the required-admin list and the OAuth app identity are all
    specific to ONE Asana workspace. Hardcoding them shipped our workspace's ids
    (and an OAuth client secret) to every user, and made the kit unusable against
    any other workspace. See workspace.example.json for the shape.
    """
    global _WS_CACHE
    if _WS_CACHE is None:
        try:
            _WS_CACHE = json.loads(WORKSPACE_CONFIG.read_text())
        except (OSError, ValueError):
            _WS_CACHE = {}
    return _WS_CACHE


_WS_CACHE = None


def required_fields() -> dict:
    """{gid: name} for the custom fields every project must carry.

    From config when present. Otherwise empty — callers degrade to reporting
    that no field policy is configured rather than attaching another
    workspace's field GIDs, which would fail with an opaque 400.
    """
    return _workspace_config().get("requiredFields", {})


def required_admins() -> list:
    """[{name, gid, email}] — who must be an Admin on every project."""
    return _workspace_config().get("requiredAdmins", [])


class AsanaAuthError(Exception):
    """No usable Asana credential (neither OAuth token nor PAT). Raised by
    get_token() so embedders can handle it; the CLI catches it at the bottom."""


class AsanaWorkspaceError(Exception):
    """Workspace can't be resolved — the account has multiple workspaces and
    none was selected (no ASANA_WORKSPACE, no saved choice). The user must pick
    once. Caught by the CLI; the MCP server reports it and exits."""


# Persisted workspace choice — so a multi-workspace user picks ONCE and both the
# CLI and the MCP server reuse it. Same resolution rules as TOKEN_FILE.
WORKSPACE_FILE = _cred_path("ASANA_WORKSPACE_FILE", "asana-workspace.json")
# Run artifacts. Absolute for the same reason as the credential paths — as a
# plugin these would otherwise litter whatever directory the user invoked from.
LOG_FILE = _PM_HOME / "asana_cleanup.log"
REPORT_FILE = _PM_HOME / "asana_cleanup_report.md"

# Rate limiting
CALLS = 0
ERRORS = 0
START_TIME = None


# ═══════════════════════════════════════════════════════
# PKCE OAuth flow
# ═══════════════════════════════════════════════════════

def get_client_id():
    """OAuth client id — env, then ~/.devhawk/pm/workspace.json. Never shipped."""
    return _oauth_app()[0]


def generate_pkce():
    """Generate PKCE code_verifier and code_challenge (S256)."""
    verifier = secrets.token_urlsafe(96)[:128]
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")
    return verifier, challenge


CONFIG_FORM = """<!doctype html>
<meta charset="utf-8"><title>Connect Asana</title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
 body{font:15px/1.5 system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1.25rem;
      color:#111;background:#fff}
 @media (prefers-color-scheme:dark){body{color:#eee;background:#161616}
   input{background:#222;color:#eee;border-color:#444}}
 h1{font-size:1.3rem;margin-bottom:.25rem}
 p.sub{margin-top:0;color:#666}
 label{display:block;margin:1.1rem 0 .3rem;font-weight:600}
 input{width:100%%;padding:.6rem;font-size:1rem;border:1px solid #ccc;border-radius:6px;
       box-sizing:border-box;font-family:ui-monospace,monospace}
 button{margin-top:1.5rem;padding:.65rem 1.4rem;font-size:1rem;border:0;border-radius:6px;
        background:#2b6cb0;color:#fff;cursor:pointer}
 .err{background:#fdd;border-left:3px solid #c00;padding:.6rem .8rem;border-radius:4px;color:#900}
 code{background:#8881;padding:.1rem .35rem;border-radius:3px}
 ol{color:#666;font-size:.92rem;padding-left:1.2rem}
</style>
<h1>Connect Asana</h1>
<p class="sub">These stay on this machine. Nothing is sent anywhere but Asana.</p>
%(error)s
<ol>
  <li>Open <a href="https://app.asana.com/0/my-apps" target="_blank">app.asana.com/0/my-apps</a></li>
  <li>Use an existing app, or create one</li>
  <li>Set its redirect URL to <code>http://localhost:%(port)d/callback</code></li>
  <li>Copy the Client ID and Client secret in below</li>
</ol>
<form method="POST" action="/configure?t=%(token)s">
  <label for="cid">Client ID</label>
  <input id="cid" name="client_id" autocomplete="off" autofocus required>
  <label for="cs">Client secret</label>
  <input id="cs" name="client_secret" type="password" autocomplete="off" required>
  <button type="submit">Save and continue</button>
</form>
"""

CONFIG_DONE = """<!doctype html>
<meta charset="utf-8"><title>Saved</title>
<style>body{font:15px/1.5 system-ui,sans-serif;max-width:34rem;margin:3rem auto;padding:0 1.25rem}
@media (prefers-color-scheme:dark){body{color:#eee;background:#161616}}</style>
<h2>Saved.</h2>
<p>Asana sign-in opens next — you can leave this tab.</p>
"""


def save_oauth_app(client_id: str, client_secret: str) -> None:
    """Merge the OAuth app into workspace.json without disturbing other blocks.

    The file also carries custom-field GIDs and the required-admin list, so this
    reads-modifies-writes rather than replacing: a user who configured those
    should not lose them by re-running setup.
    """
    global _WS_CACHE
    try:
        cfg = json.loads(WORKSPACE_CONFIG.read_text())
    except (OSError, ValueError):
        cfg = {}
    cfg.setdefault("oauth", {})
    cfg["oauth"]["clientId"] = client_id
    cfg["oauth"]["clientSecret"] = client_secret
    _write_private(WORKSPACE_CONFIG, json.dumps(cfg, indent=2) + "\n")
    _WS_CACHE = None  # force reload; the flow reads the app back immediately


def configure_app_via_browser(timeout: int = 300) -> bool:
    """Collect the OAuth app through a loopback form. Returns True if saved.

    WHY THIS EXISTS: /pm-setup is normally run from inside Claude Code, whose
    Bash tool gives the script no controlling terminal. `read` cannot prompt
    there, so the terminal path exits and tells the user to re-run in a shell —
    which for a PM on a fresh machine is exactly the thing they were avoiding.

    The obvious alternative, having Claude pass --client-secret, is worse: a live
    secret would land in the conversation transcript and in this host's `ps`
    output. Typed into a page served on loopback, it goes browser -> this
    process -> 0600 file and appears nowhere else.
    """
    token = secrets.token_urlsafe(32)
    url = f"http://localhost:{CALLBACK_PORT}/configure?t={token}"
    saved = [False]

    def page(error: str = "") -> bytes:
        block = f'<p class="err">{error}</p>' if error else ""
        return (CONFIG_FORM % {"error": block, "token": token,
                               "port": CALLBACK_PORT}).encode()

    class ConfigHandler(http.server.BaseHTTPRequestHandler):
        def _authed(self) -> bool:
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            # Any page in the browser can POST to loopback; only one that can
            # read this URL knows the token. Without it, a hostile tab could
            # silently overwrite the stored app with its own.
            return secrets.compare_digest(qs.get("t", [""])[0], token)

        def _send(self, body: bytes, code: int = 200) -> None:
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            # Nothing here should ever be cached — it renders a credential form.
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if not self._authed():
                self._send(b"<h2>Not found</h2>", 404)
                return
            self._send(page())

        def do_POST(self):
            if not self._authed():
                self._send(b"<h2>Not found</h2>", 404)
                return
            try:
                n = int(self.headers.get("Content-Length", 0))
            except ValueError:
                n = 0
            # Bound the read: this is an unauthenticated socket until the token
            # is checked, and a form of this shape is a few hundred bytes.
            fields = urllib.parse.parse_qs(self.rfile.read(min(n, 8192)).decode("utf-8", "replace"))
            cid = fields.get("client_id", [""])[0].strip()
            secret = fields.get("client_secret", [""])[0].strip()
            if not cid or not secret:
                self._send(page("Both fields are required."), 400)
                return
            save_oauth_app(cid, secret)
            self._send(CONFIG_DONE.encode())
            saved[0] = True

        def log_message(self, *args):
            pass

    try:
        server = http.server.HTTPServer(("localhost", CALLBACK_PORT), ConfigHandler)
    except OSError as e:
        print(f"Could not open the setup form on localhost:{CALLBACK_PORT}: {e}",
              file=sys.stderr)
        print("  Something else is using that port. Free it and re-run, or set",
              file=sys.stderr)
        print("  ASANA_CLIENT_ID / ASANA_CLIENT_SECRET in the environment instead.",
              file=sys.stderr)
        return False

    print("Enter your Asana app details in the browser window that just opened.")
    print(f"If it didn't open, go to:\n  {url}\n")
    if os.environ.get("WSL_DISTRO_NAME") or os.environ.get("WSL_INTEROP"):
        print("  WSL: if the page won't load, open that address in Windows directly.")
        print()
    webbrowser.open(url)

    # serve_forever rather than one handle_request: the browser makes several
    # requests here (the form, a favicon, then the POST, plus any correction
    # round-trip after a validation error).
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    deadline = time.time() + timeout
    while not saved[0] and time.time() < deadline:
        time.sleep(0.2)
    server.shutdown()
    server.server_close()

    if not saved[0]:
        print(f"Timed out after {timeout // 60} minutes waiting for the form.",
              file=sys.stderr)
        return False
    print("Saved to", WORKSPACE_CONFIG)
    return True


def oauth_auth():
    """Run PKCE OAuth flow: open browser, catch callback, exchange for tokens."""
    client_id = get_client_id()
    if not client_id:
        print("No Asana OAuth app configured.", file=sys.stderr)
        print("  Easiest path — skip OAuth entirely and use a personal access token:",
              file=sys.stderr)
        print("      export ASANA_PAT=<token>        # app.asana.com → My settings → Apps",
              file=sys.stderr)
        print("  Or register an app at https://app.asana.com/0/my-apps (redirect",
              file=sys.stderr)
        print("  http://localhost:8372/callback) and set ASANA_CLIENT_ID +",
              file=sys.stderr)
        print("  ASANA_CLIENT_SECRET, or the oauth block in", file=sys.stderr)
        print(f"      {WORKSPACE_CONFIG}", file=sys.stderr)
        print("  See workspace.example.json in this directory for the shape.",
              file=sys.stderr)
        sys.exit(1)

    verifier, challenge = generate_pkce()
    state = secrets.token_urlsafe(32)

    # Omit scope parameter to get legacy full-access token.
    # Asana's granular scopes don't cover section creation, addMembers,
    # or addCustomFieldSetting — those need full access.

    # Build authorization URL
    params = {
        "client_id": client_id,
        "redirect_uri": f"http://localhost:{CALLBACK_PORT}/callback",
        "response_type": "code",
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    auth_url = f"{ASANA_AUTH_URL}?{urllib.parse.urlencode(params)}"

    # Capture the authorization code via local HTTP server
    auth_code = [None]
    auth_error = [None]

    class CallbackHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            qs = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if qs.get("state", [None])[0] != state:
                auth_error[0] = "State mismatch"
            elif qs.get("error"):
                auth_error[0] = qs["error"][0]
            else:
                auth_code[0] = qs.get("code", [None])[0]

            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            if auth_code[0]:
                self.wfile.write(b"<h2>Authenticated! You can close this tab.</h2>")
            else:
                self.wfile.write(f"<h2>Error: {auth_error[0]}</h2>".encode())

        def log_message(self, *args):
            pass  # suppress server logs

    server = http.server.HTTPServer(("localhost", CALLBACK_PORT), CallbackHandler)
    server_thread = threading.Thread(target=server.handle_request)
    server_thread.start()

    print(f"Opening browser for Asana authorization...")
    print(f"If the browser doesn't open, visit:\n  {auth_url}\n")
    if os.environ.get("WSL_DISTRO_NAME") or os.environ.get("WSL_INTEROP"):
        # The browser runs on Windows; the callback listener is in WSL. Windows
        # relays localhost to WSL, but not on every setup — mirrored networking,
        # a firewall rule, or something already holding the port all break it,
        # and the failure looks like the browser hanging on "can't reach this
        # page". Say this BEFORE the 2-minute wait, because the recovery needs
        # the URL from that failed page and the listener is gone afterwards.
        print("  WSL: if the browser lands on 'can't reach this page' after you approve,")
        print("  copy its full address and finish the handshake from inside WSL:")
        print(f"      curl \"http://localhost:{CALLBACK_PORT}/callback?code=...&state=...\"")
        print()
    webbrowser.open(auth_url)

    server_thread.join(timeout=120)
    server.server_close()

    if auth_error[0]:
        print(f"Auth error: {auth_error[0]}")
        sys.exit(1)
    if not auth_code[0]:
        print("Timed out waiting for authorization (2 min).", file=sys.stderr)
        if os.environ.get("WSL_DISTRO_NAME") or os.environ.get("WSL_INTEROP"):
            print("  On WSL this usually means Windows didn't relay localhost:"
                  f"{CALLBACK_PORT} into the distro.", file=sys.stderr)
            print("  Re-run, and when the browser fails to load the callback, copy its full",
                  file=sys.stderr)
            print("  address and replay it from inside WSL while this is still waiting:",
                  file=sys.stderr)
            print(f"      curl \"http://localhost:{CALLBACK_PORT}/callback?code=...&state=...\"",
                  file=sys.stderr)
        print("  Or skip OAuth entirely — a personal access token needs no callback:",
              file=sys.stderr)
        print("      export ASANA_PAT=<token>   # app.asana.com → My settings → Apps",
              file=sys.stderr)
        sys.exit(1)

    # Exchange code for tokens
    token_data = {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "client_secret": _oauth_app()[1],
        "redirect_uri": f"http://localhost:{CALLBACK_PORT}/callback",
        "code": auth_code[0],
        "code_verifier": verifier,
    }
    resp = requests.post(ASANA_TOKEN_URL, data=token_data, timeout=HTTP_TIMEOUT)
    if resp.status_code != 200:
        print(f"Token exchange failed: {resp.status_code} {resp.text}")
        sys.exit(1)

    tokens = resp.json()
    tokens["obtained_at"] = time.time()
    _write_private(TOKEN_FILE, json.dumps(tokens, indent=2))
    print(f"Authenticated as Asana user. Token saved to {TOKEN_FILE}")
    print("This file is gitignored. Re-run --auth to re-authenticate.")
    return tokens["access_token"]


def refresh_token():
    """Refresh an expired OAuth token."""
    if not TOKEN_FILE.exists():
        return None
    tokens = json.loads(TOKEN_FILE.read_text())
    client_id = get_client_id()
    if not client_id or not tokens.get("refresh_token"):
        return None

    resp = requests.post(ASANA_TOKEN_URL, data={
        "grant_type": "refresh_token",
        "client_id": client_id,
        "client_secret": _oauth_app()[1],
        "refresh_token": tokens["refresh_token"],
    }, timeout=HTTP_TIMEOUT)
    if resp.status_code != 200:
        print(f"Token refresh failed: {resp.status_code}. Re-run --auth.")
        return None

    new_tokens = resp.json()
    new_tokens["obtained_at"] = time.time()
    # Preserve refresh_token if not returned in refresh response
    if "refresh_token" not in new_tokens:
        new_tokens["refresh_token"] = tokens["refresh_token"]
    _write_private(TOKEN_FILE, json.dumps(new_tokens, indent=2))
    return new_tokens["access_token"]


def get_token():
    """Get a valid access token. Priority: token file → PAT env var."""
    # Try stored OAuth token
    if TOKEN_FILE.exists():
        tokens = json.loads(TOKEN_FILE.read_text())
        expires_in = tokens.get("expires_in", 3600)
        obtained_at = tokens.get("obtained_at", 0)
        if time.time() - obtained_at < expires_in - 60:
            return tokens["access_token"]
        # Try refresh
        refreshed = refresh_token()
        if refreshed:
            return refreshed
        print("OAuth token expired and refresh failed. Re-run --auth or set ASANA_PAT.")

    # Fallback to PAT. ASANA_ACCESS_TOKEN is accepted as an alias (the name the
    # MCP ecosystem uses); ASANA_PAT takes precedence if both are set.
    pat = os.environ.get("ASANA_PAT") or os.environ.get("ASANA_ACCESS_TOKEN") or ""
    if pat:
        return pat

    # Raise (not sys.exit) so embedders like the MCP server can report a clean
    # error instead of having the process killed mid-request. The CLI entrypoint
    # catches this and prints the friendly message + exits 1.
    raise AsanaAuthError(
        "No Asana auth available. Run `python3 scripts/asana_ops.py --auth` "
        "for OAuth, or set ASANA_PAT / ASANA_ACCESS_TOKEN.")


# ── Workspace resolution (multi-workspace accounts pick once) ──
def account_workspaces():
    """Return the account's workspaces as [{gid, name}, ...]."""
    me = api("GET", "/users/me", params={"opt_fields": "workspaces.name"})
    if not me:
        raise AsanaAuthError("Auth failed resolving workspaces. Run --auth or set a PAT.")
    return me["data"].get("workspaces", [])


def _persist_workspace(gid, name=""):
    try:
        _write_private(WORKSPACE_FILE, json.dumps({"gid": gid, "name": name}))
    except OSError:
        pass  # non-fatal — falls back to env/derivation next run


def resolve_workspace(interactive=False):
    """Resolve the active workspace GID. Precedence:
      1. ASANA_WORKSPACE env var
      2. saved choice in WORKSPACE_FILE (the "pick once" result)
      3. the sole workspace if the account has exactly one (auto-saved)
      4. interactive prompt (TTY only) → saved
    Otherwise raise AsanaWorkspaceError so the caller tells the user to pick once.
    """
    env = os.environ.get("ASANA_WORKSPACE", "").strip()
    if env:
        return env
    if WORKSPACE_FILE.exists():
        try:
            gid = json.loads(WORKSPACE_FILE.read_text()).get("gid")
            if gid:
                return gid
        except (ValueError, OSError):
            pass
    wss = account_workspaces()
    if not wss:
        raise AsanaWorkspaceError("This account belongs to no Asana workspaces.")
    if len(wss) == 1:
        _persist_workspace(wss[0]["gid"], wss[0].get("name", ""))
        return wss[0]["gid"]
    if interactive and sys.stdin.isatty():
        print("Pick your Asana workspace (saved for next time):", file=sys.stderr)
        for i, w in enumerate(wss, 1):
            print(f"  {i}. {w.get('name', '?')} ({w['gid']})", file=sys.stderr)
        try:
            sel = wss[int(input("> ").strip()) - 1]
        except (ValueError, IndexError):
            raise AsanaWorkspaceError("Invalid selection.")
        _persist_workspace(sel["gid"], sel.get("name", ""))
        return sel["gid"]
    listing = ", ".join(f"{w.get('name', '?')} ({w['gid']})" for w in wss)
    raise AsanaWorkspaceError(
        "Multiple Asana workspaces and none selected. Pick once with "
        "`python3 scripts/asana_ops.py --pick-workspace`, set `--set-workspace <gid>`, "
        f"or export ASANA_WORKSPACE. Available: {listing}")


# ── Logging ──
def log(method, url, status, gid=""):
    global CALLS
    CALLS += 1
    ts = datetime.now().strftime("%H:%M:%S")
    line = f"{ts} {method:6s} {url} → {status} {gid}"
    print(f"  {line}")
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")


# ── API helpers ──
def api(method, path, data=None, params=None, dry_run=False):
    url = f"{BASE}{path}"
    if dry_run and method != "GET":
        log(method, path, "DRY-RUN")
        return {"data": {"gid": "dry-run"}}

    token = get_token()
    headers = {"Authorization": f"Bearer {token}", "Content-Type": "application/json"}
    resp = requests.request(method, url, headers=headers,
                            json={"data": data} if data else None, params=params,
                            timeout=HTTP_TIMEOUT)

    # Rate limit handling
    if resp.status_code == 429:
        retry = int(resp.headers.get("Retry-After", 30))
        print(f"  ⏳ Rate limited, waiting {retry}s...")
        time.sleep(retry)
        return api(method, path, data, params, dry_run)

    gid = ""
    try:
        body = resp.json()
        gid = body.get("data", {}).get("gid", "") if isinstance(body.get("data"), dict) else ""
    except Exception:
        body = {}

    log(method, path, resp.status_code, gid)

    if resp.status_code >= 400:
        global ERRORS
        ERRORS += 1
        print(f"  ✗ {resp.status_code}: {resp.text[:200]}")
        return None

    return body


def paginate(path, params=None, opt_fields=None):
    """Fetch all pages of a list endpoint."""
    all_items = []
    p = dict(params or {})
    p["limit"] = 100
    if opt_fields:
        p["opt_fields"] = opt_fields
    while True:
        resp = api("GET", path, params=p)
        if not resp:
            break
        all_items.extend(resp.get("data", []))
        np = resp.get("next_page")
        if not np or not np.get("offset"):
            break
        p["offset"] = np["offset"]
    return all_items


# 100 MB — Asana's hard cap on a single attachment upload.
ATTACHMENT_MAX_BYTES = 100 * 1024 * 1024


def attach_file(task_gid, file_path, dry_run=False):
    """Upload a local file as an attachment on a task.

    POST /attachments is multipart/form-data, not JSON — the shared api()
    helper sends JSON and would be rejected here, so this does its own
    request and lets `requests` set the multipart boundary (never set
    Content-Type by hand or the boundary is lost). Fills the MCP gap: the
    Asana MCP can't upload a local file.
    """
    global ERRORS
    path = Path(file_path)
    if not path.exists() or not path.is_file():
        print(f"  ✗ File not found: {file_path}", file=sys.stderr)
        sys.exit(1)
    size = path.stat().st_size
    if size > ATTACHMENT_MAX_BYTES:
        print(f"  ✗ {path.name} is {size} bytes — exceeds Asana's 100MB attachment limit", file=sys.stderr)
        sys.exit(1)

    if dry_run:
        log("POST", "/attachments", "DRY-RUN")
        print(f"  DRY RUN: would attach {path.name} ({size} bytes) to task {task_gid}")
        return {"data": {"gid": "dry-run"}}

    token = get_token()
    with open(path, "rb") as fh:
        resp = requests.post(
            f"{BASE}/attachments",
            headers={"Authorization": f"Bearer {token}"},
            data={"parent": task_gid},
            files={"file": (path.name, fh)},
            timeout=UPLOAD_TIMEOUT,
        )

    if resp.status_code == 429:
        retry = int(resp.headers.get("Retry-After", 30))
        print(f"  ⏳ Rate limited, waiting {retry}s...")
        time.sleep(retry)
        return attach_file(task_gid, file_path, dry_run)

    log("POST", "/attachments", resp.status_code)
    if resp.status_code >= 400:
        ERRORS += 1
        print(f"  ✗ {resp.status_code}: {resp.text[:200]}", file=sys.stderr)
        return None

    att = resp.json().get("data", {})
    print(f"OK gid={att.get('gid', '')} {att.get('view_url', '')}")
    return att


# ═══════════════════════════════════════════════════════
# Hygiene audit + fix
# ═══════════════════════════════════════════════════════

# Field GIDs live in ~/.devhawk/pm/workspace.json, not here — see
# required_fields() and workspace.example.json.
# Who must be Admin on every project — {gid: name}, from workspace.json.
# Empty when unconfigured: hygiene then reports the admin COUNT rather than
# asserting somebody else's team.
def required_admins_map() -> dict:
    return {a["gid"]: a.get("name", a["gid"]) for a in required_admins() if a.get("gid")}
STANDARD_SECTIONS = [
    "INBOX", "BACKLOG", "TODO", "WIP", "READY FOR REVIEW",
    "READY FOR TESTING", "READY FOR RELEASE", "DONE",
]
# Sections where we relax field requirements (Priority/Type/Points/Release).
# INBOX items haven't been discussed with stakeholders yet, so demanding
# estimates and types is the wrong order of operations. See
# docs/asana-best-practices.md for the per-section field requirement table.
LIGHT_VALIDATION_SECTIONS = {"INBOX"}
# Days before an unmoved INBOX item is flagged as stale.
INBOX_STALE_DAYS = 30
# Field and enum-option GIDs are workspace-specific: these are looked up by name
# in ~/.devhawk/pm/workspace.json rather than baked in. `""` when unconfigured,
# which callers treat as "this field isn't set up" and skip.
def _wsg(*path, default=""):
    """Fetch a nested workspace-config value, e.g. _wsg('options', 'P2')."""
    node = _workspace_config()
    for key in path:
        if not isinstance(node, dict):
            return default
        node = node.get(key)
    return node if isinstance(node, str) and node else default


def field_gid(name: str) -> str:
    """GID of a required custom field, by canonical role name.

    Matches exactly, then on a trailing word, so a workspace that prefixes its
    fields ("Fraction Priority") resolves the same as one that doesn't
    ("Priority"). Returns "" when unconfigured — callers skip that field rather
    than PUTting a GID from someone else's workspace.
    """
    want = name.strip().lower()
    fields = required_fields()
    for gid, n in fields.items():
        if n.strip().lower() == want:
            return gid
    for gid, n in fields.items():
        if n.strip().lower().endswith(" " + want):
            return gid
    return ""


# Resolved once at import from workspace.json. Empty string when unconfigured;
# every call site already treats "no gid" as "this field isn't set up" and skips.
P2_OPTION = _wsg("options", "priorityP2")
STORY_OPTION = _wsg("options", "typeStory")
DISCUSSION_OPTION = _wsg("options", "typeDiscussion")
EPIC_OPTION = _wsg("options", "typeEpic")
SPRINT_FIELD_GID = field_gid("Sprint")
SP_FIELD_GID = field_gid("Story Points")
PRIORITY_FIELD_GID = field_gid("Priority")
TYPE_FIELD_GID = field_gid("Task Type")
THEME_FIELD_GID = field_gid("Theme")
FEATURE_FIELD_GID = field_gid("Feature")


def auto_estimate(project_gid):
    """Auto-estimate story points based on description complexity."""
    print(f"\n═══ Auto-Estimate: {project_gid} ═══\n")

    def estimate_sp(name, notes):
        text = (name + " " + (notes or "")).lower()
        words = len(text.split())
        complex_kw = ["integrate", "migration", "architecture", "pipeline", "api",
                       "automate", "dashboard", "multiple", "system", "workflow",
                       "end-to-end", "security", "scrape", "ingest"]
        simple_kw = ["fix", "chore", "remove", "rename", "typo", "cleanup", "variable"]
        score = sum(1 for k in complex_kw if k in text) - sum(1 for k in simple_kw if k in text)
        if words < 20 and score <= 0: return 1
        if words < 50 and score <= 0: return 2
        if words < 100 or score <= 1: return 3
        if words < 200 or score <= 2: return 5
        return 8

    tasks = paginate(f"/projects/{project_gid}/tasks",
                     opt_fields="name,completed,notes,custom_fields.gid,custom_fields.number_value")
    incomplete = [t for t in tasks if not t.get("completed") and not t["name"].startswith("EPIC:")]
    estimated = 0
    for task in incomplete:
        has_sp = any(cf.get("gid") == SP_FIELD_GID and cf.get("number_value")
                     for cf in task.get("custom_fields", []))
        if has_sp:
            continue
        sp = estimate_sp(task["name"], task.get("notes", ""))
        api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {SP_FIELD_GID: sp}})
        estimated += 1
        if estimated % 50 == 0:
            print(f"  ... {estimated}")

    print(f"  Estimated: {estimated} tasks")


_VAGUE_VERBS = {"fix", "update", "tweak", "change", "adjust", "modify", "edit", "improve"}
_VAGUE_PREFIX_RE = re.compile(r"^\[[A-Z]+-\d+\]\s*")
_VAGUE_MARKER_RE = re.compile(r"\b(misc|todo|tbd)\b", re.IGNORECASE)


def _is_vague_title(name):
    """Flag titles that are short + start with a generic verb, or contain TBD/TODO/misc.

    Strips a leading [KEY-N] tracker prefix before evaluating length so
    migrated tasks aren't penalized for the prefix's word count.
    """
    if _VAGUE_MARKER_RE.search(name):
        return True
    body = _VAGUE_PREFIX_RE.sub("", name).strip()
    words = body.split()
    if not words:
        return True
    return len(words) <= 4 and words[0].lower() in _VAGUE_VERBS


def _print_offenders(items, indent="     ", max_show=20):
    """Print task name + permalink for each offender, capped at max_show."""
    for t in items[:max_show]:
        print(f"{indent}• {t['name']}")
        if t.get("permalink_url"):
            print(f"{indent}  {t['permalink_url']}")
    if len(items) > max_show:
        print(f"{indent}... and {len(items) - max_show} more")


def hygiene_audit(project_gid, dry_run=False):
    """Full hygiene audit + fix against Asana best practices."""
    print(f"\n═══ Hygiene Audit: {project_gid} ═══\n")
    fixes = 0

    # 1. Admins
    print("1. Required Admins")
    resp = api("GET", f"/projects/{project_gid}/members", params={"opt_fields": "name"})
    if resp:
        member_gids = {m["gid"] for m in resp.get("data", [])}
        admins = required_admins_map()
        if not admins:
            # No configured list: report the count rather than asserting somebody
            # else's team, and never add members we cannot name.
            print(f"   ⚠ {len(member_gids)} member(s); no requiredAdmins configured"
                  f" in {WORKSPACE_CONFIG} — skipping the admin policy")
        for gid, name in admins.items():
            if gid in member_gids:
                print(f"   ✅ {name}")
            else:
                print(f"   ❌ {name} — adding...")
                api("POST", f"/projects/{project_gid}/addMembers",
                    {"members": [gid]}, dry_run=dry_run)
                fixes += 1

    # 2. Custom fields
    print("\n2. Custom Fields")
    resp = api("GET", f"/projects/{project_gid}",
               params={"opt_fields": "custom_field_settings.custom_field.gid"})
    attached = set()
    if resp and isinstance(resp.get("data"), dict):
        for cfs in resp["data"].get("custom_field_settings", []):
            attached.add(cfs.get("custom_field", {}).get("gid", ""))
    fields = required_fields()
    if not fields:
        print("   ⚠ no requiredFields in ~/.devhawk/pm/workspace.json — skipping field policy")
    for gid, name in fields.items():
        if gid in attached:
            print(f"   ✅ {name}")
        else:
            print(f"   ❌ {name} — attaching...")
            api("POST", f"/projects/{project_gid}/addCustomFieldSetting",
                {"custom_field": gid, "is_important": True}, dry_run=dry_run)
            fixes += 1

    # 3. Sections
    print("\n3. Sections")
    resp = api("GET", f"/projects/{project_gid}/sections", params={"opt_fields": "name"})
    existing_sections = {s["name"] for s in resp.get("data", [])} if resp else set()
    for sname in STANDARD_SECTIONS:
        if sname in existing_sections:
            print(f"   ✅ {sname}")
        else:
            print(f"   ❌ {sname} — creating...")
            api("POST", f"/projects/{project_gid}/sections",
                {"name": sname}, dry_run=dry_run)
            fixes += 1
    extra_sections = existing_sections - set(STANDARD_SECTIONS)
    if extra_sections:
        print(f"   Non-standard sections: {len(extra_sections)}")
        for sname in sorted(extra_sections):
            print(f"     • {sname}")

    # 4. Metadata
    print("\n4. Metadata")
    resp = api("GET", f"/projects/{project_gid}",
               params={"opt_fields": "start_on,due_on,notes"})
    if resp and isinstance(resp.get("data"), dict):
        d = resp["data"]
        print(f"   start_on: {d.get('start_on') or '❌ MISSING'}")
        print(f"   due_on: {d.get('due_on') or '❌ MISSING'}")
        print(f"   notes: {'✅' if d.get('notes') else '❌ EMPTY'}")

    # 5. Task hygiene
    print("\n5. Task Hygiene")
    tasks = paginate(f"/projects/{project_gid}/tasks",
                     opt_fields="name,completed,assignee.gid,notes,parent.gid,parent.name,num_subtasks,custom_fields.gid,custom_fields.enum_value.gid,custom_fields.number_value,custom_fields.text_value,memberships.section.gid,memberships.section.name,modified_at,permalink_url")
    incomplete = [t for t in tasks if not t.get("completed")]

    # Section helpers — INBOX gets light validation (Priority/Type/Points/Release
    # are intentionally not required pre-stakeholder discussion).
    def section_name(t):
        for m in t.get("memberships", []):
            sec = m.get("section") or {}
            if sec.get("name"):
                return sec["name"]
        return None
    incomplete_strict = [t for t in incomplete if section_name(t) not in LIGHT_VALIDATION_SECTIONS]
    inbox_tasks = [t for t in incomplete if section_name(t) == "INBOX"]

    # Orphans
    orphans = [t for t in tasks if not any(
        m.get("section", {}).get("gid") for m in t.get("memberships", []))]
    print(f"   Orphaned: {len(orphans)}")
    _print_offenders(orphans)

    # INBOX summary (always shown so the funnel is visible)
    if inbox_tasks:
        print(f"   INBOX: {len(inbox_tasks)} item(s) awaiting stakeholder discussion")
        # Stale INBOX — flag items unmoved for >INBOX_STALE_DAYS
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc)
        stale = []
        for t in inbox_tasks:
            ma = t.get("modified_at")
            if not ma:
                continue
            try:
                # Asana returns ISO 8601 with Z suffix
                dt = datetime.fromisoformat(ma.replace("Z", "+00:00"))
                if (now - dt).days >= INBOX_STALE_DAYS:
                    stale.append(t)
            except (ValueError, AttributeError):
                pass
        if stale:
            print(f"   Stale INBOX (>{INBOX_STALE_DAYS}d no activity): {len(stale)}")
            _print_offenders(stale)

    # No assignee — TODO+ only (BACKLOG and INBOX intentionally unassigned)
    no_assignee = [t for t in incomplete_strict
                   if section_name(t) not in (None, "BACKLOG") and not t.get("assignee")]
    print(f"   No assignee (TODO+ only): {len(no_assignee)}")
    _print_offenders(no_assignee)

    # No priority — strict sections only (BACKLOG and below)
    no_priority = [t for t in incomplete_strict if not any(
        cf.get("gid") == PRIORITY_FIELD_GID and cf.get("enum_value")
        for cf in t.get("custom_fields", []))]
    print(f"   No Priority (excl. INBOX): {len(no_priority)}")
    if no_priority and not dry_run:
        print(f"   → Setting {len(no_priority)} to P2 (Medium)...")
        for task in no_priority:
            # EPICs are aggregate containers; child stories carry Priority.
            # Mirror the same EPIC skip used in the no_type loop below.
            if task["name"].startswith("EPIC:"):
                continue
            api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {PRIORITY_FIELD_GID: P2_OPTION}})
            fixes += 1

    # No type — strict sections only
    no_type = [t for t in incomplete_strict if not any(
        cf.get("gid") == TYPE_FIELD_GID and cf.get("enum_value")
        for cf in t.get("custom_fields", []))]
    print(f"   No Task Type (excl. INBOX): {len(no_type)}")
    if no_type and not dry_run:
        print(f"   → Setting {len(no_type)} types...")
        meta_kw = ["BREAK OUT", "DISCUSS", "REFINE", "BREAKOUT"]
        for task in no_type:
            if task["name"].startswith("EPIC:"):
                option = EPIC_OPTION
            elif any(k in task["name"].upper() for k in meta_kw):
                option = DISCUSSION_OPTION
            else:
                option = STORY_OPTION
            api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {TYPE_FIELD_GID: option}})
            fixes += 1

    # No story points — strict sections only
    no_sp = [t for t in incomplete_strict if not any(
        cf.get("gid") == SP_FIELD_GID and cf.get("number_value")
        for cf in t.get("custom_fields", [])) and not t["name"].startswith("EPIC:")]
    print(f"   No Story Points (excl. INBOX): {len(no_sp)}")
    if no_sp and not dry_run:
        print(f"   → Auto-estimating...")
        auto_estimate(project_gid)
        fixes += len(no_sp)

    # No Release — strict sections only (INBOX is pre-release classification)
    no_release = [t for t in incomplete_strict if not any(
        cf.get("gid") == RELEASE_FIELD_GID and cf.get("enum_value")
        for cf in t.get("custom_fields", []))]
    print(f"   No Release (excl. INBOX): {len(no_release)}")
    if no_release and not dry_run:
        print(f"   → Auto-detecting phase (own name → task prefix → Phase 1 fallback)...")
        # Flat model: no parent epics to inherit from. Detect phase from the task's
        # own "(Phase N)" suffix (e.g. an EPIC definition card) or a Jira prefix.
        phase_pattern = re.compile(r"\(Phase\s+(\d+)\)", re.IGNORECASE)
        scrum_re = re.compile(r"^\[SCRUM-")
        phas_re = re.compile(r"^\[PHAS-")
        fallback_count = 0
        for task in no_release:
            phase = None
            m = phase_pattern.search(task["name"])
            if m:
                phase = f"Phase {m.group(1)}"
            elif scrum_re.match(task["name"]):
                phase = "Phase 1"
            elif phas_re.match(task["name"]):
                phase = "Phase 2"
            # Greenfield fallback — no signal in name or prefix
            if not phase:
                phase = "Phase 1"
                fallback_count += 1
            opt_gid = RELEASE_OPTIONS.get(phase)
            if opt_gid:
                api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {RELEASE_FIELD_GID: opt_gid}})
                fixes += 1
        if fallback_count:
            print(f"   ⚠ {fallback_count} task(s) defaulted to Phase 1 (no signal in name or prefix). Review if your project has multiple phases.")

    # Title quality
    vague = [t for t in incomplete if _is_vague_title(t["name"])]
    print(f"   Vague titles: {len(vague)}")
    _print_offenders(vague)

    # Empty descriptions
    no_desc = [t for t in incomplete if not (t.get("notes") or "").strip()]
    print(f"   Empty descriptions: {len(no_desc)}")
    _print_offenders(no_desc)

    # Missing Feature (flat-model grouping — the epic a task supports). Feature is
    # free-text, per-project. Auto-fix is safe ONLY when the project already uses
    # exactly one Feature (unambiguous → blanks inherit it); with zero or multiple
    # epics in play the value is a judgement call, so surface for triage. INBOX
    # exempt — Feature is set at the INBOX → BACKLOG promotion.
    def feature_value(t):
        for cf in t.get("custom_fields", []):
            if cf.get("gid") == FEATURE_FIELD_GID:
                return (cf.get("text_value") or "").strip()
        return ""
    features_in_use = {feature_value(t) for t in incomplete if feature_value(t)}
    missing_feature = [t for t in incomplete_strict
                       if not t["name"].startswith("EPIC:") and not feature_value(t)]
    print(f"   Missing Feature (excl. INBOX): {len(missing_feature)}")
    if missing_feature and len(features_in_use) == 1:
        sole_f = next(iter(features_in_use))
        print(f"   → Single project Feature in use ({sole_f!r}) — filling {len(missing_feature)} blank(s)...")
        if not dry_run:
            for task in missing_feature:
                api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {FEATURE_FIELD_GID: sole_f}})
                fixes += 1
    elif missing_feature:
        _print_offenders(missing_feature)

    # Missing Theme (flat-model grouping — the project's theme/arc). Theme is a
    # free-text, per-project field (no shared enum), so there's no global default.
    # Auto-fix is safe ONLY when the project already uses exactly one Theme
    # (unambiguous → fill the blanks); with zero or multiple themes in play the
    # value is a judgement call, so surface for triage like Feature. INBOX exempt.
    def theme_value(t):
        for cf in t.get("custom_fields", []):
            if cf.get("gid") == THEME_FIELD_GID:
                return (cf.get("text_value") or "").strip()
        return ""
    themes_in_use = {theme_value(t) for t in incomplete if theme_value(t)}
    missing_theme = [t for t in incomplete_strict
                     if not t["name"].startswith("EPIC:") and not theme_value(t)]
    print(f"   Missing Theme (excl. INBOX): {len(missing_theme)}")
    if missing_theme and len(themes_in_use) == 1:
        sole = next(iter(themes_in_use))
        print(f"   → Single project Theme in use ({sole!r}) — filling {len(missing_theme)} blank(s)...")
        if not dry_run:
            for task in missing_theme:
                api("PUT", f"/tasks/{task['gid']}", {"custom_fields": {THEME_FIELD_GID: sole}})
                fixes += 1
    elif missing_theme:
        # ambiguous (0 or >1 themes in use) — can't safely default; report
        _print_offenders(missing_theme)

    # Subtasks present (flat-model violation — Asana can't move a subtask between
    # board sections, so it's stuck). Two shapes: a task that still has a parent
    # (incl. the dual state: project member AND parented), or a task that still
    # owns subtasks. Fix with --elevate-subtasks (non-destructive). All sections.
    still_parented = [t for t in tasks if not t.get("completed") and t.get("parent")]
    owns_subtasks = [t for t in tasks if not t.get("completed") and t.get("num_subtasks", 0) > 0]
    subtask_offenders = {t["gid"]: t for t in still_parented + owns_subtasks}
    if subtask_offenders:
        print(f"   ⚠ Subtasks present (flat-model violation): "
              f"{len(still_parented)} still parented, {len(owns_subtasks)} still own subtasks")
        print(f"     → Fix: python3 scripts/asana_ops.py --elevate-subtasks {project_gid}")
        _print_offenders(list(subtask_offenders.values()))
    else:
        print(f"   Subtasks present (flat-model violation): 0")

    print(f"\n   Total fixes applied: {fixes}")


# ═══════════════════════════════════════════════════════
# Create new phase in an existing project
# ═══════════════════════════════════════════════════════


def create_new_phase(project_gid, phase_name, dry_run=False):
    """Create a new phase (a release arc) in an existing project.

    A phase is a named release arc within a single project. The project stays
    the same — it adds a Release enum option and posts a status update. Tasks
    are grouped by the Feature (epic) text field, not by parent/child nesting.

    This is how teams add new release phases without creating new projects.
    """
    print(f"\n═══ New Phase: {phase_name} ═══\n")
    print(f"  Project: {project_gid}")

    # Verify project exists
    resp = api("GET", f"/projects/{project_gid}", params={"opt_fields": "name"})
    if not resp:
        print("  ✗ Project not found")
        return
    print(f"  Project name: {resp['data']['name']}")

    # Ensure standard fields + sections exist (idempotent)
    print("\n  Verifying best practices...")

    # Check sections
    sr = api("GET", f"/projects/{project_gid}/sections", params={"opt_fields": "name"})
    existing_sections = {s["name"] for s in sr.get("data", [])} if sr else set()
    section_gids = {}
    if sr:
        section_gids = {s["name"]: s["gid"] for s in sr.get("data", [])}
    for sname in STANDARD_SECTIONS:
        if sname not in existing_sections:
            print(f"    Creating section: {sname}")
            r = api("POST", f"/projects/{project_gid}/sections",
                    {"name": sname}, dry_run=dry_run)
            if r:
                section_gids[sname] = r["data"]["gid"]

    # Check fields
    fr = api("GET", f"/projects/{project_gid}",
             params={"opt_fields": "custom_field_settings.custom_field.gid"})
    attached = set()
    if fr and isinstance(fr.get("data"), dict):
        for cfs in fr["data"].get("custom_field_settings", []):
            attached.add(cfs.get("custom_field", {}).get("gid", ""))
    for gid, name in required_fields().items():
        if gid not in attached:
            print(f"    Attaching field: {name}")
            api("POST", f"/projects/{project_gid}/addCustomFieldSetting",
                {"custom_field": gid, "is_important": True}, dry_run=dry_run)

    # Post status update
    print(f"\n  Posting status update for {phase_name}...")
    api("POST", f"/projects/{project_gid}/project_statuses", {
        "color": "blue",
        "title": f"{phase_name} started",
        "text": f"New phase '{phase_name}' created. Features and tasks will be added as discovery and planning complete.",
    }, dry_run=dry_run)

    # Ensure Release enum option exists for this phase
    release_opt_gid = RELEASE_OPTIONS.get(phase_name)
    if not release_opt_gid:
        print(f"\n  Creating Release option: {phase_name}")
        resp = api("POST", f"/custom_fields/{RELEASE_FIELD_GID}/enum_options",
                   {"name": phase_name, "insert_before": None}, dry_run=dry_run)
        if resp:
            release_opt_gid = resp["data"]["gid"]
            RELEASE_OPTIONS[phase_name] = release_opt_gid
            print(f"    Created: {phase_name} → {release_opt_gid}")

    todo_gid = section_gids.get("TODO", "")
    print(f"\n  Phase '{phase_name}' ready.")
    print(f"  Add top-level tasks with Feature = '<epic name>' (no subtasks — flat-task policy).")
    print(f"  TODO section: {todo_gid}")
    if release_opt_gid:
        print(f"  Release option GID: {release_opt_gid} — set on new tasks")
    print(f"\n  Next: create top-level tasks via MCP or asana_ops.py (carry Feature/Theme)")


def add_subtasks_to_project(parent_gid, dry_run=False):
    """Add a parent task's direct subtasks to all of the parent's projects.

    Asana gotcha: POST /tasks with `parent` parents the subtask but does NOT
    add it to the parent's projects. Custom fields are project-scoped, so
    setting Priority / Type / Story Points / etc. on an unprojected subtask
    returns 400 ("Custom field with ID X is not on given object"). This
    function is the recovery tool — idempotent, safe to re-run.
    """
    parent = api("GET", f"/tasks/{parent_gid}",
                 params={"opt_fields": "name,projects.gid,projects.name"})
    if not parent:
        return
    parent_data = parent["data"]
    parent_projects = parent_data.get("projects", [])
    if not parent_projects:
        print(f"  ✗ Parent '{parent_data['name']}' has no projects — nothing to do")
        return
    project_gids = {p["gid"]: p["name"] for p in parent_projects}

    subtasks = paginate(f"/tasks/{parent_gid}/subtasks",
                        opt_fields="name,projects.gid")
    print(f"  Parent: {parent_data['name']}")
    print(f"  Parent projects: {', '.join(project_gids.values())}")
    print(f"  Subtasks: {len(subtasks)}")

    added = skipped = 0
    for st in subtasks:
        already = {p["gid"] for p in st.get("projects", [])}
        missing = set(project_gids) - already
        name = st["name"][:60]
        if not missing:
            print(f"    · {name} (already on project)")
            skipped += 1
            continue
        for proj_gid in missing:
            print(f"    + {name} → adding to {project_gids[proj_gid]}")
            api("POST", f"/tasks/{st['gid']}/addProject",
                {"project": proj_gid}, dry_run=dry_run)
        added += 1

    print(f"  Done. {added} added, {skipped} skipped.")


def elevate_subtasks(project_gid, dry_run=False):
    """Elevate every subtask in a project to a top-level task (flat-task policy).

    Asana can't move a subtask between board sections, so subtasks can never
    flow INBOX → DONE. This promotes them non-destructively (same gid, comments,
    attachments) with a two-call sequence — order matters:
        1. POST /tasks/{gid}/addProject {project, section}  → board-visible
        2. POST /tasks/{gid}/setParent  {parent: null}       → detach
    Reverse the order and the task briefly belongs to nothing. Then the former
    parent's name is copied into each child's Feature field (and the parent's
    Theme, if set). The parent EPIC card is KEPT (its Feature = its own name, so
    it groups with its tasks). Idempotent — also repairs the dual state where a
    task is a project member but still parented (step 1 ran, step 2 didn't).

    Section routing for a not-yet-placed child: completed → DONE; open → the
    parent's section if it's an active flow section (INBOX/BACKLOG/TODO/WIP),
    else BACKLOG. A child already in a section keeps it.
    """
    print(f"\n═══ Elevate subtasks: {project_gid} ═══\n")

    sr = api("GET", f"/projects/{project_gid}/sections", params={"opt_fields": "name"})
    sections = {s["name"]: s["gid"] for s in sr.get("data", [])} if sr else {}
    gid_to_name = {g: n for n, g in sections.items()}
    done_gid = sections.get("DONE")
    backlog_gid = sections.get("BACKLOG")
    ACTIVE = {"INBOX", "BACKLOG", "TODO", "WIP"}

    tasks = paginate(f"/projects/{project_gid}/tasks", opt_fields="name,num_subtasks")
    parents = [t for t in tasks if t.get("num_subtasks", 0) > 0]
    if not parents:
        print("  No parent tasks with subtasks — project is already flat.")
        return

    elevated = 0
    for p in parents:
        pdata = api("GET", f"/tasks/{p['gid']}", params={
            "opt_fields": "name,memberships.section.name,"
                          "custom_fields.gid,custom_fields.text_value"})
        pd = pdata["data"] if pdata else {}
        pname = pd.get("name", p["name"])
        psection = next((m["section"]["name"] for m in pd.get("memberships", [])
                         if m.get("section")), None)
        ptheme = next((cf["text_value"] for cf in pd.get("custom_fields", [])
                       if cf.get("gid") == THEME_FIELD_GID and cf.get("text_value")), None)
        # Keep the parent EPIC card; tag its own Feature so it groups with its tasks.
        api("PUT", f"/tasks/{p['gid']}", {"custom_fields": {FEATURE_FIELD_GID: pname}},
            dry_run=dry_run)

        subs = paginate(f"/tasks/{p['gid']}/subtasks",
                        opt_fields="name,completed,memberships.section.name")
        print(f"  EPIC {pname[:50]!r} [{psection or '—'}] — {len(subs)} subtask(s)")
        for st in subs:
            cur_sec = next((m["section"]["name"] for m in st.get("memberships", [])
                            if m.get("section")), None)
            if cur_sec:
                target = sections.get(cur_sec)              # already placed — keep
            elif st.get("completed"):
                target = done_gid
            elif psection in ACTIVE:
                target = sections.get(psection)
            else:
                target = backlog_gid
            target = target or backlog_gid
            api("POST", f"/tasks/{st['gid']}/addProject",
                {"project": project_gid, "section": target}, dry_run=dry_run)   # step 1
            api("POST", f"/tasks/{st['gid']}/setParent",
                {"parent": None}, dry_run=dry_run)                              # step 2
            cf = {FEATURE_FIELD_GID: pname}
            if ptheme:
                cf[THEME_FIELD_GID] = ptheme
            api("PUT", f"/tasks/{st['gid']}", {"custom_fields": cf}, dry_run=dry_run)
            elevated += 1
            print(f"    ✓ {st['name'][:46]!r} → {gid_to_name.get(target, target)}")

    print(f"\n  Elevated {elevated} subtask(s). Parent EPIC cards kept (Feature = own name).")


# Default owner for generated index projects, from workspace.json.
JEREMY_GID = _wsg("defaultProjectOwnerGid")


RELEASE_FIELD_GID = field_gid("Release")

# Audit tag: stamped on every card created by the `add-card` skill so
# skill-created vs manually-created cards are distinguishable in saved
# views + machine-parseable for audit scripts.
ADD_CARD_AUDIT_TAG_NAME = "devhawk:add-card"


def ensure_audit_tag(dry_run=False):
    """Idempotent: ensure the workspace-level audit tag exists. Returns its gid.

    Asana tags are workspace-scoped (not project-scoped), so this is a one-shot
    per workspace. Safe to re-run — finds the existing tag and prints its gid
    without creating a duplicate.
    """
    # Resolve the active workspace (multi-workspace accounts pick once).
    ws_gid = resolve_workspace()

    # Look for an existing tag with the canonical name. The workspace tags
    # endpoint paginates; we accept up to a few hundred tags before giving up.
    for tag in paginate(f"/workspaces/{ws_gid}/tags", opt_fields="name"):
        if tag.get("name") == ADD_CARD_AUDIT_TAG_NAME:
            print(tag["gid"])
            return tag["gid"]

    if dry_run:
        print(f"DRY RUN: would create tag '{ADD_CARD_AUDIT_TAG_NAME}' in workspace {ws_gid}", file=sys.stderr)
        return None

    resp = api("POST", f"/workspaces/{ws_gid}/tags", {"name": ADD_CARD_AUDIT_TAG_NAME})
    if not resp:
        # Return None (not sys.exit) so an embedder degrades gracefully — the MCP
        # capture_inbox_idea checks `if tag:` and just skips the tag attach. The
        # CLI --ensure-audit-tag handler turns a None into exit 1.
        print(f"FAILED to create tag '{ADD_CARD_AUDIT_TAG_NAME}'", file=sys.stderr)
        return None
    tag_gid = resp["data"]["gid"]
    print(tag_gid)
    return tag_gid


# ═══════════════════════════════════════════════════════
# Report
# ═══════════════════════════════════════════════════════


# ═══════════════════════════════════════════════════════
# Skill-facing CLI verbs
# ═══════════════════════════════════════════════════════
# Thin wrappers over api()/paginate() that give the skills (add-card, card-done,
# add-comment, asana-bootstrap) a first-party home for the operations the curated
# asana_mcp.py server deliberately omits — raw create, complete, user lookup,
# project create. This keeps EVERY Asana write inside our own tooling; no
# third-party Asana MCP is ever required. I/O is JSON-in / JSON-out so a skill
# can pipe a spec and parse the result.

def _read_json_arg(arg):
    """A JSON spec passed inline, or read from stdin when arg == '-'."""
    raw = sys.stdin.read() if arg == "-" else arg
    try:
        return json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"  ✗ invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)


# Release enum options, {phase name: option gid}, seeded from workspace.json.
# create_new_phase() adds to this dict for the rest of the process; --add-release-option
# creates the option in Asana and PRINTS the new gid, but does not persist it — add it
# to workspace.json yourself if you want it resolved on later runs. The gids are
# workspace-specific, so they are never shipped.
RELEASE_OPTIONS = dict(_workspace_config().get("releaseOptions", {}))
def _resolve_section_gid(project_gid, section):
    """Section name (case-insensitive) or numeric gid → section gid.
    Raises ValueError when a named section isn't found in the project."""
    if str(section).isdigit():
        return str(section)
    secs = paginate(f"/projects/{project_gid}/sections", opt_fields="name")
    match = next((s for s in secs
                  if (s.get("name") or "").strip().lower() == str(section).strip().lower()), None)
    if not match:
        names = ", ".join((s.get("name") or "?") for s in secs)
        raise ValueError(f"section {section!r} not found in project {project_gid}. Available: {names}")
    return match["gid"]


def create_task(spec, dry_run=False):
    """Create a top-level task (flat-task policy — never a subtask). `spec` keys:
    name (req), notes, projects (list, req), section (name/gid within the first
    project), custom_fields (dict gid→value, applied on create), sprint (list of
    enum-option gids, applied via a follow-up PUT since multi_enum can't always
    be set on create), audit_tag (bool, default True → stamp the
    devhawk:add-card tag). Prints a JSON result."""
    name = spec.get("name")
    projects = spec.get("projects") or []
    if not name or not projects:
        print('  ✗ --create-task requires "name" and a non-empty "projects" list', file=sys.stderr)
        sys.exit(1)
    payload = {"name": name, "projects": projects}
    if spec.get("notes"):
        payload["notes"] = spec["notes"]
    if spec.get("custom_fields"):
        payload["custom_fields"] = spec["custom_fields"]
    if dry_run:
        print(json.dumps({"ok": True, "dry_run": True, "would_create": payload}))
        return
    created = api("POST", "/tasks", payload)
    if not created or not isinstance(created.get("data"), dict):
        print(json.dumps({"ok": False, "error": "create failed"}))
        sys.exit(1)
    gid = created["data"]["gid"]
    # The card now exists — every follow-up is best-effort so a later failure
    # reports a warning rather than losing the card.
    warnings = []
    if spec.get("section"):
        try:
            sec_gid = _resolve_section_gid(projects[0], spec["section"])
            api("POST", f"/sections/{sec_gid}/addTask", {"task": gid})
        except ValueError as e:
            warnings.append(str(e))
    if spec.get("sprint"):
        if not api("PUT", f"/tasks/{gid}", {"custom_fields": {SPRINT_FIELD_GID: spec["sprint"]}}):
            warnings.append("sprint not applied")
    if spec.get("audit_tag", True):
        try:
            tag = ensure_audit_tag()
            if tag:
                api("POST", f"/tasks/{gid}/addTag", {"tag": tag})
            else:
                warnings.append("audit tag unavailable — footer marker still applies")
        except Exception as e:  # noqa: BLE001 — best-effort, surfaced in result
            warnings.append(f"audit tag skipped: {e}")
    print(json.dumps({"ok": True, "task_gid": gid,
                      "permalink": f"https://app.asana.com/0/{projects[0]}/{gid}",
                      "warnings": warnings}))


def complete_task(task_gid, dry_run=False):
    """Mark a task complete. (The curated MCP omits completion deliberately;
    card-done drives it here.)"""
    r = api("PUT", f"/tasks/{task_gid}", {"completed": True}, dry_run=dry_run)
    print("OK" if r else "FAILED")
    if not r and not dry_run:
        sys.exit(1)


def find_user(query):
    """Find workspace users matching `query` (substring of name or email,
    case-insensitive). Prints gid<TAB>name<TAB>email per match — used by the
    add-comment skill to resolve @mentions to user GIDs."""
    ws = resolve_workspace()
    q = query.strip().lower()
    matches = [u for u in paginate(f"/workspaces/{ws}/users", opt_fields="name,email")
               if q in (u.get("name") or "").lower() or q in (u.get("email") or "").lower()]
    if not matches:
        print(f"  ✗ no user matches {query!r} in workspace {ws}", file=sys.stderr)
        sys.exit(1)
    for u in matches:
        print(f"{u['gid']}\t{u.get('name', '?')}\t{u.get('email', '')}")


def create_project(spec, dry_run=False):
    """Create a project (asana-bootstrap). `spec` keys: name (req), team (gid —
    required for org workspaces), workspace (gid; defaults to the active one),
    notes, public (bool), default_view. Prints a JSON result with the new
    project gid."""
    name = spec.get("name")
    if not name:
        print('  ✗ --create-project requires "name"', file=sys.stderr)
        sys.exit(1)
    payload = {"name": name, "workspace": spec.get("workspace") or resolve_workspace()}
    if spec.get("team"):
        payload["team"] = spec["team"]
    for k in ("notes", "default_view"):
        if spec.get(k):
            payload[k] = spec[k]
    if "public" in spec:
        payload["public"] = bool(spec["public"])
    if dry_run:
        print(json.dumps({"ok": True, "dry_run": True, "would_create": payload}))
        return
    created = api("POST", "/projects", payload)
    if not created or not isinstance(created.get("data"), dict):
        print(json.dumps({"ok": False, "error": "create failed"}))
        sys.exit(1)
    gid = created["data"]["gid"]
    print(json.dumps({"ok": True, "project_gid": gid,
                      "permalink": f"https://app.asana.com/0/{gid}"}))


# ═══════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════

def main():
    global START_TIME
    START_TIME = time.time()

    parser = argparse.ArgumentParser(description="Asana workspace operations")
    parser.add_argument("--auth", action="store_true", help="Run PKCE OAuth flow")
    parser.add_argument("--configure-app", action="store_true", help="Collect the Asana OAuth app (client id + secret) via a loopback browser form and save it to workspace.json. Used when /pm-setup runs inside Claude Code, where there is no terminal to type a secret into.")
    parser.add_argument("--token", action="store_true", help="Print current access token to stdout (for use by other tools). Auto-auths if missing.")
    parser.add_argument("--hygiene", metavar="PROJECT_GID", help="Run full hygiene audit + fix on a project")
    parser.add_argument("--estimate", metavar="PROJECT_GID", help="Auto-estimate story points on unestimated tasks")
    parser.add_argument("--move-section", nargs=2, metavar=("TASK_GID", "SECTION_GID"), help="Move a task to a section")
    parser.add_argument("--new-phase", nargs=2, metavar=("PROJECT_GID", "PHASE_NAME"), help="Create a new phase (Epic group) in an existing project")
    parser.add_argument("--add-release-option", metavar="PHASE_NAME", help="Add a new enum option to the Release custom field (e.g. 'Phase 5')")
    parser.add_argument("--add-sprint-option", metavar="SPRINT_NAME", help="Add a new enum option to the Sprint custom field (convention: 'Sprint M/D-M/D')")
    parser.add_argument("--add-subtasks-to-project", metavar="TASK_GID", help="[legacy] Add all direct subtasks of TASK_GID to the parent's projects WITHOUT detaching. Superseded by --elevate-subtasks under the flat-task policy.")
    parser.add_argument("--elevate-subtasks", metavar="PROJECT_GID", help="Flat-task fix: promote every subtask in PROJECT_GID to a top-level task (addProject+section, then setParent null), copy the parent's Feature/Theme onto each child, keep the parent EPIC card. Idempotent; repairs dual state.")
    parser.add_argument("--post-comment", nargs="+", metavar="TASK_GID", help="Post a comment on a task. Pass HTML as the second arg, or '-' to read HTML from stdin. Example: --post-comment 1234 '<body><p>hello</p></body>' or echo '<body>...</body>' | --post-comment 1234 -")
    parser.add_argument("--attach-file", nargs=2, metavar=("TASK_GID", "FILE_PATH"), help="Upload a local file as an attachment on a task (fills the MCP gap — MCP can't upload local files). Asana caps a single attachment at 100MB.")
    parser.add_argument("--create-task", metavar="JSON", help="Create a top-level task from a JSON spec (or '-' for stdin). Keys: name, notes, projects[], section, custom_fields{gid:val}, sprint[opt_gid], audit_tag(bool). Covers add-card's rich BACKLOG/INBOX creation — the surface the curated MCP omits. Prints JSON {ok,task_gid,permalink,warnings}.")
    parser.add_argument("--complete-task", metavar="TASK_GID", help="Mark a task complete (used by card-done; the curated MCP omits completion).")
    parser.add_argument("--find-user", metavar="QUERY", help="Find workspace users by name/email substring; prints gid<TAB>name<TAB>email. Used by add-comment to resolve @mentions.")
    parser.add_argument("--create-project", metavar="JSON", help="Create a project from a JSON spec (or '-' for stdin). Keys: name, team, workspace, notes, public, default_view. Used by asana-bootstrap. Prints JSON {ok,project_gid,permalink}.")
    parser.add_argument("--ensure-audit-tag", action="store_true", help=f"Idempotent: ensure the workspace-level '{ADD_CARD_AUDIT_TAG_NAME}' tag exists; prints its gid. Used by the add-card skill to stamp skill-created cards.")
    parser.add_argument("--list-workspaces", action="store_true", help="List the account's Asana workspaces (gid + name).")
    parser.add_argument("--set-workspace", metavar="WORKSPACE_GID", help="Persist the active workspace choice (for multi-workspace accounts). Both the CLI and the MCP server reuse it.")
    parser.add_argument("--pick-workspace", action="store_true", help="Interactively pick the active workspace once and save it.")
    parser.add_argument("--list-projects", action="store_true", help="List non-archived projects in the active workspace (gid<TAB>name). Lets Claude show projects by name so the user picks one to fence the MCP to — no hunting GIDs from URLs.")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.configure_app:
        sys.exit(0 if configure_app_via_browser() else 1)

    if args.auth:
        oauth_auth()
        return

    if args.token:
        # Print token to stdout for use by curl/other tools.
        # Auto-auth if no token exists.
        if not TOKEN_FILE.exists():
            import sys as _sys
            print("No token found — launching OAuth...", file=_sys.stderr)
            oauth_auth()
        token = get_token()
        print(token)
        return

    if args.move_section:
        task_gid, section_gid = args.move_section
        resp = api("POST", f"/sections/{section_gid}/addTask", {"task": task_gid})
        print("OK" if resp else "FAILED")
        return

    if args.add_release_option:
        resp = api("POST", f"/custom_fields/{RELEASE_FIELD_GID}/enum_options",
                   {"name": args.add_release_option, "insert_before": None})
        if resp:
            print(f"Created: {args.add_release_option} → {resp['data']['gid']}")
        else:
            print("FAILED")
        return

    if args.add_sprint_option:
        resp = api("POST", f"/custom_fields/{SPRINT_FIELD_GID}/enum_options",
                   {"name": args.add_sprint_option, "insert_before": None})
        if resp:
            print(f"Created: {args.add_sprint_option} → {resp['data']['gid']}")
        else:
            print("FAILED")
        return

    if args.new_phase:
        create_new_phase(args.new_phase[0], args.new_phase[1], args.dry_run)
        return

    if args.add_subtasks_to_project:
        add_subtasks_to_project(args.add_subtasks_to_project, args.dry_run)
        return

    if args.elevate_subtasks:
        elevate_subtasks(args.elevate_subtasks, args.dry_run)
        return

    if args.post_comment:
        if len(args.post_comment) < 2:
            print("Error: --post-comment requires TASK_GID and HTML (or '-' for stdin)")
            sys.exit(1)
        task_gid = args.post_comment[0]
        html_arg = args.post_comment[1]
        html = sys.stdin.read() if html_arg == "-" else html_arg
        if not html.strip().startswith("<body>") or not html.strip().endswith("</body>"):
            print("Error: HTML must be wrapped in <body>...</body>", file=sys.stderr)
            sys.exit(1)
        resp = api("POST", f"/tasks/{task_gid}/stories", {"html_text": html})
        if resp and isinstance(resp.get("data"), dict):
            story_gid = resp["data"].get("gid", "")
            print(f"OK gid={story_gid}")
        else:
            print("FAILED")
            sys.exit(1)
        return

    if args.attach_file:
        attach_file(args.attach_file[0], args.attach_file[1], args.dry_run)
        return

    if args.create_task:
        create_task(_read_json_arg(args.create_task), args.dry_run)
        return

    if args.complete_task:
        complete_task(args.complete_task, args.dry_run)
        return

    if args.find_user:
        find_user(args.find_user)
        return

    if args.create_project:
        create_project(_read_json_arg(args.create_project), args.dry_run)
        return

    if args.list_workspaces:
        for w in account_workspaces():
            print(f"{w['gid']}\t{w.get('name', '?')}")
        return

    if args.set_workspace:
        names = {w["gid"]: w.get("name", "") for w in account_workspaces()}
        if args.set_workspace not in names:
            print(f"  ✗ {args.set_workspace} is not a workspace on this account", file=sys.stderr)
            sys.exit(1)
        _persist_workspace(args.set_workspace, names[args.set_workspace])
        print(f"Active workspace set: {names[args.set_workspace]} ({args.set_workspace}) → {WORKSPACE_FILE}")
        return

    if args.pick_workspace:
        gid = resolve_workspace(interactive=True)
        print(f"Active workspace: {gid} → {WORKSPACE_FILE}")
        return

    if args.list_projects:
        ws = resolve_workspace()
        for p in paginate(f"/workspaces/{ws}/projects", opt_fields="name,archived"):
            if not p.get("archived"):
                print(f"{p['gid']}\t{p['name']}")
        return

    if args.ensure_audit_tag:
        if ensure_audit_tag(args.dry_run) is None and not args.dry_run:
            sys.exit(1)
        return

    if args.hygiene:
        hygiene_audit(args.hygiene, args.dry_run)
        return

    if args.estimate:
        auto_estimate(args.estimate)
        return

    parser.print_help()
    return


if __name__ == "__main__":
    try:
        main()
    except (AsanaAuthError, AsanaWorkspaceError) as e:
        print(f"  ✗ {e}")
        sys.exit(1)
