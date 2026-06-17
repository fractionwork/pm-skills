#!/usr/bin/env node
// Once-per-session sanity check for devhawk-seed skill dependencies.
//
// Walks `.claude/skills/*/SKILL.md` and `.claude/agents/*.md`, parses each
// frontmatter for `requires_*:` declarations, and verifies every dependency
// is satisfied: CLI tool present, file exists, env var set, MCP server
// declared in .mcp.json, plugin enabled, permission allow-listed.
//
// Output discipline: silent when everything's clean. Loud when something's
// missing, with one-line "how to fix" hints per category.
//
// Modes:
//   (default)            — print report, exit 0 always
//   --strict             — print report, exit 1 if any check fails (CI mode)
//   --on-session-start   — same as default, but writes a marker file and
//                          short-circuits subsequent runs in the same hour.
//                          Designed for the SessionStart hook.
//   --json               — emit JSON instead of human-readable output
//
// The check is read-only. It never modifies settings.json, never installs
// tools, never prompts. It tells you what's missing and how to fix it.

import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, readdirSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";

const ROOT = process.cwd();
const ARGV = process.argv.slice(2);
const ARGS = new Set(ARGV);
const STRICT = ARGS.has("--strict");
const ON_SESSION_START = ARGS.has("--on-session-start");
const JSON_OUT = ARGS.has("--json");

// --skills-dir <path> lets the user-level SessionStart hook (registered by the
// installer) point the walk at ~/.claude/skills, while file/MCP/plugin probes
// still run against the current project (ROOT) + user-scope MCP. Default: the
// project's own .claude/skills + .claude/agents.
function argValue(flag) {
  const i = ARGV.indexOf(flag);
  return i >= 0 && ARGV[i + 1] ? ARGV[i + 1] : null;
}
const SKILLS_DIR_OVERRIDE = argValue("--skills-dir");
const SKILLS_BASE = SKILLS_DIR_OVERRIDE
  ? resolve(SKILLS_DIR_OVERRIDE)
  : join(ROOT, ".claude/skills");
const AGENTS_BASE = SKILLS_DIR_OVERRIDE
  ? join(dirname(resolve(SKILLS_DIR_OVERRIDE)), "agents")
  : join(ROOT, ".claude/agents");

// ─── Once-per-hour gate for SessionStart use ──────────────────────────────
if (ON_SESSION_START) {
  const repoHash = createHash("sha1").update(ROOT).digest("hex").slice(0, 12);
  const marker = join(tmpdir(), `devhawk-seed-deps-${repoHash}.ok`);
  if (existsSync(marker)) {
    const ageMs = Date.now() - statSync(marker).mtimeMs;
    if (ageMs < 60 * 60 * 1000) process.exit(0);
  }
  // Continue; if the run is clean, we'll write the marker at the end.
  process.on("exit", (code) => {
    if (code === 0) {
      try {
        writeFileSync(marker, `${new Date().toISOString()}\n`);
      } catch {
        /* ignore */
      }
    }
  });
}

// ─── Minimal frontmatter parser ───────────────────────────────────────────
// Handles: scalars (`key: value`), inline arrays (`key: [a, b]`), block
// arrays (`key:\n  - a\n  - b`). Quotes (single or double) are stripped
// from values. Multi-line scalar blocks (`>`, `|`) are read literally up
// to the next un-indented key.

function parseFrontmatter(text) {
  const m = text.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return {};
  const body = m[1];
  const lines = body.split("\n");
  const out = {};
  let i = 0;
  const stripQuotes = (s) => s.replace(/^["']|["']$/g, "");
  while (i < lines.length) {
    const line = lines[i];
    if (!line.trim() || line.trim().startsWith("#")) {
      i++;
      continue;
    }
    const keyMatch = line.match(/^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$/);
    if (!keyMatch) {
      i++;
      continue;
    }
    const key = keyMatch[1];
    const rest = keyMatch[2];
    if (rest === "" || rest === ">" || rest === "|") {
      // Block scalar or block array — peek at next non-empty line
      let j = i + 1;
      while (j < lines.length && !lines[j].trim()) j++;
      if (j < lines.length && /^\s+-\s/.test(lines[j])) {
        // Block array
        const items = [];
        while (j < lines.length && /^\s+-\s/.test(lines[j])) {
          items.push(stripQuotes(lines[j].replace(/^\s+-\s*/, "").trim()));
          j++;
        }
        out[key] = items;
        i = j;
        continue;
      }
      // Block scalar — consume indented lines as a single string
      const buf = [];
      while (j < lines.length && (lines[j].startsWith(" ") || !lines[j].trim())) {
        buf.push(lines[j].trim());
        j++;
      }
      out[key] = buf.join(" ").trim();
      i = j;
      continue;
    }
    // Inline value
    const trimmed = rest.trim();
    if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
      out[key] = trimmed
        .slice(1, -1)
        .split(",")
        .map((s) => stripQuotes(s.trim()))
        .filter(Boolean);
    } else {
      out[key] = stripQuotes(trimmed);
    }
    i++;
  }
  return out;
}

// ─── Discovery ────────────────────────────────────────────────────────────

function walkSkills() {
  const skillsDir = SKILLS_BASE;
  const agentsDir = AGENTS_BASE;
  const items = [];
  if (existsSync(skillsDir)) {
    for (const entry of readdirSync(skillsDir)) {
      const p = join(skillsDir, entry, "SKILL.md");
      if (existsSync(p)) items.push({ kind: "skill", name: entry, path: p });
    }
  }
  if (existsSync(agentsDir)) {
    for (const entry of readdirSync(agentsDir)) {
      if (!entry.endsWith(".md")) continue;
      items.push({
        kind: "agent",
        name: entry.replace(/\.md$/, ""),
        path: join(agentsDir, entry),
      });
    }
  }
  return items;
}

// ─── Environment probes ───────────────────────────────────────────────────
// Each probe is small + cached so check time stays under a second.

const cache = new Map();
function memo(key, fn) {
  if (cache.has(key)) return cache.get(key);
  const v = fn();
  cache.set(key, v);
  return v;
}

function hasTool(name) {
  return memo(`tool:${name}`, () => {
    try {
      execSync(`command -v ${name}`, { stdio: "ignore" });
      return true;
    } catch {
      return false;
    }
  });
}

function hasFile(relPath) {
  return existsSync(join(ROOT, relPath));
}

function hasSkill(name) {
  return existsSync(join(SKILLS_BASE, name, "SKILL.md"));
}

function hasSubagent(name) {
  return existsSync(join(AGENTS_BASE, `${name}.md`));
}

function readJsonSafe(relPath) {
  return memo(`json:${relPath}`, () => {
    try {
      return JSON.parse(readFileSync(join(ROOT, relPath), "utf8"));
    } catch {
      return null;
    }
  });
}

function hasPlugin(pluginId) {
  // Plugin requirement format: "plugin-name:skill-name" (e.g. "code-review:code-review").
  // settings.json enabledPlugins keys are "plugin-name@source" (e.g.
  // "code-review@claude-plugins-official"). Match on the plugin-name prefix
  // of each side.
  const settings = readJsonSafe(".claude/settings.json");
  if (!settings) return false;
  const enabled = settings.enabledPlugins ?? settings.plugins ?? {};
  const wantName = pluginId.split(":")[0];
  const matches = (k) => k === pluginId || k.split("@")[0] === wantName;
  if (Array.isArray(enabled)) return enabled.some(matches);
  if (typeof enabled === "object") {
    return Object.keys(enabled).some(matches);
  }
  return false;
}

function hasMcp(serverName) {
  // Project scope: declared in .mcp.json.
  const mcp = readJsonSafe(".mcp.json");
  if (mcp?.mcpServers && Object.keys(mcp.mcpServers).includes(serverName)) return true;
  // User scope: servers registered via `claude mcp add --scope user` (e.g. the
  // installer wires asana/shortcut/linear there). This removes the old
  // "accept the noise" false-positives. If `claude` isn't on PATH, fall back
  // to the .mcp.json-only answer above.
  return memo(`mcp-cli:${serverName}`, () => {
    try {
      const out = execSync("claude mcp list", {
        stdio: ["ignore", "pipe", "ignore"],
        encoding: "utf8",
        timeout: 5000,
      });
      // Lines look like "asana: python ... - ✓ Connected" or "asana   <url>".
      return new RegExp(`(^|\\n)\\s*${serverName}[\\s:]`, "m").test(out);
    } catch {
      return false;
    }
  });
}

function hasEnv(name) {
  return Boolean(process.env[name]);
}

function hasPermission(pattern) {
  const settings = readJsonSafe(".claude/settings.json");
  if (!settings) return false;
  const allow = settings.permissions?.allow ?? [];
  return allow.includes(pattern);
}

// ─── Fix hints ────────────────────────────────────────────────────────────

const FIX_HINTS = {
  // Tools — best-known install commands
  gh: "macOS: brew install gh · Linux: see https://cli.github.com/",
  jq: "macOS: brew install jq · Debian/Ubuntu: apt install jq",
  doctl: "macOS: brew install doctl · then: doctl auth init",
  trivy: "macOS: brew install aquasecurity/trivy/trivy",
  pnpm: "corepack enable && corepack prepare pnpm@latest --activate",
  node: "use mise/nvm/asdf or install from https://nodejs.org",
  python: "macOS: brew install python · Debian/Ubuntu: apt install python3",
  python3: "macOS: brew install python · Debian/Ubuntu: apt install python3",
  docker: "https://www.docker.com/products/docker-desktop/",
  psql: "macOS: brew install libpq · or use the Postgres app",
  yq: "macOS: brew install yq · Linux: see https://github.com/mikefarah/yq",
  playwright: "pnpm dlx playwright install (or via @playwright/mcp)",
};

function toolHint(name) {
  return FIX_HINTS[name] ?? `install \`${name}\` and ensure it's on PATH`;
}

// ─── Checks ───────────────────────────────────────────────────────────────

function checkOne(item) {
  const text = readFileSync(item.path, "utf8");
  const fm = parseFrontmatter(text);
  const findings = [];

  const arr = (k) => (Array.isArray(fm[k]) ? fm[k] : []);

  for (const tool of arr("requires_tools")) {
    if (!hasTool(tool)) {
      findings.push({
        category: "tool",
        missing: tool,
        fix: toolHint(tool),
      });
    }
  }
  for (const file of arr("requires_files")) {
    if (!hasFile(file)) {
      findings.push({
        category: "file",
        missing: file,
        fix: "expected file is missing — run `bash scripts/sync-skills.sh` or check git status",
      });
    }
  }
  for (const skill of arr("requires_skills")) {
    if (!hasSkill(skill)) {
      findings.push({
        category: "skill",
        missing: skill,
        fix: `expected sibling skill \`.claude/skills/${skill}/SKILL.md\` is missing`,
      });
    }
  }
  for (const agent of arr("requires_subagents")) {
    if (!hasSubagent(agent)) {
      findings.push({
        category: "subagent",
        missing: agent,
        fix: `expected subagent \`.claude/agents/${agent}.md\` is missing`,
      });
    }
  }
  for (const plugin of arr("requires_plugins")) {
    if (!hasPlugin(plugin)) {
      findings.push({
        category: "plugin",
        missing: plugin,
        fix: "enable in .claude/settings.json enabledPlugins, or restart Claude Code",
      });
    }
  }
  for (const mcp of arr("requires_mcp")) {
    if (!hasMcp(mcp)) {
      findings.push({
        category: "mcp",
        missing: mcp,
        fix: "register at user scope (re-run the installer for asana/shortcut/linear) or declare in .mcp.json, then restart Claude Code",
      });
    }
  }
  const anyOf = arr("requires_mcp_any_of");
  if (anyOf.length > 0 && !anyOf.some(hasMcp)) {
    findings.push({
      category: "mcp_any_of",
      missing: anyOf.join(" | "),
      fix: "register at least one at user scope (installer) or in .mcp.json",
    });
  }
  for (const env of arr("requires_env")) {
    if (!hasEnv(env)) {
      findings.push({
        category: "env",
        missing: env,
        fix: `set ${env}=… in .env.local (local) or DO console (prod)`,
      });
    }
  }
  for (const perm of arr("requires_permissions")) {
    if (!hasPermission(perm)) {
      findings.push({
        category: "permission",
        missing: perm,
        fix: "add to .claude/settings.json permissions.allow",
      });
    }
  }

  return { item, findings };
}

// ─── Reporting ────────────────────────────────────────────────────────────

function emitHuman(results) {
  const bad = results.filter((r) => r.findings.length > 0);
  const clean = results.filter((r) => r.findings.length === 0);

  if (bad.length === 0) {
    // Silent by default; one-line summary only if --strict (operator asked)
    if (STRICT) {
      console.log(`✓ ${results.length} skills/agents — all dependencies satisfied`);
    }
    return;
  }

  const total = bad.reduce((n, r) => n + r.findings.length, 0);
  console.log(
    `\n⚠ devhawk-seed skill dependency check — ${total} issue(s) across ${bad.length} skill(s):`,
  );
  for (const r of bad) {
    console.log(`\n  ${r.item.kind}: ${r.item.name}`);
    for (const f of r.findings) {
      console.log(`    ✗ ${f.category}: ${f.missing}`);
      console.log(`      Fix: ${f.fix}`);
    }
  }
  if (clean.length > 0) {
    const sample = clean
      .slice(0, 6)
      .map((r) => r.item.name)
      .join(", ");
    const suffix = clean.length > 6 ? `, +${clean.length - 6} more` : "";
    console.log(`\n  (${clean.length} other(s) checked clean — ${sample}${suffix})`);
  }
  console.log("");
}

function emitJson(results) {
  console.log(
    JSON.stringify(
      {
        checked: results.length,
        issues: results
          .filter((r) => r.findings.length > 0)
          .map((r) => ({ kind: r.item.kind, name: r.item.name, findings: r.findings })),
      },
      null,
      2,
    ),
  );
}

// ─── Main ─────────────────────────────────────────────────────────────────

const items = walkSkills();
const results = items.map(checkOne);
const failed = results.some((r) => r.findings.length > 0);

if (JSON_OUT) emitJson(results);
else emitHuman(results);

if (STRICT && failed) process.exit(1);
process.exit(0);
