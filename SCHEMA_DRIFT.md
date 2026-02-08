# Schema Drift Checklist

Guardrail checklist for keeping `protocol.schema.json` aligned with runtime/backend wire behavior.

## 1) Static Drift Check (Schema <-> Zig Types)

Install validator dependency once:

```bash
python3 -m pip install jsonschema
```

Run canonical drift checks:

```bash
python3 scripts/check_protocol_schema.py --docs docs/PROTOCOL.md
```

This verifies:

- JSON Schema is valid (Draft 2020-12)
- `Msg` / `EventMsg` / `Node` variant coverage matches `src/lib/protocol/types.zig`
- Canonical enum sets match Zig enums (`KeyAction`, `ThemeName`, pointer/layout enums, etc.)
- Keybinding contexts match (`global`, `input`, `textarea`, `list`, `scroll`, `action`)
- `hello` caps/limits fields stay aligned
- JSON examples in `docs/PROTOCOL.md` validate

## 2) Capture Real Demo Traffic

```bash
zig build
rm -f tui_backend.jsonl tui_events.jsonl
zig-out/bin/tui_runtime --cmd sh -c 'tee tui_events.jsonl | zig-out/bin/backend_demo | tee tui_backend.jsonl'
```

- Use the demo briefly (keypresses, focus changes, list activity, pointer activity if available), then exit runtime with `Ctrl-C`.
- Resulting files:
  - `tui_backend.jsonl`: backend -> runtime messages (`patch` / `config` / `clipboard`)
  - `tui_events.jsonl`: runtime -> backend messages (`event`)

## 3) Validate Captured JSONL Against Canonical Schema

```bash
python3 scripts/check_protocol_schema.py \
  --jsonl tui_backend.jsonl \
  --jsonl tui_events.jsonl
```

## 4) Regression Checks

```bash
zig build test
zig build demo
```

## Later: Automate in CI

- Capture protocol fixture JSONL in CI.
- Run `scripts/check_protocol_schema.py` in CI.
- Fail CI on schema drift (types/docs/schema mismatch).
