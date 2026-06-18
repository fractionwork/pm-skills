#!/usr/bin/env python3
"""ado_auth.py — Azure DevOps PAT resolution for seed skills/tools.

Mirrors the token-resolution pattern of asana_ops.get_token(): a single helper that
any ADO-touching skill imports, plus a tiny CLI to manage credentials.

PAT resolution order (most explicit wins):
  1. ADO_PAT environment variable
  2. an explicit --pat-file / pat_file (chmod-600 enforced)
  3. the central per-org store ~/.claude/.ado-credentials.json (chmod 600, git-ignored),
     keyed by org URL — a PAT is org-scoped, so one entry serves every project + skill.

A PAT is a secret: it is never echoed, never accepted on argv (use stdin), and the
store + any pat-file must not be group/world-readable.

CLI:
  ado_auth.py --set-pat <org-url> [--scope ...] [--note ...] [--expires YYYY-MM-DD]   # reads PAT from stdin
  ado_auth.py --list                 # masked (last 4 only) + scope + expiry
  ado_auth.py --get-pat <org-url>    # prints the PAT to stdout (for piping into a tool)
  ado_auth.py --rm <org-url>
Recommended minimal scope for read-only mirrors: Work Items (Read)  →  vso.work
"""
import argparse
import json
import os
import stat
import sys
from datetime import date
from pathlib import Path

STORE_PATH = Path(os.environ.get("ADO_CREDENTIALS_FILE",
                                 str(Path.home() / ".claude" / ".ado-credentials.json")))


def _die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def _norm(org):
    return (org or "").rstrip("/")


def _check_perms(p):
    if p.exists() and (p.stat().st_mode & 0o077):
        _die(f"{p} is group/world-accessible — `chmod 600 {p}` first (it holds a secret)")


def _load():
    if not STORE_PATH.exists():
        return {"version": 1, "orgs": {}}
    _check_perms(STORE_PATH)
    return json.loads(STORE_PATH.read_text())


def _save(store):
    STORE_PATH.parent.mkdir(parents=True, exist_ok=True)
    STORE_PATH.write_text(json.dumps(store, indent=2))
    os.chmod(STORE_PATH, stat.S_IRUSR | stat.S_IWUSR)  # 600


def get_pat(org, pat_file=None):
    """Return a PAT for `org` (env → pat_file → central store), or None if none found.
    Raises SystemExit on a world-readable pat_file. Callers build the Basic header:
    base64(':' + pat)."""
    env = os.environ.get("ADO_PAT")
    if env:
        return env.strip()
    if pat_file:
        p = Path(pat_file).expanduser()
        if not p.exists():
            _die(f"--pat-file {p} not found")
        _check_perms(p)
        return p.read_text().strip()
    entry = _load().get("orgs", {}).get(_norm(org))
    if entry and entry.get("pat"):
        exp = entry.get("expires")
        if exp and str(exp) < date.today().isoformat():
            print(f"  ! ADO PAT for {org} expired {exp} — rotate it", file=sys.stderr)
        return entry["pat"].strip()
    return None


def require_pat(org, pat_file=None):
    pat = get_pat(org, pat_file)
    if not pat:
        _die(f"no ADO PAT for {org}. Add one:  "
             f"echo -n '<PAT>' | python3 {Path(__file__).name} --set-pat {org}\n"
             f"       (minimal scope for a read-only mirror: Work Items → Read). "
             f"Do NOT reuse a PAT that has been printed in a chat/transcript — rotate it.")
    return pat


def _set_pat(org, scope, note, expires):
    if sys.stdin.isatty():
        _die("pipe the PAT via stdin, e.g.  echo -n '<PAT>' | ado_auth.py --set-pat <org>  "
             "(never pass a secret on the command line)")
    pat = sys.stdin.read().strip()
    if not pat:
        _die("empty PAT on stdin")
    store = _load()
    store.setdefault("orgs", {})[_norm(org)] = {
        "pat": pat, "scope": scope or "", "note": note or "", "expires": expires or ""}
    _save(store)
    print(f"stored PAT for {_norm(org)} (…{pat[-4:]}) → {STORE_PATH}")


def _list():
    orgs = _load().get("orgs", {})
    if not orgs:
        print("(no ADO credentials stored)")
        return
    for org, e in orgs.items():
        pat = e.get("pat", "")
        masked = f"…{pat[-4:]}" if pat else "(none)"
        extra = " ".join(filter(None, [
            f"scope={e['scope']}" if e.get("scope") else "",
            f"expires={e['expires']}" if e.get("expires") else "",
            f"# {e['note']}" if e.get("note") else ""]))
        print(f"{org}\t{masked}\t{extra}")


def main():
    ap = argparse.ArgumentParser(description="Manage Azure DevOps PATs for seed skills.")
    ap.add_argument("--set-pat", metavar="ORG_URL", help="Store a PAT for an org (PAT read from stdin).")
    ap.add_argument("--get-pat", metavar="ORG_URL", help="Print the PAT for an org to stdout (for piping).")
    ap.add_argument("--list", action="store_true", help="List stored orgs (masked).")
    ap.add_argument("--rm", metavar="ORG_URL", help="Remove an org's stored PAT.")
    ap.add_argument("--scope", help="Note the PAT's scope (e.g. 'Work Items: Read').")
    ap.add_argument("--note", help="Free-text note (e.g. who/what it's for).")
    ap.add_argument("--expires", metavar="YYYY-MM-DD", help="Expiry date, for rotation warnings.")
    args = ap.parse_args()

    if args.set_pat:
        _set_pat(args.set_pat, args.scope, args.note, args.expires)
    elif args.get_pat:
        pat = get_pat(args.get_pat)
        if not pat:
            _die(f"no PAT stored for {args.get_pat}")
        print(pat)
    elif args.list:
        _list()
    elif args.rm:
        store = _load()
        if store.get("orgs", {}).pop(_norm(args.rm), None) is None:
            _die(f"no entry for {args.rm}")
        _save(store)
        print(f"removed {_norm(args.rm)}")
    else:
        ap.print_help()


if __name__ == "__main__":
    main()
