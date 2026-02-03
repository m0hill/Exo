# Tracer Slice (Zig): Patch → Render → Events → Patch → Render

This repository contains a minimal two-process tracer demo:

- `tui_runtime`: spawns a backend, reads JSONL patches, renders, sends JSONL events (key/focus/input/select); mouse click-to-focus/select + wheel list scroll are handled in the runtime
- `backend_demo`: emits patches and reacts to key events

## Layout

- `src/bin`: executables (`tui_runtime`, `backend_demo`)
- `src/lib`: shared runtime/protocol/render code
- `src/test`: unit tests + test-only helpers

## Manual Testing

Each slice has manual reproduction steps documented in `progress.json` under the `manual_repro` field.

Quick start:

```bash
zig build demo        # Run the interactive demo
zig build test        # Run all unit tests
```

Tip: when running interactively, logs go to `/tmp/tui_trace.log` to avoid corrupting the TUI (set `TUI_LOG_STDERR=1` or use `2>trace.log` if you prefer stderr). If terminal is broken, run `reset`. Emergency exit chord: `Ctrl-G` then `Ctrl-G` (restores terminal and exits immediately).

## Automated tests

Run:

- `zig build test`

What's covered (no real TTY required):

- Rendering output + cursor placement via a mock terminal (`src/test/testing_terminal.zig`)
- Incremental rendering (frame diff emits small updates)
- Input editing rules (`src/lib/input.zig`)
- Patch-by-id tree updates (`src/lib/tree.zig`)
All tests live in `src/test/tests.zig`.

## Protocol (v0.6)

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

Patch-by-id with morph mode (keyed reorders/inserts/removals in containers):

```json
{"type":"patch","target":"root","mode":"morph","node":{"type":"vbox","id":"root","children":[ ... ]}}
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

List selection changed:

```json
{"type":"event","name":"select","id":"results","item":"item-2"}
```

List item activated:

```json
{"type":"event","name":"activate","id":"results","item":"item-2"}
```

Scroll viewport moved (optional):

```json
{"type":"event","name":"scroll","id":"md-scroll","scroll_y":42}
```

Resize (runtime-generated):

```json
{"type":"event","name":"resize","rows":40,"cols":120}
```

### Nodes

- `vbox`: `{ "type":"vbox", "id":"...", "children":[ ... ] }`
- `hbox`: `{ "type":"hbox", "id":"...", "children":[ ... ] }`
- `scroll`: `{ "type":"scroll", "id":"...", "child": { ... } }`
- `text`: `{ "type":"text", "id":"...", "text":"..." }`
- `styled_text`: `{ "type":"styled_text", "id":"...", "spans":[ {"text":"...","style":{...}} ] }`
- `input`: `{ "type":"input", "id":"...", "placeholder":"..." }`
- `list`: `{ "type":"list", "id":"...", "height":3, "children":[ ... ] }`

### Styling

Any node may include an optional `style` object. `input` nodes may also include `placeholder_style`.

```json
{"type":"text","id":"status","text":"Connected","style":{"fg":"#00FF00","bold":true}}
```

Runtime selects a color mode automatically (and degrades gracefully). You can force it via:

- `NO_COLOR=1` (disable colors)
- `TUI_COLOR_MODE=truecolor|256|16|mono`

### Layout hints (optional)

Any node may include:

- `w` (int): fixed width (used when the parent is an `hbox`)
- `h` (int): fixed height (used when the parent is a `vbox`)
- `flex` (int, default 0): share of remaining space along the parent's main axis

Containers (`vbox`/`hbox`) may also include:

- `pad` (int, default 0): uniform padding (in cells)
- `clip` (bool, default false): clip child rendering to the padded inner rect

Runtime owns `input.value` + `input.cursor` (patches must not clobber local editing state).

### Failure modes

- Invalid JSON line: runtime logs to stderr and ignores the line
- Unknown node type / missing required fields: runtime logs to stderr and ignores the patch (keeps last good tree)
- Patch-by-id with unknown `target`: runtime logs `PATCH_WARN ... found=false` and ignores it
