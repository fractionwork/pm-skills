#!/usr/bin/env node
// pm-python.mjs — run pm-kit's Python, on every platform.
//
//   node pm-python.mjs asana_mcp.py            # the MCP server (.mcp.json)
//   node pm-python.mjs asana_ops.py --hygiene  # a skill's Asana call
//   node pm-python.mjs -c "print(1)"           # any python arguments
//   node pm-python.mjs --which [asana_mcp.py]  # say which interpreter, run nothing
//
// A bare script name resolves next to this file, so skills can say
// `pm-python.mjs asana_ops.py` without spelling the plugin path twice.
//
// WHY NODE. This replaced pm-python.sh, which could not run on native Windows at
// all: `.mcp.json` declares the server as a command plus arguments, which Claude
// Code spawns directly with no shell, and Windows cannot execute a `.sh` as a
// process — the server died before its handshake, and a stdio server that does
// that registers nothing, so the Asana tools were silently absent. Confirmed on
// a Windows runner: `claude mcp list` reported `pm-python.sh … Connection closed`.
// `node` is a real executable on every OS and every kit already requires it;
// Anthropic's own guidance for Windows hooks is exactly this node-plus-script
// shape.
//
// It also fixes something on EVERY platform: skills used to run bare `python3`,
// which is whatever is first on PATH — not the venv /pm-setup built with the
// dependencies in it.
//
// Resolution, first hit wins:
//   1. $DEVHAWK_PM_PYTHON — explicit override, used as given
//   2. the venv /pm-setup creates (bin/python, or Scripts\python.exe on Windows)
//   3. a python on PATH that can already import what the script needs
//      (py -3, python, python3 on Windows; python3, python elsewhere)
// Failing all three: the one-line fix on stderr, exit 1.

import { spawn, spawnSync } from 'node:child_process';
import { existsSync, realpathSync } from 'node:fs';
import { homedir } from 'node:os';
import { dirname, isAbsolute, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));

/**
 * What a system python must be able to import before it is trusted with a
 * script. Probing a server CLASS, not just `import mcp`: that succeeds on every
 * version ever published, including one with no class this can drive, and the
 * failure then happens inside the handshake where nothing reports it. 1.x has
 * mcp.server.fastmcp.FastMCP, 2.x has mcp.server.MCPServer; both are accepted.
 */
export const PROBES = {
  none: 'import sys',
  requests: 'import requests',
  mcp: 'import requests, mcp.server\nhasattr(mcp.server, "MCPServer") or __import__("mcp.server.fastmcp")',
};

/** Which probe a given invocation needs. */
export function requirementFor(argv) {
  const first = argv[0] ?? '';
  if (/(^|[\\/])asana_mcp\.py$/.test(first)) return 'mcp';
  if (/\.py$/.test(first)) return 'requests';
  // Inline code that imports the kit's own modules needs their dependencies —
  // asana-bootstrap's snippets do `from asana_ops import api`.
  if (first === '-c') {
    const code = argv[1] ?? '';
    if (/\basana_mcp\b/.test(code)) return 'mcp';
    if (/\basana_ops\b/.test(code)) return 'requests';
  }
  return 'none';
}

export function pmHome(env = process.env, home = homedir()) {
  return env.DEVHAWK_PM_HOME ? resolve(env.DEVHAWK_PM_HOME) : join(home, '.devhawk', 'pm');
}

/** Where a venv puts its interpreter. The layout differs on Windows, and
 *  pm-setup once looked only for bin/python there — building a venv it could
 *  then never find. */
export function venvPython(pmHomeDir, platform = process.platform) {
  return platform === 'win32'
    ? join(pmHomeDir, 'venv', 'Scripts', 'python.exe')
    : join(pmHomeDir, 'venv', 'bin', 'python');
}

/** System interpreters to try, in order. `py -3` first on Windows: it is the
 *  python.org launcher, and `python3.exe` there is usually only the Microsoft
 *  Store stub, which fails the probe rather than running anything. */
export function systemCandidates(platform = process.platform) {
  return platform === 'win32'
    ? [
        { cmd: 'py', args: ['-3'] },
        { cmd: 'python', args: [] },
        { cmd: 'python3', args: [] },
      ]
    : [
        { cmd: 'python3', args: [] },
        { cmd: 'python', args: [] },
      ];
}

function defaultProbe(candidate, code) {
  const r = spawnSync(candidate.cmd, [...candidate.args, '-c', code], {
    stdio: 'ignore',
    timeout: 20_000,
    windowsHide: true,
  });
  return r.status === 0;
}

/**
 * Choose an interpreter. PURE given its injected `exists` and `probe`, so every
 * branch is testable on every OS without fake executables — which Windows
 * cannot run anyway.
 */
export function resolveInterpreter({
  requirement = 'none',
  env = process.env,
  platform = process.platform,
  home = homedir(),
  exists = existsSync,
  probe = defaultProbe,
} = {}) {
  if (env.DEVHAWK_PM_PYTHON) {
    if (!exists(env.DEVHAWK_PM_PYTHON)) {
      return {
        error: `DEVHAWK_PM_PYTHON is set but does not exist: ${env.DEVHAWK_PM_PYTHON}`,
      };
    }
    return { cmd: env.DEVHAWK_PM_PYTHON, args: [], source: 'DEVHAWK_PM_PYTHON' };
  }

  const venv = venvPython(pmHome(env, home), platform);
  if (exists(venv)) return { cmd: venv, args: [], source: 'venv' };

  let anyPython = false;
  let mcpPackageOnly = false;
  for (const c of systemCandidates(platform)) {
    if (!probe(c, PROBES.none)) continue; // absent, or a Store stub
    anyPython = true;
    if (probe(c, PROBES[requirement])) return { cmd: c.cmd, args: c.args, source: 'system' };
    if (requirement === 'mcp' && probe(c, 'import mcp')) mcpPackageOnly = true;
  }

  if (!anyPython) return { error: 'no Python found (the Asana tools need Python >= 3.10)' };
  if (mcpPackageOnly) {
    return {
      error:
        "the installed 'mcp' package exposes no usable server class (need 1.x FastMCP or 2.x MCPServer)",
    };
  }
  return {
    error:
      requirement === 'mcp'
        ? "Python found, but the 'mcp' and 'requests' packages are missing"
        : "Python found, but the 'requests' package is missing",
  };
}

/** A bare `*.py` resolves next to this file; anything else passes through. */
export function pythonArgs(argv, here = HERE) {
  const [first, ...rest] = argv;
  if (first && /\.py$/.test(first) && !isAbsolute(first) && !/[\\/]/.test(first)) {
    return [join(here, first), ...rest];
  }
  return argv;
}

/**
 * The child's environment. UTF-8 mode, because Python on Windows otherwise
 * decodes files and writes stdout as cp1252: reading its own UTF-8 source
 * failed, and an em dash or bullet in Asana output reached Claude as U+FFFD.
 */
export function childEnv(env = process.env) {
  return { ...env, PYTHONUTF8: '1', PYTHONIOENCODING: 'utf-8' };
}

function fail(message) {
  process.stderr.write(`pm-kit: ${message}\n`);
  process.stderr.write('pm-kit: run /pm-setup in Claude Code to install the Asana runtime.\n');
  return 1;
}

export async function main(argv = process.argv.slice(2)) {
  if (argv[0] === '--which') {
    const r = resolveInterpreter({ requirement: requirementFor(argv.slice(1)) });
    if (r.error) return fail(r.error);
    process.stdout.write(`${[r.cmd, ...r.args].join(' ')}\t(${r.source})\n`);
    return 0;
  }
  if (argv.length === 0) {
    process.stderr.write('usage: node pm-python.mjs <script.py | -c code | -m module> [args...]\n');
    return 2;
  }

  const r = resolveInterpreter({ requirement: requirementFor(argv) });
  if (r.error) return fail(r.error);

  // stdio inherited: for the MCP server this IS the protocol channel, so
  // nothing may be buffered or rewritten in between.
  const child = spawn(r.cmd, [...r.args, ...pythonArgs(argv)], {
    stdio: 'inherit',
    env: childEnv(),
    windowsHide: true,
  });
  // Windows does not take a process's children down with it, so a Claude Code
  // that stops the server would otherwise leave Python running.
  for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(sig, () => child.kill(sig));
  }
  return await new Promise((done) => {
    child.on('error', (e) => done(fail(`could not start ${r.cmd}: ${e.message}`)));
    child.on('exit', (code, signal) => done(code ?? (signal ? 1 : 0)));
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  main().then((code) => process.exit(code));
}
