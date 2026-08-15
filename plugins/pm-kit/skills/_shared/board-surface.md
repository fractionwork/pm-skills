# Which board tools to call

Shared by every skill that touches a project board. Read this once when a skill
points you here.

## Why this file exists

These skills are written to be tool-neutral — they describe what to do to a
board, not which MCP to do it through — and the plugin tests enforce that by
banning hardcoded tool ids from every `SKILL.md`. That is right, but on its own
it leaves the binding to judgement, and there is a wrong answer with a real cost:

> **Two servers may be connected at once.** pm-kit ships an Asana server that
> uses **your own** Asana credential. The factory server uses the **project's**
> credential and stamps every write with a `Source:` line naming you. Picking the
> wrong one silently writes to a client's board as yourself, with no attribution
> and no project scoping.

So resolve capabilities through the table below rather than by name similarity.

## Which surface am I on?

| | when | how you can tell |
|---|---|---|
| **Factory** | the project is registered with a factory engine | `mcp__factory__*` tools exist AND the project resolves (see `factory.md`) |
| **Asana-direct** | no factory, or a board the factory does not know | pm-kit's own Asana tools exist |

**Prefer the factory when both are available.** It works on Asana, Linear and
Azure DevOps; it uses the credential that belongs to the project rather than to
you; and it records who asked. The Asana-direct path is for boards no factory
knows about — a prospect's, a personal one — and for structural work no MCP can
do (see the bottom of this file).

**Say which one you used** in your confirmation output. "Commented via the
factory on SPIN-337" and "Commented as you, directly on Asana" are different
events on a client's board, and the person reading should not have to guess.

## The table

Every factory tool takes `project_key` as its first argument.

| capability | factory | Asana-direct |
|---|---|---|
| list what is on the board | `board_list_items` | `list_project_tasks` |
| search the board | `board_search_items` | `search_tasks` |
| read one item | `board_get_item` | `get_task` |
| read an item's comments | `board_list_comments` | `get_task_comments` |
| list the columns | `board_list_sections` | *(none — sections are implicit)* |
| list assignable people | `board_list_users` | *(none)* |
| what is assigned to me | `board_list_users` → match your email → `board_list_items` | `list_my_tasks` |
| comment | `board_add_comment` | `add_comment` |
| move to a column | `board_move_item` | `move_task_to_section` |
| assign | `board_assign_item` | `assign_task` |
| mark finished | `board_move_item` to the board's done column | `complete_task` |
| create a card the factory should work | `submit_idea` | `capture_inbox_idea` |
| board policy audit | *(none yet)* | `run_hygiene` |

### Three that need care

**"What is assigned to me" is two calls on the factory, and that is deliberate.**
The factory writes with a **service account**, so `assignee: me` on the board is
the bot — its queue is nobody's personal list. Call `board_list_users`, match the
email of the person asking, then filter by that id. **If no email matches, say so
and ask which board user they are.** Never fall back to the factory's own
account: a plausible wrong answer to "what's on my plate" gets acted on.

**`submit_idea`, not a plain create.** It creates the board item *and* the engine
card *and* starts the pipeline. Creating the item directly would produce a card
the factory never sees, which looks identical on the board and behaves nothing
alike.

**Ids are not interchangeable.** `board_*` tools take the **board's** id;
`get_card` / `update_card` take the **factory card** id. They are different
objects — a board item that never passed the intake gate has no card at all — so
`get_card` finding nothing is often the correct answer rather than an error.
`board_get_item` returns `cardId` when the two correspond; use it to cross over.

## What the factory cannot do

Structural work on an Asana board — creating custom fields, creating or removing
sections, adding enum options, creating workspace tags, changing project admins.
None of it is on the connector interface, deliberately: implementing it would
mean three implementations of board surgery, and it would put board-admin reach
into a credential shared across a whole project.

Those stay Asana-direct, under **your** credential, in `asana-bootstrap` and
`asana-hygiene`. If an audit turns up findings that need them, say so plainly and
name the skill rather than trying to do it through the factory.
