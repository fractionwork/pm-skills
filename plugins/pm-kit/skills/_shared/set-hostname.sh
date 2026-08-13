#!/usr/bin/env bash
# set-hostname.sh — rename this machine, without breaking sudo.
#
# Usage:  bash set-hostname.sh [name]        (default: factory-demo)
#         bash set-hostname.sh --check       report, change nothing
#
# WHY THIS IS NOT `hostname factory-demo`.
#
# Renaming a box is two facts that have to agree: what it calls itself, and what
# it resolves to. Change only the first and every single `sudo` prints
#
#     sudo: unable to resolve host factory-demo: Name or service not known
#
# on a two-second delay, forever, because sudo looks its own hostname up. That
# is what this script exists to prevent — it is the reported failure, not a
# hypothetical one.
#
# WHY IT DOES NOT SET `generateHosts = false`.
#
# WSL regenerates /etc/hosts at boot and the file it writes ALREADY contains
# `127.0.1.1  <name>.localdomain  <name>` for whatever hostname wsl.conf
# declares — verified on a live distro. So the persistent fix is the wsl.conf
# hostname alone. Turning generation off makes you the owner of /etc/hosts
# forever, including the Windows-side entries WSL injects, to solve a problem
# you no longer have.
#
# The /etc/hosts edit below is therefore a BRIDGE, not the fix: it stops sudo
# warning between now and the restart that regenerates the file properly.
#
# SCOPE: THE WSL DISTRO ONLY. Nothing here touches Windows. That is worth
# stating because the default distro hostname IS the Windows machine name —
# WSL copies it at first boot — so renaming the distro can look like it is
# about to rename the PC. It is not: every write below is inside the Linux
# filesystem (/etc/wsl.conf, /etc/hosts) or the Linux kernel's own hostname.
# Your Windows computer name is untouched, and `wsl --shutdown` only stops the
# WSL VM. The script REFUSES to run anywhere that is not WSL, rather than
# falling back to hostnamectl, which on a real Linux box is a genuine system
# rename — the one thing this is not for.

set -uo pipefail

NAME="${1:-factory-demo}"
CHECK=0
case "${1:-}" in
  --check) CHECK=1; NAME="$(hostname 2>/dev/null)" ;;
  -h|--help) sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) echo "set-hostname: unknown option '$1'" >&2; exit 2 ;;
esac

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m⊙\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
say()  { printf '    %s\n' "$1"; }

is_wsl() { grep -qiE "microsoft|wsl" /proc/version 2>/dev/null; }

# RFC 1123: letters, digits and hyphens; no leading/trailing hyphen; <= 63 chars.
# Rejected rather than sanitised — silently renaming a box to something the user
# did not type is worse than refusing.
valid_name() {
  case "$1" in
    ''|*[!a-zA-Z0-9-]*) return 1 ;;
    -*|*-) return 1 ;;
  esac
  [ "${#1}" -le 63 ]
}

# Section-aware INI write. A plain `printf >> /etc/wsl.conf` produces a SECOND
# [network] section, which WSL resolves in a way nobody can predict — and that
# file already carries [boot] and often [interop], so appending is not safe.
ini_set() {
  local file="$1" section="$2" key="$3" value="$4" tmp
  tmp="$(mktemp)" || return 1
  sudo touch "$file" 2>/dev/null
  awk -v sect="$section" -v key="$key" -v val="$value" '
    function flush_blanks(  i) { for (i = 1; i <= nb; i++) print ""; nb = 0 }
    BEGIN { in_s = 0; done = 0; nb = 0 }
    /^[[:space:]]*$/ { if (in_s) { nb++; next } print; next }
    /^[[:space:]]*\[/ {
      if (in_s && !done) { print key " = " val; done = 1 }
      flush_blanks()
      in_s = ($0 ~ "^[[:space:]]*\\[" sect "\\][[:space:]]*$")
      if (in_s) seen = 1
      print; next
    }
    {
      flush_blanks()
      if (in_s && $0 ~ "^[[:space:]]*" key "[[:space:]]*=") {
        if (!done) { print key " = " val; done = 1 }
        next
      }
      print
    }
    END {
      if (in_s && !done) { print key " = " val; done = 1 }
      flush_blanks()
      if (!seen) { print ""; print "[" sect "]"; print key " = " val }
    }
  ' "$file" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  sudo cp "$tmp" "$file" && rm -f "$tmp"
}

# Point 127.0.1.1 at $1, replacing any existing 127.0.1.1 line. Debian's
# convention for the machine's own name — distinct from 127.0.0.1/localhost,
# which must keep pointing at localhost.
hosts_point_at() {
  local n="$1" tmp
  tmp="$(mktemp)" || return 1
  # Built whole, then written back by TRUNCATING the original — never by
  # renaming a temp file over it, which is what `sed -i` does. /etc/hosts is
  # frequently a bind mount or a hardlink (containers, some WSL setups), and a
  # rename onto one fails with "Device or resource busy" while an in-place
  # write succeeds. Same reason `tee` and not `mv`.
  {
    grep -vE "^127\.0\.1\.1[[:space:]]" /etc/hosts 2>/dev/null
    printf '127.0.1.1\t%s.localdomain\t%s\n' "$n" "$n"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  sudo tee /etc/hosts < "$tmp" >/dev/null
  local rc=$?
  rm -f "$tmp"
  return $rc
}

report() {
  local h; h="$(hostname 2>/dev/null)"
  printf '\n\033[1mhostname\033[0m\n'
  ok "running as: $h"
  if getent hosts "$h" >/dev/null 2>&1; then ok "resolves — sudo is quiet"
  else bad "does NOT resolve — sudo warns on every call"; fi
  if is_wsl; then
    local declared; declared="$(sed -n 's/^[[:space:]]*hostname[[:space:]]*=[[:space:]]*//p' /etc/wsl.conf 2>/dev/null | head -1)"
    if [ -n "$declared" ]; then
      ok "/etc/wsl.conf declares: $declared"
      # The interesting case: set but not yet applied. Says exactly what to do.
      [ "$declared" != "$h" ] && warn "not applied yet — run 'wsl --shutdown' in PowerShell"
    else
      warn "/etc/wsl.conf declares no hostname — this name will not survive a restart"
    fi
  fi
  printf '\n'
}

[ "$CHECK" = "1" ] && { report; exit 0; }

valid_name "$NAME" || {
  bad "'$NAME' is not a valid hostname"
  say "letters, digits and hyphens only; no leading or trailing hyphen; 63 chars max"
  exit 2
}

# Refuse before writing anything. Outside WSL there is no /etc/wsl.conf to own
# the name, so the only way to honour the request would be a real system
# rename — which is explicitly not what this is for.
is_wsl || {
  bad "not running under WSL — refusing"
  say "this script renames a WSL DISTRO and nothing else. On a normal Linux box"
  say "the equivalent is a real system rename: sudo hostnamectl set-hostname <name>"
  exit 2
}

printf '\n\033[1mrenaming to %s\033[0m\n' "$NAME"

# 1. Persist it. On WSL this is the ONLY durable place — /etc/hostname is
#    rewritten on every boot from wsl.conf (or from the Windows machine name
#    when wsl.conf says nothing), so editing it alone reverts silently.
if ini_set /etc/wsl.conf network hostname "$NAME"; then
  ok "/etc/wsl.conf: [network] hostname = $NAME"
else
  bad "could not write /etc/wsl.conf"; exit 1
fi

# 2. Apply it to the RUNNING kernel, so this session matches. Not persistent by
#    itself — step 1 is what survives.
sudo hostname "$NAME" 2>/dev/null && ok "running hostname is now $NAME" \
  || warn "could not set the running hostname (it will apply after a restart)"

# 3. Make it resolve NOW. WSL will regenerate /etc/hosts correctly on the next
#    boot; this is the bridge so sudo stops warning immediately.
if hosts_point_at "$NAME" && getent hosts "$NAME" >/dev/null 2>&1; then
  ok "resolves — sudo will not warn"
else
  bad "could not make $NAME resolve"
  say "add by hand:  127.0.1.1\t$NAME"
fi

printf '\n'
printf '\033[1;33m  One more step:\033[0m run this in \033[1mPowerShell\033[0m to make it permanent —\n\n'
printf '      \033[1mwsl --shutdown\033[0m\n\n'
say "WSL reads [network] at boot only. Until then this session is renamed but"
say "the distro is not, and a new terminal may still show the old name."
say "This stops the WSL VM. It does not touch Windows or its computer name."
printf '\n'
