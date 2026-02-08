#!/usr/bin/env python3
"""Protocol schema drift checker for the TUI JSONL protocol.

Checks:
- JSON Schema is valid Draft 2020-12.
- Canonical schema coverage matches Zig protocol types (messages/events/nodes/enums).
- Optional validation of JSONL captures (line-by-line against Msg entrypoint).
- Optional validation of JSON examples embedded in docs/PROTOCOL.md.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

try:
    from jsonschema import Draft202012Validator
except Exception as exc:  # pragma: no cover - dependency gate
    print(
        "ERROR: missing dependency 'jsonschema'. Install with: python3 -m pip install jsonschema",
        file=sys.stderr,
    )
    print(f"Import failure: {exc}", file=sys.stderr)
    raise SystemExit(2)


@dataclass
class CheckResult:
    errors: list[str]
    warnings: list[str]

    def fail(self, message: str) -> None:
        self.errors.append(message)

    def warn(self, message: str) -> None:
        self.warnings.append(message)


def normalize_ident(raw: str) -> str:
    token = raw.strip().rstrip(",")
    if token.startswith('@"') and token.endswith('"'):
        return token[2:-1]
    return token


def extract_block(source: str, decl: str) -> str:
    pattern = re.compile(rf"pub const {re.escape(decl)} = (union\(enum\)|enum|struct) \{{", re.MULTILINE)
    match = pattern.search(source)
    if not match:
        raise ValueError(f"Unable to find declaration for {decl}")

    start = match.end()
    depth = 1
    i = start
    while i < len(source):
        ch = source[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return source[start:i]
        i += 1
    raise ValueError(f"Unclosed declaration for {decl}")


def extract_union_tags(source: str, name: str) -> list[str]:
    body = extract_block(source, name)
    tags: list[str] = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        if ":" not in line:
            continue
        head = line.split(":", 1)[0].strip()
        tags.append(normalize_ident(head))
    return tags


def extract_enum_values(source: str, name: str) -> list[str]:
    body = extract_block(source, name)
    values: list[str] = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        if "=" in line or ":" in line:
            continue
        values.append(normalize_ident(line))
    return values


def extract_struct_fields(source: str, name: str) -> list[str]:
    body = extract_block(source, name)
    fields: list[str] = []
    for line in body.splitlines():
        line = line.strip()
        if not line or line.startswith("//"):
            continue
        match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*', line)
        if not match:
            continue
        fields.append(match.group(1))
    return fields


def resolve_ref(schema: dict[str, Any], ref: str) -> dict[str, Any]:
    if not ref.startswith("#/$defs/"):
        raise ValueError(f"Unsupported ref format: {ref}")
    name = ref.split("/")[-1]
    defs = schema.get("$defs", {})
    if name not in defs:
        raise ValueError(f"Missing $defs entry referenced by {ref}")
    node = defs[name]
    if not isinstance(node, dict):
        raise ValueError(f"Invalid schema node for {ref}")
    return node


def schema_message_types(schema: dict[str, Any]) -> list[str]:
    defs = schema["$defs"]
    msg = defs["Msg"]
    out: list[str] = []
    for variant in msg["oneOf"]:
        type_values = schema_type_values_from_ref(schema, variant["$ref"])
        if len(type_values) != 1:
            raise ValueError(f"Msg variant maps to ambiguous type values: {variant} -> {sorted(type_values)}")
        out.append(next(iter(type_values)))
    return out


def schema_event_names(schema: dict[str, Any]) -> list[str]:
    defs = schema["$defs"]
    msg = defs["EventMsg"]
    out: list[str] = []
    for variant in msg["oneOf"]:
        node = resolve_ref(schema, variant["$ref"])
        props = node.get("properties", {})
        name_def = props.get("name", {})
        const = name_def.get("const")
        if not isinstance(const, str):
            raise ValueError(f"Event variant lacks name.const: {variant}")
        out.append(const)
    return out


def schema_node_types(schema: dict[str, Any]) -> list[str]:
    defs = schema["$defs"]
    msg = defs["Node"]
    out: list[str] = []
    for variant in msg["oneOf"]:
        node = resolve_ref(schema, variant["$ref"])
        props = node.get("properties", {})
        type_def = props.get("type", {})
        const = type_def.get("const")
        if not isinstance(const, str):
            raise ValueError(f"Node variant lacks type.const: {variant}")
        out.append(const)
    return out


def schema_type_values_from_ref(schema: dict[str, Any], ref: str) -> set[str]:
    node = resolve_ref(schema, ref)
    props = node.get("properties", {})
    type_def = props.get("type", {})
    const = type_def.get("const")
    if isinstance(const, str):
        return {const}

    one_of = node.get("oneOf")
    if not isinstance(one_of, list):
        raise ValueError(f"Schema node has neither type.const nor oneOf: {ref}")

    out: set[str] = set()
    for variant in one_of:
        child_ref = variant.get("$ref")
        if not isinstance(child_ref, str):
            raise ValueError(f"Unsupported oneOf variant without $ref in {ref}: {variant}")
        out.update(schema_type_values_from_ref(schema, child_ref))
    return out


def check_exact_list(result: CheckResult, label: str, expected: list[str], actual: list[str]) -> None:
    if expected != actual:
        expected_set = set(expected)
        actual_set = set(actual)
        missing = sorted(expected_set - actual_set)
        extra = sorted(actual_set - expected_set)
        result.fail(
            f"{label} mismatch. missing={missing or '[]'} extra={extra or '[]'} "
            f"expected_order={expected} actual_order={actual}"
        )


def unique_preserving_order(items: list[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def validate_jsonl_file(
    path: Path,
    validator: Draft202012Validator,
    result: CheckResult,
) -> None:
    if not path.exists():
        result.fail(f"JSONL file not found: {path}")
        return

    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception as exc:
            result.fail(f"{path}:{line_no}: invalid JSON: {exc}")
            continue

        errors = sorted(validator.iter_errors(obj), key=lambda e: list(e.path))
        for err in errors:
            ptr = "/".join(str(p) for p in err.path)
            loc = f" at {ptr}" if ptr else ""
            result.fail(f"{path}:{line_no}: schema error{loc}: {err.message}")


def extract_json_codeblocks(markdown: str) -> list[str]:
    pattern = re.compile(r"```json\n(.*?)\n```", re.DOTALL)
    return [m.group(1) for m in pattern.finditer(markdown)]


def validate_docs_examples(
    docs_path: Path,
    msg_validator: Draft202012Validator,
    node_validator: Draft202012Validator,
    result: CheckResult,
) -> None:
    if not docs_path.exists():
        result.fail(f"Docs file not found: {docs_path}")
        return

    blocks = extract_json_codeblocks(docs_path.read_text(encoding="utf-8"))
    for idx, block in enumerate(blocks, start=1):
        raw = block.strip()
        if not raw:
            continue
        snippets = [raw]

        # Some doc blocks intentionally contain multiple one-line JSON objects.
        try:
            json.loads(raw)
        except json.JSONDecodeError as exc:
            if "Extra data" not in str(exc):
                result.fail(f"{docs_path}:json-block-{idx}: invalid JSON snippet: {exc}")
                continue
            snippets = [line.strip() for line in raw.splitlines() if line.strip()]

        for part_no, snippet in enumerate(snippets, start=1):
            try:
                obj = json.loads(snippet)
            except Exception as exc:
                result.fail(f"{docs_path}:json-block-{idx}.{part_no}: invalid JSON snippet: {exc}")
                continue

            msg_errors = sorted(msg_validator.iter_errors(obj), key=lambda e: list(e.path))
            if not msg_errors:
                continue
            node_errors = sorted(node_validator.iter_errors(obj), key=lambda e: list(e.path))
            if not node_errors:
                continue

            first = msg_errors[0]
            ptr = "/".join(str(p) for p in first.path)
            loc = f" at {ptr}" if ptr else ""
            result.fail(f"{docs_path}:json-block-{idx}.{part_no}: schema error{loc}: {first.message}")


def run_checks(args: argparse.Namespace) -> CheckResult:
    result = CheckResult(errors=[], warnings=[])

    schema = json.loads(args.schema.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    node_root = {"$schema": schema["$schema"], "$ref": "#/$defs/Node", "$defs": schema["$defs"]}
    node_validator = Draft202012Validator(node_root)

    types_src = args.types.read_text(encoding="utf-8")

    msg_tags = extract_union_tags(types_src, "Msg")
    event_tags = extract_union_tags(types_src, "EventMsg")
    node_tags = extract_union_tags(types_src, "Node")

    check_exact_list(
        result,
        "Msg variants",
        msg_tags,
        unique_preserving_order(schema_message_types(schema)),
    )
    check_exact_list(result, "Event variants", event_tags, schema_event_names(schema))
    check_exact_list(result, "Node variants", node_tags, schema_node_types(schema))

    enum_map = {
        "ThemeName": "ThemeName",
        "ValidationState": "ValidationState",
        "StateMode": "StateMode",
        "ListMarker": "ListMarker",
        "JustifyContent": "JustifyContent",
        "AlignItems": "AlignItems",
        "HorizontalAlign": "HorizontalAlign",
        "VerticalAlign": "VerticalAlign",
        "OverlayPlacement": "OverlayPlacement",
        "OverlayAlign": "OverlayAlign",
        "PointerKind": "PointerKind",
        "PointerButton": "PointerButton",
        "ClipboardOp": "ClipboardOp",
        "PasteSource": "PasteSource",
        "KeyAction": "KeyAction",
    }

    defs = schema["$defs"]
    for zig_name, schema_name in enum_map.items():
        expected = extract_enum_values(types_src, zig_name)
        actual = defs[schema_name]["enum"]
        check_exact_list(result, f"Enum {zig_name}", expected, actual)

    expected_contexts = extract_struct_fields(types_src, "KeybindingsConfig")
    actual_contexts = list(defs["KeybindingsConfig"]["properties"].keys())
    check_exact_list(result, "Keybindings contexts", expected_contexts, actual_contexts)

    expected_hello_caps = extract_struct_fields(types_src, "HelloCaps")
    actual_hello_caps = defs["HelloCaps"]["required"]
    check_exact_list(result, "HelloCaps fields", expected_hello_caps, actual_hello_caps)

    expected_hello_limits = extract_struct_fields(types_src, "HelloLimits")
    actual_hello_limits = defs["HelloLimits"]["required"]
    check_exact_list(result, "HelloLimits fields", expected_hello_limits, actual_hello_limits)

    for jsonl_path in args.jsonl:
        validate_jsonl_file(jsonl_path, validator, result)

    if args.docs:
        validate_docs_examples(args.docs, validator, node_validator, result)

    return result


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Check protocol.schema.json against Zig protocol types")
    parser.add_argument(
        "--schema",
        type=Path,
        default=Path("protocol.schema.json"),
        help="Path to canonical protocol JSON Schema",
    )
    parser.add_argument(
        "--types",
        type=Path,
        default=Path("src/lib/protocol/types.zig"),
        help="Path to Zig protocol types",
    )
    parser.add_argument(
        "--docs",
        type=Path,
        default=None,
        help="Validate JSON snippets in docs markdown file",
    )
    parser.add_argument(
        "--jsonl",
        type=Path,
        action="append",
        default=[],
        help="JSONL capture file to validate line-by-line (repeatable)",
    )
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    try:
        result = run_checks(args)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    for warning in result.warnings:
        print(f"WARN: {warning}")

    if result.errors:
        for err in result.errors:
            print(f"FAIL: {err}")
        print(f"FAILED with {len(result.errors)} error(s)")
        return 1

    print("OK: schema drift checks passed")
    if args.docs:
        print(f"OK: docs JSON snippets valid in {args.docs}")
    if args.jsonl:
        for path in args.jsonl:
            print(f"OK: JSONL validated {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
