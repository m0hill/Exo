# Tracer Slice (Zig): Patch → Render → Key Event → Patch → Render

This repository contains a minimal two-process tracer demo:

- `tui_runtime`: spawns a backend, reads JSONL patches, renders, sends JSONL key events
- `backend_demo`: emits patches and reacts to key events

## Manual repro (required)

1. `zig build demo`
2. Confirm screen shows “State: OFF”
3. Press `q` → screen updates to “State: ON”
4. Press `q` again → “OFF”
5. Press `x` → program exits, terminal restored

If terminal is broken, run `reset`.

## Protocol (v0)

Transport is newline-delimited JSON (JSONL) over pipes.

### Patch (backend → runtime)

```json
{"type":"patch","root":{"type":"vbox","id":"root","children":[ ... ]}}
```

### Event (runtime → backend)

```json
{"type":"event","name":"key","key":"q"}
```

### Failure modes

- Invalid JSON line: runtime logs to stderr and ignores the line
- Unknown node type / missing required fields: runtime logs to stderr and ignores the patch (keeps last good tree)

