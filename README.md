# Tracer Slice (Zig): Patch → Render → Events → Patch → Render

This repository contains a minimal two-process tracer demo:

- `tui_runtime`: spawns a backend, reads JSONL patches, renders, sends JSONL key events
- `backend_demo`: emits patches and reacts to key events

## Layout

- `src/bin`: executables (`tui_runtime`, `backend_demo`)
- `src/lib`: shared runtime/protocol/render code
- `src/test`: unit tests + test-only helpers

## Manual repro (slice 1)

1. `zig build demo`
2. Confirm screen shows “State: OFF”
3. Press `q` → screen updates to “State: ON”
4. Press `q` again → “OFF”
5. Press `x` → program exits, terminal restored

If terminal is broken, run `reset`.

## Manual repro (slice 2)

1. `zig build demo`
2. Confirm `Tick: 0` increments every ~250ms
3. Confirm input is focused (cursor visible on the input line); press `Tab` to toggle focus
4. Type `hello` (don’t press Enter)
5. Confirm tick keeps updating and the input stays intact (value + cursor) during patches
6. Confirm status updates to include your last input and focus id
7. Press `x` (or `Ctrl-C`) to exit

Tip: logs are written to stderr; run `zig build demo 2>trace.log` if you want a clean UI.

## Automated tests

Run:

- `zig build test`

What’s covered (no real TTY required):

- Rendering output + cursor placement via a mock terminal (`src/test/testing_terminal.zig`)
- Input editing rules (`src/lib/input.zig`)
- Patch-by-id tree updates (`src/lib/tree.zig`)
All tests live in `src/test/tests.zig`.

## Protocol (v0.2)

Transport is newline-delimited JSON (JSONL) over pipes.

### Patch (backend → runtime)

Full tree (replace root):

```json
{"type":"patch","root":{"type":"vbox","id":"root","children":[ ... ]}}
```

Patch-by-id (replace a node by `id`):

```json
{"type":"patch","target":"clock","node":{"type":"text","id":"clock","text":"Tick: 12"}}
```

### Event (runtime → backend)

Key event:

```json
{"type":"event","name":"key","key":"q"}
```

Focus changed:

```json
{"type":"event","name":"focus","id":"query"}
```

Input changed:

```json
{"type":"event","name":"input","id":"query","value":"hello","cursor":5}
```

### Nodes

- `vbox`: `{ "type":"vbox", "id":"...", "children":[ ... ] }`
- `text`: `{ "type":"text", "id":"...", "text":"..." }`
- `input`: `{ "type":"input", "id":"...", "placeholder":"..." }`

Runtime owns `input.value` + `input.cursor` (patches must not clobber local editing state).

### Failure modes

- Invalid JSON line: runtime logs to stderr and ignores the line
- Unknown node type / missing required fields: runtime logs to stderr and ignores the patch (keeps last good tree)
- Patch-by-id with unknown `target`: runtime logs `PATCH_WARN ... found=false` and ignores it
