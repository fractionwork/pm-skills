#!/usr/bin/env bash
# SessionStart hook — inject the PM operating rules as session context.
#
# Replaces the old installer behaviour of splicing this prose into the user's
# ~/.claude/CLAUDE.md between marker comments. That was worse in three ways: the
# rules couldn't version or roll back with the tooling that owns them, a re-run
# had to surgically patch a user-owned file (which broke once), and uninstalling
# the tooling left the prose behind.
#
# Deliberately terse. This fires on EVERY session in EVERY repo for anyone who
# has pm-kit installed, including sessions that touch no board at all, so it
# pays for itself only by staying short. The full text — rationale, source-line
# formats, per-system muting flags — lives in skills/_shared/operating-rules.md
# and is read on demand by the skills that need it.
#
# The rules that can be enforced in code are enforced in the MCP server, not
# here (see _require_source / _bulk_silent in skills/_shared/asana_mcp.py). This
# hook covers the residual case: a human or model reasoning about board work
# without having loaded a skill.

set -u

read -r -d '' RULES <<'EOF' || true
## PM operating rules (pm-kit)

Applies to every project-board operation, without being asked:

1. **Source attribution.** When research — a meeting transcript, an email, a Slack
   thread, or the codebase — informs a card change (create / rename / description
   / status move), do BOTH: put a `Source: …` line in the description, AND post a
   comment quoting the evidence. Descriptions get rewritten; the comment is the
   audit trail. pm-kit's Asana MCP requires a `source` argument on state-changing
   tools, so this is enforced there rather than left to memory.

2. **Mute bulk notifications.** Batches of 6+ card transitions mute notifications
   (Asana `silent=true`, Linear `notifySubscribers: false`, batch
   endpoints); say that you muted. Single operations notify normally. For batches
   of ≤5, ask.

Never call a PM MCP's raw `create_task*` / `create_story` / `create_issue`
directly — use the `add-card` skill, which applies field, section, duplicate and
attribution rules at creation time.

Full text: `${CLAUDE_PLUGIN_ROOT}/skills/_shared/operating-rules.md`
EOF

# jq is not a dependency of this kit, so build the JSON with python3 (already
# required by the Asana MCP) and fall back to emitting nothing rather than
# emitting malformed JSON, which would surface as a hook error every session.
if command -v python3 >/dev/null 2>&1; then
  RULES="$RULES" python3 -c '
import json, os
print(json.dumps({
    "hookSpecificOutput": {
        "hookEventName": "SessionStart",
        "additionalContext": os.environ["RULES"],
    }
}))'
fi
