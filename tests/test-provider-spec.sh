#!/usr/bin/env bash
set -euo pipefail

# engine/providers.json is the single place a provider fact is decided. This
# test is what makes that true of the copies the engine keeps for speed: every
# full provider-set literal in the engine, the console and the schemas must
# equal the spec's provider set, every subset must be one this file justifies,
# and the derived tables (doctor, capability_policy, console fallbacks, adapter
# model defaults) must agree with the spec value for value.
#
# The failure this exists to prevent has already happened: the default model
# lived in the grok adapter AND in doctor's table, they were edited apart, and
# a model id that never existed shipped in every grok invocation.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "engine"))
sys.path.insert(0, str(root / "plugin" / "scripts"))
import provider_spec as spec

failures: list[str] = []


def check(condition: bool, message: str) -> None:
    if not condition:
        failures.append(message)


spec_path = root / "engine" / "providers.json"
data = spec.load(spec_path)
names = spec.names(spec_path)
name_set = set(names)
strict = spec.strict_isolation_providers(spec_path)
unproven_isolation = name_set - strict

# 1. Every provider names an adapter that exists and can be dispatched.
for provider, entry in spec.providers(spec_path).items():
    adapter = root / "engine" / entry["adapter"]
    check(adapter.is_file(), f"{provider}: adapter is missing: {adapter}")
    if adapter.is_file():
        import os

        check(
            os.access(adapter, os.X_OK),
            f"{provider}: adapter is not executable: {adapter}",
        )

# 2/3. No file may carry a second opinion about which providers exist.
#      Subsets are allowed only where the subset IS the meaning -- and the
#      isolation subset is checked against the spec rather than trusted.
SUBSET_REASONS = {
    ("engine/doctor.py", frozenset({"cursor", "grok"})):
        "providers with no proven built-in isolation (spec strictIsolation:false)",
    ("engine/lib.sh", frozenset({"cursor", "grok"})):
        "providers with no proven built-in isolation (spec strictIsolation:false)",
    ("engine/lib.sh", frozenset({"gemini", "opencode", "openrouter"})):
        "CLIs whose terminal envelope nests status and code under an error key",
    ("engine/lib.sh", frozenset({"opencode", "openrouter"})):
        "providers dispatched through the OpenCode CLI, so they share its "
        "terminal event shape",
    ("engine/lib.sh", frozenset({"claude", "cursor"})):
        "CLIs whose result text is the fallback error carrier",
    ("engine/lib.sh", frozenset({"claude", "cursor", "grok"})):
        "envelopes that carry token counters at top level",
    ("plugin/scripts/singular_graph_server.py",
     frozenset({"claude", "codex", "cursor", "opencode"})):
        "console providers with a login command",
    ("plugin/scripts/singular_graph_server.py", frozenset({"gemini", "opencode"})):
        "console auth inference strategies keyed by provider",
    ("engine/provider_resolver.py", frozenset({"claude", "grok"})):
        "adapters that consume per-role model and effort keys rather than a "
        "single flat model setting",
}
ISOLATION_SUBSETS = {frozenset({"cursor", "grok"})}

scanned = [
    root / "engine" / "lib.sh",
    root / "cli" / "singular",
    root / "plugin" / "scripts" / "singular_graph_server.py",
    *sorted((root / "engine").glob("*.py")),
    *sorted((root / "engine").glob("*-run.sh")),
    *sorted((root / "schemas").rglob("*.json")),
]
group = re.compile(r"[\{\[]([^\{\}\[\]]*)[\}\]]", re.S)
quoted = re.compile(r"""["']([A-Za-z0-9_.\-/]+)["']""")
for path in scanned:
    if not path.is_file() or path.name == "providers.json":
        continue
    rel = path.relative_to(root).as_posix()
    text = path.read_text(encoding="utf-8", errors="replace")
    for match in group.finditer(text):
        tokens = quoted.findall(match.group(1))
        found = {token for token in tokens if token in name_set}
        if len(found) < 2:
            continue
        line = text[: match.start()].count("\n") + 1
        where = f"{rel}:{line}"
        if any(token.endswith("-run.sh") for token in tokens):
            try:
                mapped = json.loads(match.group(0))
            except json.JSONDecodeError:
                # A python dict literal, not the JSON map lib.sh embeds; its
                # contents are pinned field-by-field further down.
                mapped = None
            if mapped is not None:
                check(
                    mapped == spec.adapter_providers(spec_path),
                    f"{where}: adapter map disagrees with the spec: {mapped}",
                )
                continue
        if found == name_set:
            # Complete: whatever else the literal holds is this consumer's own
            # per-provider values, which the field checks below compare.
            continue
        frozen = frozenset(found)
        if frozen in ISOLATION_SUBSETS:
            check(
                found == unproven_isolation,
                f"{where}: isolation subset {sorted(found)} != spec "
                f"strictIsolation:false {sorted(unproven_isolation)}",
            )
            continue
        check(
            (rel, frozen) in SUBSET_REASONS,
            f"{where}: undocumented provider subset {sorted(found)} -- state its "
            "meaning in SUBSET_REASONS or derive it from the spec",
        )

# 4. Doctor's tables are the spec's, not a second copy of it.
import doctor

check(
    {p: (v[0], v[1]) for p, v in doctor.PROVIDERS.items()}
    == {
        p: (entry["adapter"], entry["binary"])
        for p, entry in spec.providers(spec_path).items()
    },
    "doctor.PROVIDERS disagrees with the spec",
)
check(doctor.MODEL_ENV == spec.model_env(spec_path), "doctor.MODEL_ENV disagrees with the spec")
check(
    {p: pattern.pattern for p, pattern in doctor.MODEL_PATTERNS.items()}
    == {p: pattern.pattern for p, pattern in spec.model_patterns(spec_path).items()},
    "doctor.MODEL_PATTERNS disagrees with the spec",
)
check(
    {p: tuple(v) for p, v in doctor.MODEL_LISTINGS.items()}
    == {
        p: spec.model_listing(p, spec_path)
        for p in names
        if spec.model_listing(p, spec_path)
    },
    "doctor.MODEL_LISTINGS disagrees with the spec",
)

# 5. The strict-argument policy covers exactly the providers the spec says have
#    a native isolation mode; the rest must reach strict through validated
#    providerArgs, which is a different mechanism, not a missing table row.
import capability_policy

check(
    set(capability_policy.STRICT_PROVIDER_DENIED_OPTIONS) == strict,
    "capability_policy strict providers "
    f"{sorted(capability_policy.STRICT_PROVIDER_DENIED_OPTIONS)} != spec "
    f"strictIsolation:true {sorted(strict)}",
)

# 6. The console's provider registry and its model fallbacks describe the same
#    installation the engine dispatches -- a card naming a different binary or
#    a different default model is the operator being told a fiction.
import singular_graph_server as console

console_registry = {item["id"]: item for item in console.PROVIDERS}
check(
    set(console_registry) == name_set,
    f"console PROVIDERS {sorted(console_registry)} != spec {sorted(name_set)}",
)
for provider in sorted(name_set & set(console_registry)):
    entry = spec.entry(provider, spec_path)
    item = console_registry[provider]
    check(
        item["binary"] == entry["binary"],
        f"console {provider} binary {item['binary']} != spec {entry['binary']}",
    )
    check(
        item["runnerScript"] == entry["adapter"],
        f"console {provider} runnerScript {item['runnerScript']} != spec "
        f"{entry['adapter']}",
    )
check(
    console._CONFIG_MODEL_FALLBACK == spec.model_env(spec_path),
    "console _CONFIG_MODEL_FALLBACK disagrees with the spec: "
    f"{console._CONFIG_MODEL_FALLBACK}",
)

# 7. Adapter model defaults. Every literal fallback an adapter carries for its
#    own model variable must be the spec's default -- five copies of a default
#    is five chances to edit one of them.
literal_default = re.compile(r"SINGULAR_[A-Z0-9_]*MODEL:-([^$}][^}]*)")
for provider, entry in spec.providers(spec_path).items():
    adapter = root / "engine" / entry["adapter"]
    if not adapter.is_file():
        continue
    text = adapter.read_text(encoding="utf-8")
    expected = entry["model"].get("default", "")
    for found in literal_default.findall(text):
        check(
            found == expected,
            f"{entry['adapter']}: model default '{found}' != spec '{expected}'",
        )

# 8. Every adapter takes its provider facts from the spec rather than carrying
#    them. tests/test-provider-update-pin.sh proves the pin reaches the provider
#    process; this asserts the adapter asks for it at all, so a new adapter
#    copied from a sibling cannot quietly drop the call. An adapter may also
#    delegate to a shared host (openrouter rides OpenCode's), in which case it
#    declares its identity and the host loads the row for it.
host_call = re.compile(r"singular_provider_spec_load\s+\"\$provider\"")
for provider, entry in spec.providers(spec_path).items():
    adapter = root / "engine" / entry["adapter"]
    if not adapter.is_file():
        continue
    text = adapter.read_text(encoding="utf-8")
    if f"singular_provider_spec_load {provider}" in text:
        continue
    hosts = re.findall(r'source "\$SCRIPT_DIR/([a-z0-9-]+-host\.sh)"', text)
    delegated = False
    for host_name in hosts:
        host = root / "engine" / host_name
        if not host.is_file():
            continue
        if f'provider="{provider}"' in text and host_call.search(
            host.read_text(encoding="utf-8")
        ):
            delegated = True
            break
    check(
        delegated,
        f"{entry['adapter']}: must load its spec row (singular_provider_spec_load "
        f"{provider}, or declare provider=\"{provider}\" to a host that does)",
    )

# 9. Schema enums are generated from the spec, in spec order: a provider the
#    engine can dispatch but the result schema rejects fails at write time,
#    after the work is done.
for schema_path in sorted((root / "schemas").rglob("*.json")):
    document = json.loads(schema_path.read_text(encoding="utf-8"))
    provider_enum = (
        document.get("properties", {}).get("provider", {}).get("enum")
    )
    if provider_enum is None:
        continue
    check(
        provider_enum == names,
        f"{schema_path.relative_to(root).as_posix()}: provider enum "
        f"{provider_enum} != spec order {names}",
    )

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)
PY

echo "PASS: test-provider-spec"
