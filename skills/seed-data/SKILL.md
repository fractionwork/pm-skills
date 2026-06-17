---
name: seed-data
profiles: [engineer]
description: >
  Generate realistic seed data for local development and testing. Creates a
  TypeScript seed script that populates the database with contextually
  appropriate test data based on the project's domain, schema, and business
  rules. Triggers on phrases like "seed data", "test data", "sample data",
  "populate the database", "create fake data", "generate seed", "I need
  data to test with", or any request for realistic development data.
requires_tools: [pnpm, node]
---

# Seed Data Generator

You are generating realistic test data for a DevHawk project. The goal is a single script at `lib/db/seed.ts` that populates the database with data that looks and feels real — not `test1@example.com` and `Lorem ipsum`.

## Before generating

1. Read the full schema in `lib/db/schema/` to understand every table, column, relationship, and constraint
2. Read `CLAUDE.md` for domain concepts and business rules
3. Check if `lib/db/seed.ts` already exists — if so, update it rather than replacing it
4. Understand the auth setup. Read the `**Auth variant:**` line in `CLAUDE.md` — `org` (organization plugin, multi-tenant) or `solo` (admin plugin, no orgs). Also peek at `lib/auth.ts` for the active plugin list (e.g. twoFactor, passkey).

## Seed script structure

Create `lib/db/seed.ts`:

```typescript
import { db } from "@/lib/db";
import { user, session, account, organization, member, ... } from "@/lib/db/schema";

async function seed() {
  console.log("🌱 Seeding database...");

  // 1. Clean existing data (reverse dependency order)
  // 2. Create organizations (if multi-tenant)
  // 3. Create users with accounts (password hash for email/password auth)
  // 4. Create org memberships (if multi-tenant)
  // 5. Create domain-specific data
  // 6. Create realistic relationships between entities

  console.log("✅ Seed complete");
  process.exit(0);
}

seed().catch((err) => {
  console.error("❌ Seed failed:", err);
  process.exit(1);
});
```

## Data realism rules

### Users
- Use realistic full names that reflect diverse backgrounds (not "Test User 1")
- Use email addresses at realistic domains (not `@example.com` for every user) — mix of company domains, gmail, etc.
- For Better Auth email/password accounts, use the `account` table with `providerId: "credential"` and a bcrypt-hashed password. Use a shared test password like `"Password123!"` and document it in the seed output
- Create 3-5 users per organization with varied roles (owner, admin, member)

### Organizations (if multi-tenant)
- Use realistic company/team names relevant to the project domain
- Each org should have different amounts of data to test pagination, empty states, and edge cases
- One org should be "full" (lots of data), one "starter" (minimal), one "empty" (just the owner)

### Domain data
- Base quantities, names, descriptions, and values on what makes sense for the domain
- Use realistic prices (not $1.00 or $999.99), dates (spread across recent months, not all today), statuses (mix of active/completed/pending)
- Include edge cases: items with long names, empty optional fields, boundary values
- Create enough data to fill a paginated list (20-50 items for the primary entity)
- Relationships should be realistic — not every user creates equal amounts of data

### Timestamps
- Spread `createdAt` across the last 90 days, not all `new Date()`
- Use `updatedAt` that's the same as or later than `createdAt`
- Some items should be recently created (today/yesterday), some older

### IDs
- Use `crypto.randomUUID()` for generating IDs (matches Better Auth's default ID generation)

## Password hashing

Better Auth uses bcrypt for credential accounts. To create seeded users that can actually sign in:

```typescript
import { createHash } from "crypto";

// Better Auth stores passwords as bcrypt hashes in the account table.
// Use the better-auth hash utility or bcrypt directly:
import { hash } from "better-auth/crypto";

const TEST_PASSWORD = "Password123!";
const hashedPassword = await hash.password(TEST_PASSWORD);

// Create account entry for each user:
await db.insert(account).values({
  id: crypto.randomUUID(),
  userId: userId,
  accountId: userId,
  providerId: "credential",
  password: hashedPassword,
  createdAt: new Date(),
  updatedAt: new Date(),
});
```

If `better-auth/crypto` is not available, fall back to bcrypt:
```typescript
import bcrypt from "bcryptjs";
const hashedPassword = await bcrypt.hash(TEST_PASSWORD, 10);
```

## The pnpm db:seed script

The script should be runnable via `pnpm db:seed`. Add it to package.json:
```json
"db:seed": "tsx lib/db/seed.ts"
```

## Variant-specific considerations

### Org variant (`**Auth variant:** org`)

- Create 3 organizations with different profiles
- Assign users to specific orgs with appropriate roles via the `member` table
- ALL domain data must be scoped to an organization (carry `organizationId`)
- The seed output should show which org to use for testing: "Sign in as jane@acme.co (Password123!) — Acme Corp (owner, full data)"

### Solo variant (`**Auth variant:** solo`)

- No `organization` / `member` / `invitation` tables — skip steps 2 and 4 in the seed-script structure above
- Create 5-10 users across `role: "user"` and `role: "admin"` (one or two admins)
- Domain data carries no `organizationId` — it's all global
- The seed output should mark which user is admin for testing: "Sign in as jane@example.com (Password123!) — admin"

## Output

The seed script should print a summary when done:

```
🌱 Seeding database...

Organizations:
  Acme Corp (org_xxx) — 3 members, 45 products, 120 orders
  Startup Inc (org_yyy) — 2 members, 5 products, 3 orders
  Empty Co (org_zzz) — 1 member (owner only)

Test accounts (password: Password123!):
  jane@acme.co — Acme Corp owner
  bob@acme.co — Acme Corp admin
  alice@startup.io — Startup Inc owner

✅ Seed complete
```

## Idempotency

The seed script should be safe to run multiple times:
- Delete all existing data before inserting (in reverse dependency order to respect foreign keys)
- Use `db.delete(tableName)` for each table
- Never use `TRUNCATE CASCADE` — explicit deletes are safer and more portable

## After generating the script

Once `lib/db/seed.ts` is written:

1. Verify it compiles: `pnpm typecheck`
2. Run it: `pnpm db:seed`
3. If it fails, fix the script and re-run — do not ask the user to run it manually
4. Show the user the summary output (test accounts and data counts)

Always run the seed script for the user. The whole point is to get data into the database so they can start testing immediately.

## What NOT to do

- Don't generate hundreds of rows for every table — enough to be useful, not so much it's slow
- Don't use sequential data (`item-1`, `item-2`, `item-3`) — use varied, realistic names
- Don't hardcode UUIDs — generate them at runtime
- Don't skip optional fields on every record — populate them on some records to test display
- Don't create data that violates business rules documented in CLAUDE.md
- Don't just generate the file and stop — run `pnpm db:seed` to actually populate the database
