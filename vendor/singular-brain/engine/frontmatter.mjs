// frontmatter.mjs — minimal YAML-subset frontmatter parser.
//
// Deliberately strict by default: single-line scalars (split on the first
// ": ") and two-space-indented dash lists only. No nested maps, no inline
// arrays, no multiline strings. An opening "---" with no closing exact "---"
// line is an unterminated block: a hard error in strict mode (a near-miss
// like "----" or a trailing space does not close it), null in lenient. Two
// opt-ins exist for adapters that read externally-authored files:
//   - allowFoldedScalars: `key: >-` / `key: >` folded block scalars, joined
//     with single spaces.
//   - lenient: unparseable lines are skipped instead of throwing (e.g. a
//     nested map an external tool wrote); the strict default fails fast so
//     malformed frontmatter in owned docs is a build error, not silence.

export function normalize(raw) {
  let text = raw;
  if (text.charCodeAt(0) === 0xfeff) text = text.slice(1);
  return text.replace(/\r\n/g, "\n");
}

export function stripQuotes(v) {
  if (
    (v.startsWith('"') && v.endsWith('"') && v.length >= 2) ||
    (v.startsWith("'") && v.endsWith("'") && v.length >= 2)
  ) {
    return v.slice(1, -1);
  }
  return v;
}

// Returns { fields, bodyStart } or null when the file has no opening "---".
// Throws (strict mode) with a 1-based line number on any line that is not
// blank, a comment, a dash-list item, or a `key: value` scalar — and, with
// no line number, when the opening "---" has no closing "---" line. In
// lenient mode both cases are tolerated (null / skipped).
export function parseFrontmatter(lines, options = {}) {
  const { allowFoldedScalars = false, lenient = false } = options;
  if (lines[0] !== "---") return null;
  const end = lines.indexOf("---", 1);
  if (end === -1) {
    if (lenient) return null;
    throw new Error(
      'frontmatter parse error: unterminated frontmatter — the opening "---" ' +
        'on line 1 has no closing "---" line (a near-miss like "----" or ' +
        "trailing whitespace does not count)"
    );
  }
  const fm = {};
  let listKey = null;
  for (let i = 1; i < end; i += 1) {
    const line = lines[i];
    if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue;
    const listItem = line.match(/^\s+-\s+(.+?)\s*$/);
    if (listItem && listKey) {
      fm[listKey].push(stripQuotes(listItem[1]));
      continue;
    }
    const kv = line.match(/^([A-Za-z][A-Za-z0-9_-]*):(?:\s+(.*?))?\s*$/);
    if (!kv) {
      if (lenient) {
        listKey = null;
        continue;
      }
      throw new Error(
        `frontmatter parse error at line ${i + 1}: ${JSON.stringify(line)}`
      );
    }
    const key = kv[1];
    const value = kv[2];
    if (allowFoldedScalars && (value === ">" || value === ">-")) {
      const folded = [];
      while (i + 1 < end && /^\s+\S/.test(lines[i + 1])) {
        folded.push(lines[i + 1].trim());
        i += 1;
      }
      fm[key] = folded.join(" ");
      listKey = null;
    } else if (value === undefined || value === "") {
      fm[key] = [];
      listKey = key;
    } else {
      fm[key] = stripQuotes(value);
      listKey = null;
    }
  }
  return { fields: fm, bodyStart: end + 1 };
}
