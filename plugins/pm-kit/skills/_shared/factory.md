# Consulting the factory from a plugin skill

Shared by every ship-kit skill that can be factory-aware. Read this once when a
skill points you here; the rules are the same everywhere.

## The contract, in one line

**The factory ADVISES. The human decides. A repo that is not registered behaves
exactly as it did before the factory existed.**

## How to tell whether this repo is a factory project

```bash
node "${CLAUDE_PLUGIN_ROOT}/skills/_shared/factory-detect.mjs"
```

Returns `{slug, branch, cwd}` — the repo's `owner/name` (or ADO's
`org/project/repo`), derived deterministically from the git remote. Then:

1. If the `mcp__factory__*` tools are **absent**, stop. This machine is not
   connected to a factory. Say nothing about it; it is not an error, and a user
   who never asked for the factory should not be told about one.
2. If they are present, call `list_projects` and look for a project whose `repo`
   equals the slug.
3. **No match → the repo is not registered.** Continue exactly as you would
   have, and do not mention the factory.

**Registration IS the opt-in.** There is no config file to add and no flag to
set. This matters because plugins auto-propagate on merge with no staging ring:
a change here reaches every installed client on the next merge, so the default
for an unregistered repo has to be "does nothing".

## What you may and may not do

**May, freely — reads.** `next_card`, `project_status`, `get_card`,
`list_decisions`, `list_project_settings`, `project_readiness`. They change
nothing and cost nothing.

**May, when the human's action implies it — writes.** `update_card` and card
transitions, only as the mirror of something the human just did (finished a
card, picked one up). Never speculatively.

**May, after the work — `record_activity`.** One row per completed skill run, so
`/factory stats` and the panel describe the whole delivery team rather than only
its agent half. The rules:

- **After, not before.** Call it once, with the outcome you already know. Do not
  open a row at the start and hope to close it — a skill that ends early leaves
  a row running forever, which is the ghost-agent bug the panel already had to
  fix once.
- **Namespace the activity** — `ship-kit/feature-build`, not `build`. Stats group
  by that string, so an agent stage name would merge two populations into one
  row and quietly corrupt both.
- **`actor_id` is the human's email**, and it is self-reported: the API token
  authenticates the token, not the person. A convention among colleagues, not an
  audit control.
- **Record failures too.** A skill that only records its successes produces a
  100% success rate, which is worse than no rate at all.
- The server forces `kind: 'human'` and records no cost, so neither is yours to
  get wrong.

**Never.** Do not enable a project, unpause one, change `trust.*`,
`pipeline.activities`, or a gate floor from inside a delivery skill. Those are
`onboard`'s job and a human's decision. A skill that quietly widens what the
factory may do unattended is the one failure mode there is no recovering from.

## Never block the human

Every factory call is best-effort:

- a call that **fails** → note it in one line, continue the skill
- a call that is **slow** → do not wait on it to show the human their work
- a call that **contradicts** the human → show both, let them choose

The factory's rank is an opinion computed from board priority, due date and
estimate. The human sitting in front of the repo knows things it does not.

## Saying where a claim came from

When you show factory data, say so — `factory: WSJF rank 3 of 11`, not a bare
`rank 3`. A number with no provenance is indistinguishable from one you made up,
and the whole point of consulting a shared ledger is that two people looking at
it see the same thing.
