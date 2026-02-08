# Protocol

Transport is **newline-delimited JSON (JSONL)** over stdin/stdout pipes:

- backend → runtime: patches (and clipboard requests)
- runtime → backend: events

This repo’s current protocol is defined by the Zig types in `src/lib/protocol/types.zig`.

## Messages

Every line is a single JSON object with a `type`:

- `patch` (backend → runtime)
- `event` (runtime → backend)
- `clipboard` (backend → runtime)
- `config` (backend → runtime)
- `theme` (backend → runtime)

Optional top-level version field:

- `v` (integer, optional) can appear on any message type
- current protocol version is `1`
- receivers must accept messages with or without `v`
- senders may omit `v` to keep payloads smaller

Compatibility policy:

- additive fields are non-breaking
- unknown fields must be ignored
- removing or changing meaning of existing fields is breaking and requires a new version rollout plan

### Patch (backend → runtime)

Full tree (replace root):

```json
{"type":"patch","root":{"type":"vbox","id":"root","children":[]}}
```

Patch-by-id:

```json
{"type":"patch","target":"clock","node":{"type":"text","id":"clock","text":"Tick: 12"}}
```

Patch mode:

- default is replace
- `mode:"morph"` enables keyed morphing for container children (reorder/insert/remove)

```json
{"type":"patch","target":"root","mode":"morph","node":{"type":"vbox","id":"root","children":[]}}
```

Optional patch sequencing:

```json
{"type":"patch","seq":42,"target":"clock","node":{"type":"text","id":"clock","text":"Tick: 42"}}
```

Notes:

- runtime treats `seq` as monotonic and drops stale patches (`seq <= last_seen_seq`)
- runtime continues rendering the last good tree when a patch is dropped/invalid

### Clipboard (backend → runtime)

Write:

```json
{"type":"clipboard","op":"write","data":"copied text","target":"clipboard"}
```

Read:

```json
{"type":"clipboard","op":"read","request_id":1,"target":"clipboard"}
```

### Config (backend -> runtime)

Runtime keybindings can be replaced at runtime with a strict, replace-style message:

```json
{
  "type":"config",
  "keybindings":{
    "global":[{"key":"Tab","action":"focus_next"}],
    "list":[{"key":"j","action":"list_next"},{"key":"k","action":"list_prev"}]
  }
}
```

Config can also switch the active runtime theme:

```json
{"type":"config","theme":"light"}
```

Rules:

- each rule is `{ "key": string, "mods": number (optional, default 0), "action": string }`
- `mods` uses the runtime bitmask: `shift=1`, `ctrl=2`, `alt=4`
- contexts are optional: `global`, `input`, `textarea`, `list`, `scroll`, `action`
- omitted contexts keep runtime defaults
- explicit empty arrays clear defaults for that context
- matching is exact (`key` + `mods`), context-first and then `global`
- malformed rules reject the entire config message

Theme names:

- `default`
- `light`
- `ocean`

### Theme (backend -> runtime)

A dedicated theme message can also change active theme at runtime:

```json
{"type":"theme","name":"ocean"}
```

Action names:

- focus/actions: `noop`, `focus_next`, `focus_prev`, `focus_scope_next`, `focus_scope_prev`, `focus_clear`, `action_activate`
- list: `list_prev`, `list_next`, `list_activate`
- scroll: `scroll_line_up`, `scroll_line_down`, `scroll_page_up`, `scroll_page_down`, `scroll_home`, `scroll_end`
- input: `input_left`, `input_right`, `input_word_left`, `input_word_right`, `input_home`, `input_end`, `input_delete`, `input_backspace`, `input_select_left`, `input_select_right`, `input_select_word_left`, `input_select_word_right`, `input_select_home`, `input_select_end`, `input_select_all`, `input_copy`, `input_paste`, `input_undo`, `input_redo`
- textarea: `textarea_left`, `textarea_right`, `textarea_up`, `textarea_down`, `textarea_word_left`, `textarea_word_right`, `textarea_home`, `textarea_end`, `textarea_page_up`, `textarea_page_down`, `textarea_delete`, `textarea_backspace`, `textarea_newline`, `textarea_select_left`, `textarea_select_right`, `textarea_select_up`, `textarea_select_down`, `textarea_select_word_left`, `textarea_select_word_right`, `textarea_select_home`, `textarea_select_end`, `textarea_select_all`, `textarea_copy`, `textarea_paste`, `textarea_undo`, `textarea_redo`

### Event (runtime → backend)

Startup handshake (sent once after runtime spawns backend):

```json
{"type":"event","name":"hello","protocol_version":1,"caps":{"ansi":true,"alt_screen":true,"bracketed_paste":true,"mouse_sgr":true,"osc52":true,"color":"ansi256"},"limits":{"max_fps":30,"frame_interval_ns":33333333,"max_pending_targets":256,"max_backend_lines_per_iter":128,"queue_overflow":"drop_newest"}}
```

Notes:

- `protocol_version` is the runtime's protocol schema version
- `caps` advertises detected runtime/terminal capabilities
- `limits` advertises runtime scheduling/backpressure limits in effect

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

List selection / activation:

```json
{"type":"event","name":"select","id":"results","item":"row-2"}
{"type":"event","name":"activate","id":"results","item":"row-2"}
```

Scroll:

```json
{"type":"event","name":"scroll","id":"viewport","scroll_y":12}
```

Resize:

```json
{"type":"event","name":"resize","rows":24,"cols":80}
```

Hover / pointer (emitted only for nodes that opt in; see `hoverable`/`mouseable`):

```json
{"type":"event","name":"hover","id":"btn-ok","x":10,"y":4,"item":null}
{"type":"event","name":"pointer","kind":"down","id":"btn-ok","x":10,"y":4,"local_x":1,"local_y":0,"button":"left","clicks":1}
```

Clipboard result + paste semantic:

```json
{"type":"event","name":"clipboard","op":"read","ok":true,"request_id":1,"data":"pasted"}
{"type":"event","name":"paste","source":"clipboard","bytes":6}
```

Runtime error event (machine-readable runtime-side rejection):

```json
{"type":"event","name":"error","code":"invalid_patch_shape","message":"backend patch rejected: invalid shape","seq":42,"context":"InvalidPatchShape"}
```

Config acknowledgement event (runtime config negotiation result):

```json
{"type":"event","name":"config_ack","applied":["keybindings"],"rejected":[{"key":"theme","reason":"UnknownThemeName"}]}
```

`config_ack` rules:

- runtime emits one `config_ack` for every backend `config` message attempt
- `applied` is an array of top-level keys that were accepted (`keybindings`, `theme`)
- `rejected` is an array of `{ "key": string, "reason": string }`
- malformed config that cannot be mapped to a specific top-level key uses `key:"config"`
- keybindings are evaluated first; if keybindings fail, runtime rejects `theme` in the same message with reason `keybindings_rejected`

Optional runtime render/drop telemetry:

```json
{"type":"event","name":"rendered","seq":42,"dropped":0,"bytes":512,"changed_cells":27}
{"type":"event","name":"dropped","seq":41,"reason":"stale_seq"}
```

Stable `event:error` codes:

- `invalid_line`: runtime rejected a backend line (invalid JSON or invalid message schema)
- `invalid_patch_shape`: runtime rejected a backend patch shape/mode
- `config_rejected`: runtime rejected backend config (parse-time or apply-time)

## Nodes

Nodes form a tree. Every node has a required `id` and a `type`.

Node types (current):

- containers: `vbox`, `hbox`, `grid`, `box`, `scroll`, `overlay`
- text: `text`, `styled_text`
- inputs: `input`, `textarea`
- collection: `list`

### Common fields (most nodes)

- `id` (string, required)
- `class` (string, optional): theme class hook (exact string match; no selector language)
- layout: `w`/`h` (int?), `flex` (int), `pad` (int), `clip` (bool)
- interaction/state: `hoverable` (bool), `mouseable` (bool), `focusable` (bool), `disabled` (bool), `readonly` (bool)
- focus scoping: `focus_scope` (string, optional; alias `focus_group` accepted on input)
- validation: `validation` (`none|error|warning|success`)
- `style` (object, optional): style overrides

### Controlled State

State-capable widgets support `state_mode`:

- `uncontrolled` (default): runtime is source of truth for local widget state
- `init`: apply backend state once when the widget first appears
- `controlled`: backend is source of truth on every patch

Patch application rule:

- runtime never emits events just because a patch applied widget state
- exception kept for compatibility: uncontrolled `list` still auto-selects first item and emits initial `select`

State fields by widget:

- `input`: `value`, `cursor`, `scroll_x`, `selection_start`, `selection_end`
- `textarea`: `value`, `cursor`, `scroll_y`, `selection_start`, `selection_end`
- `list`: `selected_id`, `scroll`
- `scroll`: `scroll_y`

Examples:

Controlled input:

```json
{"type":"patch","root":{"type":"input","id":"query","state_mode":"controlled","value":"hello","cursor":5}}
```

Controlled list selection:

```json
{"type":"patch","root":{"type":"list","id":"results","state_mode":"controlled","selected_id":"row-2","children":[{"type":"text","id":"row-1","text":"A"},{"type":"text","id":"row-2","text":"B"}]}}
```

Controlled scroll viewport:

```json
{"type":"patch","root":{"type":"scroll","id":"viewport","state_mode":"controlled","scroll_y":12,"child":{"type":"text","id":"body","text":"...content..."}}}
```

`focus_scope` behavior:

- focus traversal (`focus_next` / `focus_prev`) is trapped within the currently focused node's scope
- `focus_scope_next` / `focus_scope_prev` jump across scope boundaries
- nodes without `focus_scope` are in the default global scope (`null`)

### Styling (`style`)

`style` is a tri-state override object (inherit/clear/value). Example:

```json
{"type":"text","id":"status","text":"Connected","style":{"fg":"#00FF00","bold":true}}
```

`input`/`textarea` also accept `placeholder_style` and `selection_style`.

### Grid (`type:"grid"`)

`grid` provides table-like layout without manual hbox/vbox nesting:

- track sizing:
  - fixed: number (example `10`)
  - auto: string `"auto"`
  - fractional: string `"<n>fr"` (example `"2fr"`)
- `rows` and `cols` are required track arrays.
- spacing: `gap_x`, `gap_y`.
- optional named areas: `areas` is an array of row strings (space-delimited names), for example:
  - `"header header"`
  - `"sidebar content"`

Child placement fields (available on all node types):

- `grid_row`, `grid_col` (0-based explicit cell)
- `row_span`, `col_span` (default `1`)
- `grid_area` (name from `areas`)
- precedence: explicit `grid_row`/`grid_col` placement is used when present; `grid_area` is used otherwise.

### Terminal caps / env overrides

Color mode:

- `NO_COLOR=1`
- `TUI_COLOR_MODE=truecolor|256|16|mono`

Capability profile + feature disables:

- `TUI_TERM_PROFILE=dumb|xterm|screen|tmux|alacritty|kitty|wezterm|vscode|iterm2|windows-terminal`
- `TUI_CAPS_DISABLE=mouse,osc52,altscreen,bracketed_paste,...`

## Failure modes

- invalid JSON line: runtime logs and ignores the line
- unknown node type / missing required fields: runtime logs and ignores the patch (keeps last good tree)
- patch-by-id with unknown `target`: runtime logs and ignores it
- runtime also emits `event:error` (rate-limited) for invalid lines, invalid patch shape/mode, and config rejection
