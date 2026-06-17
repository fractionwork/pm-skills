---
name: test-gen
profiles: [engineer]
description: >
  Generate and run tests for recently written feature code. Reads the diff,
  categorizes changes, and produces unit tests (Vitest), integration tests
  (Vitest + DB), and E2E tests (Playwright) following DevHawk conventions.
  Triggers on "write tests", "generate tests", "test this feature", "qa",
  "add tests", "test-gen", or any request to create tests for recent work.
seed_managed: true
requires_tools: [pnpm, node]
---

# Test Generation

Generate tests for recently changed code. Read docs/testing-patterns.md before writing any test.

## Step 1: Detect what changed

```bash
BASE=$(git rev-parse --verify origin/develop 2>/dev/null && echo develop || echo main)
git diff "$BASE"...HEAD --name-only
```

Categorize each changed file:

| File pattern | Category | Test type |
|---|---|---|
| `lib/db/schema/*.ts` | Schema | Unit (Vitest) |
| `"use server"` in file | Server Action | Integration (Vitest + DB) |
| `app/api/*/route.ts` | API route | Integration (Vitest) |
| `lib/jobs/processors/*.ts` | BullMQ processor | Unit (Vitest) |
| `app/**/page.tsx` (new critical flow) | User flow | E2E (Playwright) |
| `components/**/*.tsx` | UI component | Skip — don't test shadcn/ui internals |
| `lib/ai/*.ts` | AI tool/agent | Unit (Vitest, mock provider) |

## Step 2: Generate tests by category

### Schema → Unit test

For each new/modified schema file, generate `tests/unit/[domain].test.ts`:
```typescript
import { describe, it, expect } from "vitest";
import { insertXSchema } from "@/lib/db/schema/[domain]";

describe("insertXSchema", () => {
  it("accepts valid data", () => { /* valid input → success */ });
  it("rejects missing required fields", () => { /* partial input → failure */ });
  it("rejects invalid values", () => { /* out-of-range, wrong type → failure */ });
});
```

### Server Action → Integration test

For each Server Action, generate `tests/integration/[action].test.ts`:
```typescript
import { describe, it, expect, beforeEach } from "vitest";
import { db } from "@/lib/db";

describe("[actionName]", () => {
  it("returns { success: true } with valid input", () => { /* happy path */ });
  it("returns { success: false } without auth", () => { /* no session → unauthorized */ });
  it("validates input with Zod", () => { /* invalid input → error message */ });
  // Org variant: it("filters by organizationId", () => { /* wrong org → not found */ });
  // Solo variant: it("requires admin role for admin-only mutations", () => { /* role=user → forbidden */ });
});
```

### API route → Integration test

For webhook routes, test signature verification + correct status codes. For external API routes, test auth + response shape.

### BullMQ processor → Unit test

Test the processor function directly with mock job data. Verify it returns expected results and handles errors by throwing (BullMQ retries).

### E2E → Playwright spec

**Only for critical user flows** — auth (sign up, sign in), core workflow, payment. Not every page.

Generate `tests/e2e/[flow].spec.ts`:
```typescript
import { test, expect } from "@playwright/test";

test("[flow description]", async ({ page }) => {
  await page.goto("/[starting-page]");
  // interact with elements
  // assert final state
});
```

Use the **Playwright MCP** (if available) to interact with the running app and derive selectors from real page state instead of guessing. Start the dev server first: `pnpm dev`.

## Step 3: Write test files

Follow naming conventions from docs/testing-patterns.md:
- `tests/unit/[module].test.ts`
- `tests/integration/[module].test.ts`
- `tests/e2e/[flow].spec.ts`
- Describe: module or feature name
- It: plain English starting with a verb

## Step 4: Run tests

```bash
pnpm test:run          # Vitest unit + integration
pnpm test:e2e          # Playwright E2E (if specs were generated)
```

If tests fail, fix them. Iterate until green. Common issues:
- Integration tests need the DB running (`docker compose up -d`)
- E2E tests need the dev server running (`pnpm dev`)
- Missing env vars in test context

## Step 5: Report

> **Tests generated:**
> - Unit: [N] files, [N] test cases
> - Integration: [N] files, [N] test cases
> - E2E: [N] specs
> All passing.

If the active card (`.devhawk-work.json`) exists, comment on it: "Tests added: [N] unit, [N] integration, [N] E2E."

## What NOT to test

Per docs/testing-patterns.md:
- shadcn/ui component internals
- Next.js framework behavior
- Third-party library correctness
- Every page (E2E is for critical paths only)

## E2E scope guidance

E2E tests are expensive to write and maintain. Generate them only for:
- **Auth flows** — sign up, sign in, password reset (always)
- **Core workflow** — the main thing the product does (always)
- **Payment flows** — if Stripe is integrated (always)
- **Admin actions** — if admin panel exists (first deploy only)

Do NOT generate E2E for: settings pages, profile editing, static content pages, or features that are adequately covered by integration tests on the Server Action.

Document the E2E scope decision in the project's `docs/testing-patterns.md` or `CLAUDE.md` addendum so future test-gen invocations follow the same scope.
