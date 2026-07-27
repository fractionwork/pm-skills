#!/usr/bin/env node
// Alignment check: the add-card skill vs asana-conventions.md.
//
// The add-card skill encodes the field-requirements table at creation time,
// and asana-conventions.md encodes the same rules for hygiene audits.
// They MUST stay in sync — drift means a card created via the skill might not
// satisfy what asana-hygiene flags as required (or vice versa).
//
// This script extracts both tables and reports any field whose INBOX or
// BACKLOG requirement differs between them. It's heuristic — there's a fixed
// field map below since the skill rolls four custom fields into one row.
//
// Usage:
//   node <pm-kit>/skills/_shared/check-add-card-alignment.mjs           # human-readable
//   node <pm-kit>/skills/_shared/check-add-card-alignment.mjs --json     # machine output
//   node <pm-kit>/skills/_shared/check-add-card-alignment.mjs --strict   # exit 1 on drift

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

// Both files it compares are siblings inside this plugin, so resolve relative to
// THIS file, not the cwd. It used to read a project's docs/ and .claude/skills/,
// which only worked when run from the seed repo root; as a plugin the cwd is
// wherever the user happens to be.
const SHARED = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(SHARED, '..', '..');
const DOCS_PATH = 'skills/_shared/asana-conventions.md';
const SKILL_PATH = 'skills/add-card/SKILL.md';

// Pair fields by canonical name. Left = docs row title; right = add-card row.
// Multiple docs rows can map to one skill row (the skill collapses the four
// custom fields into a single "Priority / Type / Points / Release" row).
const FIELD_MAP = [
  { docs: 'Title (not vague)', skill: 'Title quality' },
  { docs: 'Description (1-2 sentences)', skill: 'Description (1-2 sentences)' },
  { docs: 'Source attribution', skill: 'Source attribution' },
  // Flat-task model: the epic a card supports is the Feature field, not a parent.
  { docs: 'Feature (epic)', skill: 'Feature identifiable' },
  // Collapsed custom-field row — these docs rows MUST match the single skill
  // row's INBOX/BACKLOG values for INBOX optional / BACKLOG required. The skill
  // rolls Priority / Type / Points / Release / Theme into one row.
  { docs: 'Fraction Priority', skill: 'Priority / Type / Points / Release' },
  { docs: 'Fraction Task Type', skill: 'Priority / Type / Points / Release' },
  { docs: 'Story Points', skill: 'Priority / Type / Points / Release' },
  { docs: 'Release', skill: 'Priority / Type / Points / Release' },
  { docs: 'Theme', skill: 'Priority / Type / Points / Release' },
];

function readFile(path) {
  return readFileSync(resolve(ROOT, path), 'utf8');
}

// Parse the row body up to the next blank line. Returns a map of
// field-name -> { col1, col2, ... } keyed by header columns.
function parseTableAfterHeading(text, headingMatcher) {
  const lines = text.split('\n');
  const startIdx = lines.findIndex((l) => headingMatcher.test(l));
  if (startIdx === -1) return null;

  // Find the header row (first `| ... |` line after the heading).
  let headerIdx = -1;
  for (let i = startIdx + 1; i < lines.length; i++) {
    if (lines[i].trim().startsWith('|')) {
      headerIdx = i;
      break;
    }
    if (/^#{1,6}\s/.test(lines[i])) return null; // next heading first — no table
  }
  if (headerIdx === -1) return null;

  const headers = lines[headerIdx]
    .split('|')
    .map((c) => c.trim())
    .filter((c) => c.length > 0);
  // Skip separator row.
  const rows = {};
  for (let i = headerIdx + 2; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line.startsWith('|')) break;
    const cells = line
      .split('|')
      .slice(1, -1) // drop empty leading/trailing splits
      .map((c) => c.trim());
    if (cells.length < 2) continue;
    const [nameRaw, ...rest] = cells;
    const name = nameRaw.replace(/\*\*/g, '').trim();
    const row = {};
    headers.slice(1).forEach((h, idx) => {
      row[h] = rest[idx] ?? '';
    });
    // Strip markdown emphasis (`**required**` → `required`).
    for (const k of Object.keys(row)) {
      row[k] = row[k].replace(/\*\*/g, '').trim();
    }
    rows[name] = row;
  }
  return { headers, rows };
}

function normalizeRequirement(value) {
  // Strip parenthetical detail ("required (auto-estimated)" → "required") so
  // mismatches focus on the requirement itself, not its explanation. Also
  // collapse synonyms: "none" and "unassigned" both denote "not applicable
  // at this stage" for the purpose of alignment.
  const stripped = value
    .replace(/\([^)]*\)/g, '')
    .trim()
    .toLowerCase();
  if (stripped === 'none' || stripped === 'unassigned' || stripped === 'n/a') {
    return 'n/a';
  }
  return stripped;
}

function checkAlignment() {
  const docsText = readFile(DOCS_PATH);
  const skillText = readFile(SKILL_PATH);

  const docsTable = parseTableAfterHeading(docsText, /^###\s+Section-aware field requirements/i);
  const skillTable = parseTableAfterHeading(skillText, /^##\s+Step 3:\s+Pre-flight validation/i);

  const findings = [];
  if (!docsTable) {
    findings.push({
      kind: 'error',
      message: `Could not find "Section-aware field requirements" table in ${DOCS_PATH}`,
    });
  }
  if (!skillTable) {
    findings.push({
      kind: 'error',
      message: `Could not find "Step 3: Pre-flight validation" table in ${SKILL_PATH}`,
    });
  }
  if (!docsTable || !skillTable) return findings;

  // Resolve the column names in each table — "INBOX" + "BACKLOG" exist in
  // both. The docs table also has a "TODO+" column; add-card only handles
  // INBOX/BACKLOG so we ignore TODO+ here.
  const docsInbox = docsTable.headers.slice(1).find((h) => /^INBOX$/i.test(h));
  const docsBacklog = docsTable.headers.slice(1).find((h) => /^BACKLOG$/i.test(h));
  const skillInbox = skillTable.headers.slice(1).find((h) => /INBOX/i.test(h));
  const skillBacklog = skillTable.headers.slice(1).find((h) => /BACKLOG/i.test(h));

  if (!docsInbox || !docsBacklog || !skillInbox || !skillBacklog) {
    findings.push({
      kind: 'error',
      message: `Could not resolve INBOX/BACKLOG columns. docs headers: ${docsTable.headers.join(', ')}; skill headers: ${skillTable.headers.join(', ')}`,
    });
    return findings;
  }

  // Resolve row names by prefix-match so we tolerate parenthetical suffixes
  // (e.g. skill row "Title quality (not vague, no standalone TBD/TODO/misc)"
  // matches FIELD_MAP entry "Title quality").
  const findRow = (table, prefix) => {
    if (table.rows[prefix]) return [prefix, table.rows[prefix]];
    const key = Object.keys(table.rows).find((k) =>
      k.toLowerCase().startsWith(prefix.toLowerCase()),
    );
    return key ? [key, table.rows[key]] : [null, null];
  };

  // Find each pair from FIELD_MAP and compare.
  for (const { docs, skill } of FIELD_MAP) {
    const [, docsRow] = findRow(docsTable, docs);
    const [, skillRow] = findRow(skillTable, skill);
    if (!docsRow) {
      findings.push({
        kind: 'missing-in-docs',
        field: docs,
        message: `Field "${docs}" not found in docs table — has the row title changed?`,
      });
      continue;
    }
    if (!skillRow) {
      findings.push({
        kind: 'missing-in-skill',
        field: skill,
        message: `Row "${skill}" not found in add-card Step 3 table — has the row title changed?`,
      });
      continue;
    }
    const docsI = normalizeRequirement(docsRow[docsInbox]);
    const docsB = normalizeRequirement(docsRow[docsBacklog]);
    const skillI = normalizeRequirement(skillRow[skillInbox]);
    const skillB = normalizeRequirement(skillRow[skillBacklog]);

    if (docsI !== skillI) {
      findings.push({
        kind: 'inbox-drift',
        field: `${docs} ↔ ${skill}`,
        docs: docsRow[docsInbox],
        skill: skillRow[skillInbox],
        message: `INBOX requirement drift: docs says "${docsRow[docsInbox]}", add-card says "${skillRow[skillInbox]}"`,
      });
    }
    if (docsB !== skillB) {
      findings.push({
        kind: 'backlog-drift',
        field: `${docs} ↔ ${skill}`,
        docs: docsRow[docsBacklog],
        skill: skillRow[skillBacklog],
        message: `BACKLOG requirement drift: docs says "${docsRow[docsBacklog]}", add-card says "${skillRow[skillBacklog]}"`,
      });
    }
  }

  return findings;
}

function main() {
  const args = process.argv.slice(2);
  const jsonOut = args.includes('--json');
  const strict = args.includes('--strict');

  const findings = checkAlignment();

  if (jsonOut) {
    process.stdout.write(`${JSON.stringify(findings, null, 2)}\n`);
  } else if (findings.length === 0) {
    console.log('✓ add-card SKILL.md aligned with asana-conventions.md');
  } else {
    console.log(`✗ ${findings.length} alignment finding(s):`);
    for (const f of findings) {
      console.log(`  · [${f.kind}] ${f.message}`);
    }
  }

  if (strict && findings.length > 0) process.exit(1);
}

// CLI/library duality — only run when invoked directly, not when imported by
// scripts/pr-audit.mjs's loader (which sweeps every .mjs in this directory).
const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) main();

export { checkAlignment };
