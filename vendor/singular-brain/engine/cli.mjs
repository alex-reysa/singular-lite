#!/usr/bin/env node
// cli.mjs — singular-brain: generated routing manifests over durable
// knowledge artifacts.
//
// Usage:
//   singular-brain gen    [--scope <name>]...        regenerate manifests
//   singular-brain check  [--scope <name>]...        exit 1 if any output is stale
//   singular-brain bless  (--all | <path>...) [--scope <name>]
//                                                    re-verify drifted bodies, regen
//   singular-brain lint   [--scope <name>]...        frontmatter schema lint
//   singular-brain print-config                      dump resolved config
//   singular-brain --version
//
// Config: --config <path>, else nearest singular-brain.config.json upward
// from cwd. Exit codes: 0 ok · 1 stale or lint errors · 2 config/parse/
// unmapped errors.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { loadConfig, ConfigError, CONFIG_FILENAME } from "./config.mjs";
import { buildScope, UnmappedError } from "./pipeline.mjs";
import { byteCompare, lintEntries } from "./gates.mjs";
import { DESCRIPTION_UNVERIFIED } from "./freshness.mjs";

const TOOL = "singular-brain";

function findConfig(startDir) {
  let dir = resolve(startDir);
  for (;;) {
    const candidate = join(dir, CONFIG_FILENAME);
    if (existsSync(candidate)) return candidate;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

function parseArgs(argv) {
  const args = { command: null, config: null, scopes: [], paths: [], all: false, version: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--config") args.config = argv[(i += 1)];
    else if (a === "--scope") args.scopes.push(argv[(i += 1)]);
    else if (a === "--all") args.all = true;
    else if (a === "--version") args.version = true;
    else if (a.startsWith("--")) throw new ConfigError(`unknown flag ${a}`);
    else if (!args.command) args.command = a;
    else args.paths.push(a);
  }
  return args;
}

function selectScopes(config, names) {
  if (names.length === 0) return config.scopes;
  return names.map((n) => {
    const scope = config.scopes.find((s) => s.name === n);
    if (!scope) {
      throw new ConfigError(
        `unknown scope ${JSON.stringify(n)}; configured: ${config.scopes.map((s) => s.name).join(", ")}`
      );
    }
    return scope;
  });
}

function reportTokens(scope, result) {
  process.stderr.write(`${TOOL}: ~${result.tokens} tokens (${scope.name})\n`);
  if (result.tokens > scope.tokenWarnThreshold) {
    process.stderr.write(
      `${TOOL}: WARNING — ${scope.outputRel} exceeds ${scope.tokenWarnThreshold} tokens; consider demoting entries to compact form or splitting the scope\n`
    );
  }
}

function writeOutputs(scope, result) {
  const files = [[scope.output, scope.outputRel, result.rendered]];
  if (scope.jsonOutput) files.push([scope.jsonOutput, scope.jsonOutputRel, result.renderedJson]);
  if (result.sidecarText !== null) {
    files.push([scope.freshness.sidecar, scope.freshness.sidecarRel, result.sidecarText]);
  }
  for (const [abs, rel, text] of files) {
    mkdirSync(dirname(abs), { recursive: true });
    writeFileSync(abs, text);
    process.stderr.write(`${TOOL}: wrote ${rel}\n`);
  }
}

function checkOutputs(scope, result) {
  const targets = [[scope.output, scope.outputRel, result.rendered]];
  if (scope.jsonOutput) targets.push([scope.jsonOutput, scope.jsonOutputRel, result.renderedJson]);
  if (result.sidecarText !== null) {
    targets.push([scope.freshness.sidecar, scope.freshness.sidecarRel, result.sidecarText]);
  }
  let stale = 0;
  for (const [abs, rel, expected] of targets) {
    // Raw bytes, no normalize: check must agree with gen byte-for-byte, so a
    // CRLF-mangled manifest that gen would rewrite reads as stale here too.
    const current = existsSync(abs) ? readFileSync(abs, "utf8") : null;
    const cmp = byteCompare(current, expected);
    if (!cmp.ok) {
      const hint = scope.staleHint ?? `${TOOL} gen --scope ${scope.name}`;
      process.stderr.write(`${rel} is stale (first diff at line ${cmp.firstDiffLine}); run: ${hint}\n`);
      stale += 1;
    }
  }
  return stale;
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (err) {
    process.stderr.write(`${TOOL}: ${err.message}\n`);
    process.exit(2);
  }

  if (args.version) {
    const engineDir = dirname(fileURLToPath(import.meta.url));
    const read = (name) => {
      const p = resolve(engineDir, "..", name);
      return existsSync(p) ? readFileSync(p, "utf8").trim() : "unknown (vendored)";
    };
    process.stdout.write(`${TOOL} ${read("VERSION")} (config schema ${read("SCHEMA_VERSION")})\n`);
    process.exit(0);
  }

  const commands = ["gen", "check", "bless", "lint", "print-config"];
  if (!args.command || !commands.includes(args.command)) {
    process.stderr.write(`${TOOL}: usage: ${TOOL} <${commands.join("|")}> [--scope <name>] [--config <path>]\n`);
    process.exit(2);
  }

  let exitCode = 0;
  try {
    const configPath = args.config ?? findConfig(process.cwd());
    if (!configPath) {
      throw new ConfigError(`no ${CONFIG_FILENAME} found from ${process.cwd()} upward; pass --config`);
    }
    const config = loadConfig(configPath);
    const scopes = selectScopes(config, args.scopes);

    if (args.command === "print-config") {
      process.stdout.write(
        `${JSON.stringify(config, (k, v) => (v instanceof RegExp ? v.source : v), 2)}\n`
      );
      process.exit(0);
    }

    if (args.command === "bless") {
      const blessScopes = scopes.filter((s) => s.freshness.enabled);
      if (blessScopes.length === 0) {
        throw new ConfigError("bless: no selected scope has freshness enabled");
      }
      if (!args.all && args.paths.length === 0) {
        throw new ConfigError("bless: pass --all or one or more entry paths");
      }
      for (const scope of blessScopes) {
        // bless is the explicit escape hatch for a missing sidecar.
        const before = buildScope(scope, { allowMissingSidecar: true });
        const flagged = new Set(
          [...before.states.entries()].filter(([, s]) => s === DESCRIPTION_UNVERIFIED).map(([rel]) => rel)
        );
        for (const p of args.paths) {
          if (!flagged.has(p)) {
            process.stderr.write(`${TOOL}: note — ${p} is not flagged in scope "${scope.name}"; nothing to bless\n`);
          }
        }
        const result = buildScope(scope, { bless: { blessAll: args.all, blessPaths: args.paths }, allowMissingSidecar: true });
        writeOutputs(scope, result);
        reportTokens(scope, result);
      }
      process.exit(0);
    }

    if (args.command === "lint") {
      let errors = 0;
      for (const scope of scopes) {
        const result = buildScope(scope);
        for (const issue of lintEntries(result.docsWithSections.map((d) => d.doc))) {
          process.stderr.write(`lint: ${scope.name}: ${issue.rel}: ${issue.level}: ${issue.message}\n`);
          if (issue.level === "error") errors += 1;
        }
      }
      process.exit(errors > 0 ? 1 : 0);
    }

    for (const scope of scopes) {
      const result = buildScope(scope);
      reportTokens(scope, result);
      if (args.command === "gen") {
        writeOutputs(scope, result);
      } else {
        const stale = checkOutputs(scope, result);
        if (stale > 0) exitCode = 1;
      }
    }
  } catch (err) {
    if (err instanceof ConfigError || err instanceof UnmappedError || err instanceof Error) {
      process.stderr.write(`${TOOL}: ${err.message}\n`);
      process.exit(2);
    }
    throw err;
  }
  process.exit(exitCode);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main();
}
