// config.mjs — load and validate singular-brain.config.json.
//
// Config is pure data: JSON with string-encoded regexes, no logic. Every
// project-specific fact (folder taxonomy, excludes, table rules, outputs,
// budgets) lives here in the consumer repo; the engine stays generic.
// Validation fails closed: unknown keys, bad enums, bad regexes, duplicate
// outputs are hard errors (exit 2 at the CLI).

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

export const CONFIG_FILENAME = "singular-brain.config.json";
export const ENGINE_SCHEMA_VERSION = 1;
export const ADAPTERS = ["markdown-doc", "claude-skill"];

export class ConfigError extends Error {}

function fail(path, msg) {
  throw new ConfigError(`config: ${path}: ${msg}`);
}

function checkKeys(obj, allowed, path) {
  for (const k of Object.keys(obj)) {
    if (!allowed.includes(k)) fail(`${path}.${k}`, "unknown key");
  }
}

function requireString(obj, key, path) {
  if (typeof obj[key] !== "string" || obj[key] === "") {
    fail(`${path}.${key}`, "required non-empty string");
  }
  return obj[key];
}

function optionalString(obj, key, path) {
  if (obj[key] === undefined) return null;
  if (typeof obj[key] !== "string" || obj[key] === "") {
    fail(`${path}.${key}`, "must be a non-empty string when present");
  }
  return obj[key];
}

function optionalBool(obj, key, path, dflt) {
  if (obj[key] === undefined) return dflt;
  if (typeof obj[key] !== "boolean") fail(`${path}.${key}`, "must be a boolean");
  return obj[key];
}

function stringArray(obj, key, path, { required = false } = {}) {
  const v = obj[key];
  if (v === undefined) {
    if (required) fail(`${path}.${key}`, "required array of strings");
    return [];
  }
  if (!Array.isArray(v) || v.some((s) => typeof s !== "string")) {
    fail(`${path}.${key}`, "must be an array of strings");
  }
  return v;
}

function compileRegex(source, path) {
  try {
    return new RegExp(source);
  } catch (err) {
    fail(path, `invalid regex ${JSON.stringify(source)}: ${err.message}`);
  }
}

function compileRegexArray(sources, path) {
  return sources.map((s, i) => compileRegex(s, `${path}[${i}]`));
}

function normalizeFolder(raw, path) {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    fail(path, "must be an object");
  }
  const noEntries = optionalBool(raw, "noEntries", path, false);
  if (noEntries) {
    checkKeys(raw, ["dir", "character", "purpose", "noEntries"], path);
    return {
      dir: requireString(raw, "dir", path),
      character: requireString(raw, "character", path),
      purpose: requireString(raw, "purpose", path),
      noEntries: true,
      excludeLocal: [],
      include: null,
    };
  }
  checkKeys(
    raw,
    ["dir", "title", "character", "purpose", "scan", "optional", "include", "adapter", "excludeLocal", "noEntries"],
    path
  );
  const scan = requireString(raw, "scan", path);
  if (scan !== "flat" && scan !== "recursive") {
    fail(`${path}.scan`, `must be "flat" or "recursive", got ${JSON.stringify(scan)}`);
  }
  const adapter = optionalString(raw, "adapter", path) ?? "markdown-doc";
  if (!ADAPTERS.includes(adapter)) {
    fail(`${path}.adapter`, `unknown adapter ${JSON.stringify(adapter)}; known: ${ADAPTERS.join(", ")}`);
  }
  const includeSrc = optionalString(raw, "include", path);
  return {
    dir: requireString(raw, "dir", path),
    title: requireString(raw, "title", path),
    character: requireString(raw, "character", path),
    purpose: requireString(raw, "purpose", path),
    scan,
    optional: optionalBool(raw, "optional", path, false),
    noEntries: false,
    adapter,
    include: includeSrc === null ? null : compileRegex(includeSrc, `${path}.include`),
    includeSrc,
    excludeLocal: compileRegexArray(stringArray(raw, "excludeLocal", path), `${path}.excludeLocal`),
    excludeLocalSrc: stringArray(raw, "excludeLocal", path),
  };
}

function normalizeTable(raw, path, folders) {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    fail(path, "must be an object");
  }
  checkKeys(raw, ["match", "afterSection", "title", "intro"], path);
  const afterSection = requireString(raw, "afterSection", path);
  if (!folders.some((f) => !f.noEntries && f.dir === afterSection)) {
    fail(`${path}.afterSection`, `no non-noEntries folder with dir ${JSON.stringify(afterSection)}`);
  }
  return {
    match: compileRegex(requireString(raw, "match", path), `${path}.match`),
    matchSrc: raw.match,
    afterSection,
    title: requireString(raw, "title", path),
    intro: stringArray(raw, "intro", path),
  };
}

function normalizeScope(raw, path, configDir) {
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    fail(path, "must be an object");
  }
  checkKeys(
    raw,
    ["name", "base", "output", "jsonOutput", "title", "header", "tokenWarnThreshold", "rootLabel", "staleHint", "exhaustive", "freshness", "folders", "exclude", "tables"],
    path
  );
  const name = requireString(raw, "name", path);
  if (!/^[a-z][a-z0-9-]*$/.test(name)) {
    fail(`${path}.name`, "must be lowercase kebab-case");
  }
  const baseRel = requireString(raw, "base", path);
  const outputRel = requireString(raw, "output", path);
  const jsonOutputRel = optionalString(raw, "jsonOutput", path);

  let freshness = { enabled: false, sidecar: null, sidecarRel: null };
  if (raw.freshness !== undefined) {
    if (typeof raw.freshness !== "object" || raw.freshness === null || Array.isArray(raw.freshness)) {
      fail(`${path}.freshness`, "must be an object");
    }
    checkKeys(raw.freshness, ["enabled", "sidecar"], `${path}.freshness`);
    const enabled = optionalBool(raw.freshness, "enabled", `${path}.freshness`, false);
    const sidecarRel = optionalString(raw.freshness, "sidecar", `${path}.freshness`);
    if (enabled && sidecarRel === null) {
      fail(`${path}.freshness.sidecar`, "required when freshness.enabled is true");
    }
    freshness = {
      enabled,
      sidecar: sidecarRel === null ? null : resolve(configDir, sidecarRel),
      sidecarRel,
    };
  }

  if (!Array.isArray(raw.folders) || raw.folders.length === 0) {
    fail(`${path}.folders`, "required non-empty array");
  }
  const folders = raw.folders.map((f, i) => normalizeFolder(f, `${path}.folders[${i}]`));
  const dirs = folders.map((f) => f.dir);
  if (new Set(dirs).size !== dirs.length) {
    fail(`${path}.folders`, "duplicate folder dir");
  }

  const tokenWarnThreshold = raw.tokenWarnThreshold ?? 16000;
  if (typeof tokenWarnThreshold !== "number" || tokenWarnThreshold <= 0) {
    fail(`${path}.tokenWarnThreshold`, "must be a positive number");
  }

  if (raw.tables !== undefined && !Array.isArray(raw.tables)) {
    fail(`${path}.tables`, "must be an array");
  }

  return {
    name,
    base: resolve(configDir, baseRel),
    baseRel,
    output: resolve(configDir, outputRel),
    outputRel,
    jsonOutput: jsonOutputRel === null ? null : resolve(configDir, jsonOutputRel),
    jsonOutputRel,
    title: requireString(raw, "title", path),
    header: stringArray(raw, "header", path, { required: true }),
    tokenWarnThreshold,
    rootLabel: optionalString(raw, "rootLabel", path),
    staleHint: optionalString(raw, "staleHint", path),
    exhaustive: optionalBool(raw, "exhaustive", path, true),
    freshness,
    folders,
    exclude: compileRegexArray(stringArray(raw, "exclude", path), `${path}.exclude`),
    excludeSrc: stringArray(raw, "exclude", path),
    tables: (raw.tables ?? []).map((t, i) => normalizeTable(t, `${path}.tables[${i}]`, folders)),
  };
}

export function loadConfig(configPath) {
  let raw;
  try {
    raw = JSON.parse(readFileSync(configPath, "utf8"));
  } catch (err) {
    throw new ConfigError(`config: cannot read ${configPath}: ${err.message}`);
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    throw new ConfigError("config: top level must be an object");
  }
  checkKeys(raw, ["schemaVersion", "engineVersion", "scopes"], "config");
  if (raw.schemaVersion !== ENGINE_SCHEMA_VERSION) {
    throw new ConfigError(
      `config: schemaVersion ${JSON.stringify(raw.schemaVersion)} does not match engine schema version ${ENGINE_SCHEMA_VERSION}; see migrations/`
    );
  }
  if (!Array.isArray(raw.scopes) || raw.scopes.length === 0) {
    throw new ConfigError("config: scopes: required non-empty array");
  }
  const configDir = dirname(resolve(configPath));
  const scopes = raw.scopes.map((s, i) => normalizeScope(s, `scopes[${i}]`, configDir));

  const names = scopes.map((s) => s.name);
  if (new Set(names).size !== names.length) {
    throw new ConfigError("config: duplicate scope name");
  }
  const outputs = scopes.flatMap((s) =>
    [s.output, s.jsonOutput, s.freshness.sidecar].filter(Boolean)
  );
  if (new Set(outputs).size !== outputs.length) {
    throw new ConfigError("config: two scopes write the same output file");
  }

  return { schemaVersion: raw.schemaVersion, engineVersion: raw.engineVersion ?? null, configPath: resolve(configPath), configDir, scopes };
}
