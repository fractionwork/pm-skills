#!/usr/bin/env bash
# SUPERSEDED — this now hands off to factory-setup.sh.
#
# It survives only because its URL is in circulation: docs, chat history and
# people's notes point at it, and a bookmarked one-liner that 404s is worse than
# one that redirects. Anyone running the old command gets the current script.
#
#   curl -fsSL https://raw.githubusercontent.com/fractionwork/pm-skills/main/plugins/pm-kit/skills/_shared/wsl-bootstrap.sh -o /tmp/wsl-setup.sh
#   bash /tmp/wsl-setup.sh
#
# WHY IT WENT. factory-setup.sh is a strict superset — the same interop check,
# base packages, GitHub CLI, host key and Claude Code install, plus Node 24, the
# marketplace, the plugins, the scanners and the plugin runtimes. Keeping both
# meant keeping two answers to the same question, and the older one had drifted
# into being wrong: it closed by telling people to add the PRIVATE marketplace
# for pm-kit and to run `gh auth login` first, when pm-kit is published publicly
# precisely so a PM needs neither. It also told them to do by hand what the new
# script does for them, because `claude plugin` gained a CLI after it was
# written.
#
# Every argument is passed straight through, so `--check` still works.

set -uo pipefail

TARGET_URL="https://raw.githubusercontent.com/fractionwork/pm-skills/main/plugins/pm-kit/skills/_shared/factory-setup.sh"
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL="$HERE/factory-setup.sh"

printf '\n  \033[33m⊙\033[0m wsl-bootstrap has been replaced by factory-setup.\n'
printf '    Same job, and it now finishes it: Node 24, the marketplace and the\n'
printf '    plugins are installed for you rather than listed as homework.\n\n'
printf '    Handing off — nothing for you to do.\n\n'

# Prefer the copy sitting next to this one; fall back to fetching it. A machine
# running the bookmarked one-liner has only this file, so the fetch is the
# normal path rather than the exception.
if [ -r "$LOCAL" ]; then
  exec bash "$LOCAL" "$@"
fi

DEST="${TMPDIR:-/tmp}/factory-setup.sh"
if curl -fsSL "$TARGET_URL" -o "$DEST" 2>/dev/null; then
  exec bash "$DEST" "$@"
fi

printf '  \033[31m✗\033[0m could not fetch factory-setup.sh\n'
printf '    Run it yourself:\n\n'
printf '      curl -fsSL "%s" -o /tmp/factory-setup.sh && bash /tmp/factory-setup.sh\n\n' "$TARGET_URL"
exit 1
