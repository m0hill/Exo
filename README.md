# Tracer Slice (Zig): Patch → Render → Events → Patch → Render

This repository contains a minimal two-process tracer demo:

- `tui_runtime`: spawns a backend, reads JSONL patches, renders, sends JSONL events (key/focus/input/select/hover/pointer); mouse support is full opt-in via `mouseable:true` / `hoverable:true`
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

## Protocol (v0.12)

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

Optional fields:

- `mods` (int, optional): modifier bitmask (`shift=1`, `ctrl=2`, `alt=4`)
- `seq` (string, optional): debug payload for unrecognized escape sequences (typically when `key:"Unidentified"`)

Key naming scheme (W3C-like):

- Named keys: `Escape`, `Enter`, `Tab`, `Backspace`, `Delete`, `Insert`, `Home`, `End`, `PageUp`, `PageDown`, `ArrowUp`, `ArrowDown`, `ArrowLeft`, `ArrowRight`
- Function keys: `F1`..`F24`
- Text keys: literal UTF-8 text (e.g. `"a"`, `"漢"`)

Notes:

- ESC ambiguity is resolved via a short timeout (~25ms by default): a lone ESC becomes `Escape`, but `ESC <byte>` becomes `Alt+<byte>`.
- Runtime enables bracketed paste (`\x1b[?2004h`) and treats paste bodies as literal bytes (no key parsing inside paste).

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

Hover (strict opt-in via `hoverable:true`; emitted only on change):

```json
{"type":"event","name":"hover","id":"query","x":12,"y":3}
```

Hover leave (hovering “nothing”):

```json
{"type":"event","name":"hover","id":"","x":12,"y":3}
```

Hovering a list row (includes `item` when the row maps to an item id):

```json
{"type":"event","name":"hover","id":"results","x":12,"y":3,"item":"results-1"}
```

Pointer (strict opt-in via `mouseable:true`; emitted only for mouseable targets, plus change-only leave `id:""`):

```json
{"type":"event","name":"pointer","kind":"down","id":"results","x":12,"y":3,"local_x":2,"local_y":1,"button":"left","buttons":1,"mods":0,"clicks":1,"scroll_dx":0,"scroll_dy":0,"item":"results-1","captured":false}
```

Wheel/trackpad scroll (runtime emits `kind:"scroll"` with `scroll_dy` negative for up):

```json
{"type":"event","name":"pointer","kind":"scroll","id":"results","x":12,"y":3,"local_x":2,"local_y":1,"button":"none","buttons":0,"mods":0,"clicks":1,"scroll_dx":0,"scroll_dy":-1,"item":"results-1","captured":false}
```

### Nodes

- `vbox`: `{ "type":"vbox", "id":"...", "children":[ ... ] }`
- `hbox`: `{ "type":"hbox", "id":"...", "children":[ ... ] }`
- `box`: `{ "type":"box", "id":"...", "title":"...?", "border":true, "pad":0, "clip":true, "shadow":false, "child": { ... } }` (renders a border/title around `child`; `shadow` dims underlying cells without affecting layout)
- `scroll`: `{ "type":"scroll", "id":"...", "child": { ... } }`
- `overlay`: `{ "type":"overlay", "id":"...", "base": { ... }, "layers":[ {"node": { ... }, "anchor":"...", "placement":"below|above|right|left|center", "align":"start|center|end", "offset_x":0, "offset_y":0, "w":24, "h":3, "clip":true, "modal":false} ] }`
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

- `w` (int): fixed width (used when the parent is an `hbox`; also used for centering when a parent container is not stretching children)
- `h` (int): fixed height (used when the parent is a `vbox`; also used for vertical centering in an `hbox`)
- `flex` (int, default 0): share of remaining space along the parent's main axis

Containers (`vbox`/`hbox`) may also include:

- `pad` (int, default 0): uniform padding (in cells)
- `clip` (bool, default false): clip child rendering to the padded inner rect

### Hover (optional)

Any node may include:

- `hoverable` (bool, default false): strict opt-in for hover hit-testing + hover event emission. Hover events are emitted only when `(id,item)` changes; when hovering “nothing”, `id` is `""`. For lists, `item` is the row’s node id (when applicable).

### Mouse / Pointer (optional)

Any node may include:

- `mouseable` (bool, default false): strict opt-in for pointer hit-testing + `pointer` event emission. Terminal mouse modes are enabled only when the effective tree contains any `mouseable:true` or `hoverable:true`. Runtime-local click-to-focus/select and wheel scrolling are also gated on `mouseable:true`.

### Alignment (optional)

Containers (`vbox`/`hbox`) may also include:

- `justify_content`: `start|center|end|space_between|space_around|space_evenly`
- `align_items`: `start|center|end|stretch`
- `gap` (int, default 0): spacing between children along the main axis

Any node may include:

- `align_self`: `start|center|end|stretch` (overrides the parent container's `align_items` for that node)

Text nodes (`text`/`styled_text`) may include:

- `ext_align`: `left|center|right` (horizontal alignment of wrapped text within the node's rect)
- `v_align`: `top|center|bottom` (vertical alignment within the node's rect)

Input nodes may include:

- `content_align`: `left|center|right` (horizontal alignment of the value/placeholder within the input's rect; ignored while horizontally scrolling)

Runtime owns `input.value` + `input.cursor` (patches must not clobber local editing state).

### Failure modes

- Invalid JSON line: runtime logs to stderr and ignores the line
- Unknown node type / missing required fields: runtime logs to stderr and ignores the patch (keeps last good tree)
- Patch-by-id with unknown `target`: runtime logs `PATCH_WARN ... found=false` and ignores it
