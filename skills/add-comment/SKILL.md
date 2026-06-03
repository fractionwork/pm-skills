---
name: add-comment
description: >
  Post a comment on a PM card (Asana / Shortcut / Linear / Jira), converting
  Markdown or plain text into the format each system accepts — Asana's narrow
  HTML allowlist is validated before the call so you never hit a silent 400.
  Triggers on "comment on card X", "add a comment", "leave a note on the
  ticket", "reply on the card", "post update to <card>", "@mention <person> on
  <card>". NOT for project status updates, editing a card's description, or bulk
  commenting (loop with notifications muted).
seed_managed: true
requires_mcp_any_of: [asana, shortcut, linear]
---

# Add Comment

Post a properly-formatted comment on a single PM card. Per-system formatting rules and validation are baked in so the call doesn't fail at the API.

## Step 1: Resolve the target card

If the user names the card by ID/permalink/URL, use it directly.

If the user references it by description ("the approver dropdown ticket", "the bug Austin filed"), search the active project via the appropriate MCP:
- **Asana**: `asana_search_tasks` against the project, scored by title overlap
- **Shortcut**: search via MCP, filter to non-archived
- **Linear**: search team issues
- **Jira**: search via Atlassian Rovo MCP with JQL

If multiple matches, list the top 5 with permalinks and ask which one. Don't guess.

## Step 2: Detect the host system

Read the resolved card's URL to identify the system:
- `app.asana.com` → Asana
- `app.shortcut.com` → Shortcut
- `linear.app` → Linear
- `*.atlassian.net` → Jira

The formatting contract is per-system. **Never** assume Markdown is universally accepted — it isn't.

## Step 3: Build the comment body

Take the user's input (typically Markdown, sometimes plain text) and convert it to the host system's accepted format.

### Asana — HTML subset, mandatory

Asana accepts only a narrow allowlist. Anything else returns a 400 with an unhelpful message. The full set:

| Element | Tag | Notes |
|---|---|---|
| Document root | `<body>...</body>` | Required wrapper |
| Headings | `<h1>`, `<h2>` | Cap at h2 — h3+ is silently flattened |
| Paragraph | `<p>` | Use for paragraph breaks |
| Line break | `<br/>` | Inline break inside a paragraph |
| Bold | `<strong>` | NOT `<b>` — rejected |
| Italic | `<em>` | NOT `<i>` — rejected |
| Underline | `<u>` | |
| Strikethrough | `<s>` | |
| Inline code | `<code>` | |
| Code block | `<pre>` | Wraps multi-line code |
| Link | `<a href="...">text</a>` | |
| Mention | `<a data-asana-gid="<user-gid>">@Name</a>` | See Step 4 |
| Unordered list | `<ul><li>...</li></ul>` | |
| Ordered list | `<ol><li>...</li></ol>` | |
| Blockquote | `<blockquote>` | |

**Rejected** (do not emit, even if the user pastes them in): `<div>`, `<span>`, `<img>`, `<table>`, `<b>`, `<i>`, inline `style=`, `class=`, `id=`, custom `data-*` attributes other than `data-asana-gid` on `<a>`.

Markdown → HTML conversion:

| Markdown | HTML |
|---|---|
| `**bold**` or `__bold__` | `<strong>bold</strong>` |
| `*italic*` or `_italic_` | `<em>italic</em>` |
| `~~strike~~` | `<s>strike</s>` |
| `` `code` `` | `<code>code</code>` |
| ` ```lang\n…\n``` ` | `<pre>…</pre>` (drop language) |
| `[text](url)` | `<a href="url">text</a>` |
| `# heading` | `<h1>heading</h1>` |
| `## heading` | `<h2>heading</h2>` |
| `### heading` | `<h2>heading</h2>` (cap) |
| `- item` | `<ul><li>item</li></ul>` |
| `1. item` | `<ol><li>item</li></ol>` |
| `> quote` | `<blockquote>quote</blockquote>` |
| Blank line | `</p><p>` (paragraph break) |

After conversion, **strip any tag not in the allowlist** — keep the inner text. Don't try to be clever about substitution. If the user pasted `<div class="warn">…</div>`, output the inner text inside the surrounding `<p>`.

Final wrap: `<body>...</body>`. No leading/trailing whitespace outside the wrapper.

### Shortcut, Linear — Markdown

Both accept GitHub-flavored Markdown directly. Pass the user's input through with two normalizations:

1. **Mention syntax** — Shortcut uses `@<username>`; Linear uses `@<user-display-name>`. If the user wrote a name that doesn't match the platform's mention syntax, resolve via Step 4 and rewrite.
2. **Code fences** — preserve language identifiers (`` ```ts ``); both render them.

No HTML conversion needed.

### Jira — ADF or wiki markup

Jira is the most painful. Two paths:

- **Wiki markup** (simple cases) — Atlassian Rovo MCP's `addCommentToJiraIssue` typically accepts wiki markup directly. Use this for plain-text or lightly-formatted comments. Conversion table: `**bold**` → `*bold*`, `*italic*` → `_italic_`, `` `code` `` → `{{code}}`, `[text](url)` → `[text|url]`, `- item` → `* item`, `1. item` → `# item`, `> quote` → `bq. quote`.
- **ADF** (rich content) — only when the user needs tables, panels, or other structured nodes. Construct the ADF JSON. Out of scope for this skill's default path; if the user explicitly asks for a table or panel, fall back to ADF.

If the MCP rejects wiki markup, the error will name ADF. Retry via ADF construction; if still failing, surface the error and ask the user to simplify.

## Step 4: Resolve mentions

When the user writes `@<name>` in their input:

1. **Asana** — search workspace users via MCP `mcp__claude_ai_Asana__get_users` (or the script equivalent) for `<name>`. Disambiguate by full name + email if multiple. Replace `@Jane` with `<a data-asana-gid="<user-gid>">@Jane</a>`. If no match, leave as plain text and warn the user.
2. **Shortcut** — search members via MCP. Replace with `@<username>` (Shortcut uses usernames, not display names).
3. **Linear** — search users via MCP. Replace with the form Linear's API expects (typically `@<display-name>`).
4. **Jira** — Atlassian uses account IDs in mentions: `[~accountid:<id>]` for wiki markup, or the `mention` ADF node. Resolve via `mcp__claude_ai_Atlassian_Rovo__lookupJiraAccountId`.

Always show the user the resolved mention ("→ tagging Jane Smith <jane@example.com>") before posting if there was any ambiguity.

## Step 5: Validate before posting

This is the step that prevents the silent-failure mode. Run system-specific checks:

### Asana validation

After conversion + allowlist strip, verify:

- The full output is wrapped in `<body>...</body>` (exactly one wrapper, at the outer edge).
- No tag outside the allowlist appears anywhere in the body.
- Every `<a href="...">` has a non-empty `href`.
- Every `<a data-asana-gid="...">` has a non-empty gid AND wraps a non-empty text node starting with `@`.
- No nested `<p>` (paragraphs cannot nest in Asana's parser).
- No bare text outside a block element — wrap loose text in `<p>`.

If any check fails, **do not post**. Show the user what tripped the check and ask whether to strip + retry.

### Shortcut, Linear

No structured validation — the format is forgiving. Sanity-check: comment is not empty, mentions resolved.

### Jira

If using wiki markup, no validation. If using ADF, verify the JSON shape matches the schema (ADF requires `type: "doc"`, `version: 1`, and a `content` array of valid nodes).

## Step 6: Post the comment

| System | How |
|---|---|
| **Asana** | `mcp__claude_ai_Asana__add_comment` with the assembled HTML. If the MCP isn't available, fall back to `python3 scripts/asana_ops.py --post-comment <task_gid> '<html>'`. |
| **Shortcut** | MCP if available; else `POST /stories/<story_id>/comments` via `scripts/shortcut_ops.py --post-comment <story_id> '<markdown>'`. |
| **Linear** | Linear MCP `createComment` with `body: <markdown>`. |
| **Jira** | `mcp__claude_ai_Atlassian_Rovo__addCommentToJiraIssue` with the assembled body. |

If the post returns an error:
- **Asana 400** with allowlist violation message → surface the offending tag, offer to strip + retry.
- **Asana 403** → user lacks comment permission on this task. Stop, report.
- **Any system 404** → card not found; double-check the resolution from Step 1.
- **Any system 429** → rate-limited; back off per the system's `Retry-After` header.

## Step 7: Confirm

Report back:
- Card name + permalink
- Comment permalink (if the API returns one — Asana's `add_comment` returns a story gid, build the URL)
- Any mentions that were resolved (so the user can verify the right person was tagged)
- Any tags that got stripped during validation (so the user knows the formatting wasn't lossless)

Example confirmation:
```
✓ Comment posted on "ELEVAT3 - Approver dropdown bug" (https://app.asana.com/...)
  Tagged: @Jane Smith
  Stripped: <div class="warn"> (content preserved as plain text)
```

## When NOT to use this skill

- **Editing a card's description** — that's a card-edit operation, not a comment. Different MCP call, different validation surface.
- **Project-wide status updates** — Asana has a separate `/project_statuses` endpoint; Shortcut has Workspace updates. Use the project-status flow.
- **Bulk commenting** (>5 cards) — loop this skill, but per `feedback_pm_bulk_notifications.md` mute notifications: Asana `silent=true`, Linear `notifySubscribers:false`. Don't blast the assignee/follower list.

## Reference

Asana rich-text spec (canonical): https://developers.asana.com/reference/rich-text

If the allowlist appears to have changed (Asana adds new tag support, deprecates an old one), update this skill's Step 3 table and the validation in Step 5. The allowlist drifts slowly but does drift.
