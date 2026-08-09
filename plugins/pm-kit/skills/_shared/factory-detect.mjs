#!/usr/bin/env node
/**
 * Is the repo I am standing in registered with the DevHawk factory?
 *
 * WHY THIS EXISTS. Every ship-kit skill that wants to consult the factory needs
 * the same two facts — the repo's `owner/name` slug, and whether that slug is a
 * registered project — and neither is worth asking a model to derive from
 * `git remote -v` output by hand each time. Deriving it deterministically also
 * means the answer is the SAME on every skill and every run, which is what makes
 * "the factory says this card is ranked 3rd" a claim you can check.
 *
 * REGISTRATION IS THE OPT-IN. There is no `.factory.json` to add and no flag to
 * set: a repo nobody registered resolves to `registered: false` and every
 * factory-aware step in every skill degrades to exactly what it did before the
 * factory existed. That is deliberate — the plugins auto-propagate on merge with
 * no staging ring, so the safe default has to be "does nothing" rather than
 * "does something to a project that never asked".
 *
 * NO NETWORK. This resolves the slug only. Matching it against the registry is
 * the caller's job, because the caller has the factory MCP tools and this does
 * not — a plugin script cannot call an MCP server.
 *
 * Usage:
 *   node factory-detect.mjs            # -> JSON on stdout
 *   node factory-detect.mjs --slug     # -> just the slug, or empty
 */

import { execFileSync } from 'node:child_process';

/**
 * `owner/name` from a git remote URL, or null.
 *
 * Handles the three shapes a real checkout produces — scp-style SSH
 * (`git@github.com:owner/name.git`), ssh:// and https:// — plus Azure DevOps,
 * whose URLs carry `_git` and an extra project segment. A URL this cannot parse
 * returns null rather than a guess: a wrong slug would silently match the wrong
 * project, which is worse than no match at all.
 */
export function slugFromRemote(url) {
  if (!url) return null;
  const trimmed = url.trim().replace(/\.git$/, '');

  // Azure DevOps: https://dev.azure.com/org/project/_git/repo
  const ado = /dev\.azure\.com[/:]([^/]+)\/([^/]+)\/_git\/([^/]+)$/.exec(trimmed);
  if (ado) return `${ado[1]}/${ado[2]}/${ado[3]}`;

  // scp-style SSH: git@host:owner/name
  const scp = /^[^@]+@[^:]+:(.+)$/.exec(trimmed);
  if (scp) {
    const parts = scp[1].split('/').filter(Boolean);
    return parts.length >= 2 ? parts.slice(-2).join('/') : null;
  }

  // ssh:// or https://host/owner/name
  try {
    const u = new URL(trimmed);
    const parts = u.pathname.split('/').filter(Boolean);
    return parts.length >= 2 ? parts.slice(-2).join('/') : null;
  } catch {
    return null;
  }
}

/** The current repo's slug, or null when this is not a git checkout. */
export function detectSlug(cwd = process.cwd()) {
  try {
    const url = execFileSync('git', ['remote', 'get-url', 'origin'], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    return slugFromRemote(url);
  } catch {
    // No git, no origin, or not a repo. All three mean the same thing here.
    return null;
  }
}

/** The current branch, so a caller can tell "on the card's branch" from "not". */
export function detectBranch(cwd = process.cwd()) {
  try {
    return execFileSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], {
      cwd,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return null;
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const slug = detectSlug();
  if (process.argv.includes('--slug')) {
    if (slug) process.stdout.write(slug);
  } else {
    process.stdout.write(
      `${JSON.stringify({ slug, branch: detectBranch(), cwd: process.cwd() }, null, 2)}\n`,
    );
  }
}
