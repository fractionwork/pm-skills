#!/usr/bin/env node
// State + planning helper for the pr-watch skill.
//
// Subcommands:
//   plan     — read `gh pr list` JSON from stdin, emit a per-PR action plan
//   record   — persist outcome + fingerprint for a PR
//   snooze   — suppress notifications for a PR for a duration (e.g. 4h, 2d)
//   show     — print the current state
//   clear    — forget state for one PR (forces re-review next tick)
//   prune    — drop entries for PRs no longer open
//
// State file: .pr-watcher-state.json (gitignored, project-local).

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const STATE_PATH = resolve(process.cwd(), ".pr-watcher-state.json");

function loadState() {
  if (!existsSync(STATE_PATH)) return { version: 1, prs: {} };
  try {
    return JSON.parse(readFileSync(STATE_PATH, "utf8"));
  } catch {
    return { version: 1, prs: {} };
  }
}

function saveState(state) {
  writeFileSync(STATE_PATH, `${JSON.stringify(state, null, 2)}\n`);
}

function fingerprint(pr) {
  const checks = (pr.statusCheckRollup ?? [])
    .map((c) => `${c.name ?? c.context ?? "?"}=${c.conclusion ?? c.status ?? "PENDING"}`)
    .sort()
    .join(",");
  const unresolved =
    pr.reviewThreads?.nodes?.filter?.((t) => !t.isResolved).length ??
    pr.reviewThreads?.filter?.((t) => !t.isResolved).length ??
    0;
  return [
    `sha=${pr.headRefOid}`,
    `decision=${pr.reviewDecision || "NONE"}`,
    `mergeable=${pr.mergeable || "UNKNOWN"}`,
    `checks=${checks || "none"}`,
    `unresolved=${unresolved}`,
  ].join("|");
}

function checksGreen(pr) {
  if (!pr.statusCheckRollup || pr.statusCheckRollup.length === 0) return true;
  return pr.statusCheckRollup.every((c) => {
    const v = c.conclusion ?? c.status;
    return v === "SUCCESS" || v === "NEUTRAL" || v === "SKIPPED" || v === "COMPLETED";
  });
}

function unresolvedThreadCount(pr) {
  return (
    pr.reviewThreads?.nodes?.filter?.((t) => !t.isResolved).length ??
    pr.reviewThreads?.filter?.((t) => !t.isResolved).length ??
    0
  );
}

function readyToMerge(pr) {
  return (
    pr.reviewDecision === "APPROVED" &&
    pr.mergeable === "MERGEABLE" &&
    checksGreen(pr) &&
    unresolvedThreadCount(pr) === 0
  );
}

function isSnoozed(entry) {
  if (!entry?.snoozed_until) return false;
  return new Date(entry.snoozed_until) > new Date();
}

function parseDuration(dur) {
  const m = dur.match(/^(\d+)([mhd])$/);
  if (!m) return null;
  const [, qty, unit] = m;
  const ms = { m: 60_000, h: 3_600_000, d: 86_400_000 }[unit];
  return ms * Number(qty);
}

// How long a PENDING entry (subagent dispatched but no outcome recorded yet)
// is trusted before the planner assumes the subagent crashed and re-dispatches.
// Tuned to cover a slow pr-review (worktree install + 5 activities) without
// stranding a permanently-stuck PR.
export const PENDING_STALE_MS = 60 * 60 * 1000;

// Pure planner — exported so the unit tests can drive it without subprocess.
export function planFor(prs, state, nowMs = Date.now()) {
  const plan = [];
  for (const pr of prs) {
    const entry = state.prs?.[pr.number];
    if (pr.isDraft) {
      plan.push({ number: pr.number, action: "skip", reason: "draft" });
      continue;
    }
    if (isSnoozed(entry)) {
      plan.push({
        number: pr.number,
        action: "skip",
        reason: "snoozed",
        until: entry.snoozed_until,
      });
      continue;
    }
    const fp = fingerprint(pr);

    // PENDING: a subagent is in flight from an earlier tick. Skip while
    // it's fresh; fall through to re-dispatch only if it looks stale
    // (subagent crashed or was interrupted) so a permanently-stuck PR
    // doesn't go unreviewed forever.
    if (entry?.outcome === "PENDING" && entry.fingerprint === fp) {
      const startedMs = Date.parse(entry.last_review_at ?? "");
      const ageMs = Number.isFinite(startedMs) ? nowMs - startedMs : Number.POSITIVE_INFINITY;
      if (ageMs < PENDING_STALE_MS) {
        plan.push({
          number: pr.number,
          action: "skip",
          reason: "pending",
          dispatched_at: entry.last_review_at ?? null,
        });
        continue;
      }
      // else fall through — stale, re-dispatch on this tick
    }

    if (entry && entry.fingerprint === fp && entry.outcome && entry.outcome !== "PENDING") {
      plan.push({
        number: pr.number,
        action: "skip",
        reason: "unchanged",
        prior_outcome: entry.outcome,
      });
      continue;
    }
    if (readyToMerge(pr)) {
      plan.push({
        number: pr.number,
        action: "ready",
        fingerprint: fp,
        title: pr.title,
        url: pr.url ?? null,
        prior_outcome: entry?.outcome ?? null,
      });
      continue;
    }
    plan.push({
      number: pr.number,
      action: "review",
      fingerprint: fp,
      title: pr.title,
      url: pr.url ?? null,
      prior_outcome: entry?.outcome ?? null,
    });
  }
  return plan;
}

// CLI shim — only execute when invoked directly (`node pr-watch-state.mjs ...`),
// not when imported by the unit tests. Avoids the top-level process.exit at
// the bottom of the file firing during import.
const isMain = import.meta.url === `file://${process.argv[1]}`;
const [, , cmd, ...args] = isMain ? process.argv : [];

if (!isMain) {
  // Imported as a module — exports above are all the consumer needs.
} else if (cmd === "plan") {
  const raw = readFileSync(0, "utf8");
  const prs = JSON.parse(raw);
  const state = loadState();
  console.log(JSON.stringify(planFor(prs, state), null, 2));
} else if (cmd === "record") {
  const [number, outcome, fp, notifiedRaw] = args;
  if (!number || !outcome || !fp) {
    console.error("usage: record <number> <outcome> <fingerprint> [notified=true|false]");
    process.exit(2);
  }
  const notified = notifiedRaw !== "false";
  const state = loadState();
  const prior = state.prs[number] ?? {};
  state.prs[number] = {
    fingerprint: fp,
    outcome,
    last_review_at: new Date().toISOString(),
    last_notified_at: notified ? new Date().toISOString() : (prior.last_notified_at ?? null),
    snoozed_until: prior.snoozed_until ?? null,
  };
  saveState(state);
  console.log(`recorded #${number} outcome=${outcome} notified=${notified}`);
} else if (cmd === "snooze") {
  const [number, dur] = args;
  if (!number || !dur) {
    console.error("usage: snooze <number> <duration like 30m, 4h, 2d>");
    process.exit(2);
  }
  const ms = parseDuration(dur);
  if (ms === null) {
    console.error("duration must be like 30m, 4h, or 2d");
    process.exit(2);
  }
  const until = new Date(Date.now() + ms).toISOString();
  const state = loadState();
  state.prs[number] = { ...(state.prs[number] ?? {}), snoozed_until: until };
  saveState(state);
  console.log(`snoozed #${number} until ${until}`);
} else if (cmd === "clear") {
  const [number] = args;
  if (!number) {
    console.error("usage: clear <number>");
    process.exit(2);
  }
  const state = loadState();
  if (state.prs[number]) {
    delete state.prs[number];
    saveState(state);
    console.log(`cleared #${number}`);
  } else {
    console.log(`#${number} not in state`);
  }
} else if (cmd === "show") {
  const state = loadState();
  const entries = Object.entries(state.prs);
  if (entries.length === 0) {
    console.log("(no PR state recorded)");
  } else {
    for (const [n, e] of entries) {
      const snz = isSnoozed(e) ? ` snoozed-until=${e.snoozed_until}` : "";
      const fp = e.fingerprint ? `${e.fingerprint.slice(0, 70)}...` : "(no fp)";
      console.log(`#${n} outcome=${e.outcome ?? "?"} last_review=${e.last_review_at ?? "?"}${snz}`);
      console.log(`     ${fp}`);
    }
  }
} else if (cmd === "prune") {
  const open = new Set((args[0] ?? "").split(",").filter(Boolean));
  const state = loadState();
  let removed = 0;
  for (const n of Object.keys(state.prs)) {
    if (!open.has(n)) {
      delete state.prs[n];
      removed++;
    }
  }
  saveState(state);
  console.log(`pruned ${removed} closed PR(s)`);
} else {
  console.error("usage: pr-watch-state {plan|record|snooze|show|clear|prune}");
  process.exit(2);
}
