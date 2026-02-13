# Protocol

Transport is **newline-delimited JSON (JSONL)** over stdin/stdout pipes:

- backend → runtime: patches (and clipboard requests)
- runtime → backend: events

Canonical protocol artifact for SDK generation and validation is `../protocol.schema.json` (JSON Schema
2020-12).

The Zig types in `src/lib/protocol/types.zig` are the reference implementation and must remain in sync
with `../protocol.schema.json`.

## JSONL Validation

- One JSON object per line.
- Validate each line against `Msg` (the schema entrypoint in `../protocol.schema.json`).

## Messages

Every line is a single JSON object with a `type`:

- `patch` (backend → runtime)
- `event` (runtime → backend)
- `clipboard` (backend → runtime)
- `config` (backend → runtime)

Top-level version field:

- `v` (integer, required) must appear on every message
- current protocol version is `1`
- receivers reject missing `v`
- `v` must equal `1`

Strictness policy:

- schema validation is strict (`additionalProperties: false` on message/event/node objects)
- unknown fields are rejected by the canonical schema
- canonical schema excludes compatibility aliases/quirks

### Patch (backend → runtime)

Full tree (replace root):

```json
{"type":"patch","v":1,"root":{"type":"vbox","id":"root","children":[]}}
```

Patch-by-id:

```json
{"type":"patch","v":1,"target":"clock","mode":"replace","node":{"type":"text","id":"clock","text":"Tick: 12"}}
```

Patch mode:

- `mode` is required and must be `replace` or `morph`
- `mode:"morph"` enables keyed morphing for container children (reorder/insert/remove)

```json
{"type":"patch","v":1,"target":"root","mode":"morph","node":{"type":"vbox","id":"root","children":[]}}
```

Optional patch sequencing:

```json
{"type":"patch","v":1,"seq":42,"target":"clock","mode":"replace","node":{"type":"text","id":"clock","text":"Tick: 42"}}
```

Notes:

- runtime treats `seq` as monotonic and drops stale patches (`seq <= last_seen_seq`)
- runtime continues rendering the last good tree when a patch is dropped/invalid

### Clipboard (backend → runtime)

Write:

```json
{"type":"clipboard","v":1,"op":"write","data":"copied text","target":"clipboard"}
```

Read:

```json
{"type":"clipboard","v":1,"op":"read","request_id":1,"target":"clipboard"}
```

Optional sequencing:

```json
{"type":"clipboard","v":1,"op":"read","request_id":1,"target":"clipboard","seq":101}
```

### Config (backend -> runtime)

Runtime keybindings can be replaced at runtime with a strict, replace-style message:

```json
{
  "type":"config",
  "v":1,
  "keybindings":{
    "global":[{"key":"Tab","action":"focus_next"}],
    "list":[{"key":"j","action":"list_next"},{"key":"k","action":"list_prev"}]
  }
}
```

Config can also switch the active runtime theme by setting a `theme_spec.base`:

```json
{"type":"config","v":1,"theme_spec":{"base":"light"}}
```

Optional sequencing:

```json
{"type":"config","v":1,"theme_spec":{"base":"light"},"seq":42}
```

Config can also install a dynamic selector-based theme spec:

```json
{"type":"config","v":1,"theme_spec":{"base":"default","vars":{"accent":"#38bdf8"},"rules":[{"selector":"box.button.primary:hover","style":{"bg":"$accent","bold":true}}]}}
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

`theme_spec`:

- `base` (optional): `default|light|ocean`; defaults to the currently active theme
- `vars` (optional): object map `name -> color`, where name matches `^[A-Za-z][A-Za-z0-9_]*$`
- `chrome` (optional): partial component chrome override (`input_prefix`, list markers, box glyphs, etc.)
- `overlays` (optional): optional style overrides for `disabled`, `readonly`, `focused`, `hovered`, `active`, `validation_error`, `validation_warning`, `validation_success`
- `rules` (optional): array of `{ "selector": string, "style": StyleOverride }`

Limits:

- `vars` max entries: `256`
- `rules` max entries: `2048`
- selector max length: `256`
- var name max length: `64`

Action names:

- focus/actions: `noop`, `focus_next`, `focus_prev`, `focus_scope_next`, `focus_scope_prev`, `focus_clear`, `action_activate`
- list: `list_prev`, `list_next`, `list_activate`
- scroll: `scroll_line_up`, `scroll_line_down`, `scroll_page_up`, `scroll_page_down`, `scroll_home`, `scroll_end`
- input: `input_left`, `input_right`, `input_word_left`, `input_word_right`, `input_home`, `input_end`, `input_delete`, `input_backspace`, `input_select_left`, `input_select_right`, `input_select_word_left`, `input_select_word_right`, `input_select_home`, `input_select_end`, `input_select_all`, `input_copy`, `input_paste`, `input_undo`, `input_redo`
- textarea: `textarea_left`, `textarea_right`, `textarea_up`, `textarea_down`, `textarea_word_left`, `textarea_word_right`, `textarea_home`, `textarea_end`, `textarea_page_up`, `textarea_page_down`, `textarea_delete`, `textarea_backspace`, `textarea_newline`, `textarea_select_left`, `textarea_select_right`, `textarea_select_up`, `textarea_select_down`, `textarea_select_word_left`, `textarea_select_word_right`, `textarea_select_home`, `textarea_select_end`, `textarea_select_all`, `textarea_copy`, `textarea_paste`, `textarea_undo`, `textarea_redo`

### Event (runtime → backend)

Startup handshake (sent once after runtime spawns backend):

```json
{"type":"event","v":1,"name":"hello","protocol_version":1,"caps":{"ansi":true,"alt_screen":true,"bracketed_paste":true,"mouse_sgr":true,"osc52":true,"color":"ansi256"},"limits":{"max_fps":30,"frame_interval_ns":33333333,"max_pending_targets":256,"max_backend_lines_per_iter":128,"queue_overflow":"drop_newest"}}
```

Notes:

- `protocol_version` is the runtime's protocol schema version
- `caps` advertises detected runtime/terminal capabilities
- `limits` advertises runtime scheduling/backpressure limits in effect

Key event:

```json
{"type":"event","v":1,"name":"key","key":"q"}
```

Focus changed:

```json
{"type":"event","v":1,"name":"focus","id":"query"}
```

Input changed:

```json
{"type":"event","v":1,"name":"input","id":"query","value":"hello","cursor":5}
```

List selection / activation:

```json
{"type":"event","v":1,"name":"select","id":"results","item":"row-2"}
{"type":"event","v":1,"name":"activate","id":"results","item":"row-2"}
```

For virtual lists (`type:"vlist"`), runtime also includes global row indices:

```json
{"type":"event","v":1,"name":"select","id":"results-vlist","item":"vrow-481","index":481}
{"type":"event","v":1,"name":"activate","id":"results-vlist","item":"vrow-481","index":481}
```

Virtual list range request (runtime -> backend):

```json
{"type":"event","v":1,"name":"vlist_range","id":"results-vlist","request_id":123,"start":480,"len":80,"scroll":500,"viewport_h":60,"overscan":10,"reason":"scroll"}
```

Scroll:

```json
{"type":"event","v":1,"name":"scroll","id":"viewport","scroll_y":12}
```

Resize:

```json
{"type":"event","v":1,"name":"resize","rows":24,"cols":80}
```

Hover / pointer (emitted only for nodes that opt in; see `hoverable`/`mouseable`):

```json
{"type":"event","v":1,"name":"hover","id":"btn-ok","x":10,"y":4,"item":null}
{"type":"event","v":1,"name":"pointer","kind":"down","id":"btn-ok","x":10,"y":4,"local_x":1,"local_y":0,"button":"left","buttons":1,"mods":0,"clicks":1,"scroll_dx":0,"scroll_dy":0,"captured":false}
```

When `item` is present, hover may include `index`, and pointer may include `item_index`.

Document selection commit (emitted on left mouse-up after local drag-selection over `text`/`styled_text`):

```json
{"type":"event","v":1,"name":"selection","id":"viewport","kind":"document","x0":10,"y0":4,"x1":22,"y1":7,"local_x0":0,"local_y0":0,"local_x1":12,"local_y1":3,"text":"selected text","bytes":13,"truncated":false}
```

`selection` rules:

- emitted only for document-style selection (read-only `text` / `styled_text`), not input/textarea
- runtime sends one commit event on left mouse-up (no per-move streaming)
- `id` is nearest scroll viewport id when present, otherwise the clicked text node id
- `text` is extracted from rendered cells, line-joined with `\n`, trailing spaces trimmed per line
- payload is capped at `16384` bytes; `truncated:true` indicates clipping

Clipboard result + paste semantic:

```json
{"type":"event","v":1,"name":"clipboard","op":"read","ok":true,"request_id":1,"data":"pasted"}
{"type":"event","v":1,"name":"paste","source":"clipboard","bytes":6}
```

Runtime error event (machine-readable runtime-side rejection):

```json
{"type":"event","v":1,"name":"error","code":"invalid_patch_shape","message":"backend patch rejected: invalid shape","seq":42,"context":"InvalidPatchShape"}
```

Config acknowledgement event (runtime config negotiation result):

```json
{"type":"event","v":1,"name":"config_ack","applied":["keybindings"],"rejected":[{"key":"theme_spec","reason":"UnknownThemeSpecBase"}]}
```

`config_ack` rules:

- runtime emits one `config_ack` for every backend `config` message attempt
- `applied` is an array of top-level keys that were accepted (`keybindings`, `theme_spec`)
- `rejected` is an array of `{ "key": string, "reason": string }`
- malformed config that cannot be mapped to a specific top-level key uses `key:"config"`
- keybindings are evaluated first; if keybindings fail, runtime rejects `theme_spec` in the same message with reason `keybindings_rejected`

Sequencing acknowledgement event:

```json
{"type":"event","v":1,"name":"ack","seq":42,"status":"queued","detail":"target"}
```

`ack` rules:

- runtime emits `ack` only for backend messages that include `seq`
- backend message types supporting `seq`: `patch`, `config`, `clipboard`
- `status` values:
  - `queued`: accepted into scheduler queue
  - `coalesced`: accepted and replaced an older pending target for the same id
  - `applied`: applied to runtime state (or processed immediately for clipboard/config)
  - `dropped_overflow`: dropped due to pending target overflow policy
  - `dropped_stale`: dropped because `seq` was older than the latest seen patch `seq`
  - `dropped_no_root`: dropped because a target patch arrived before any root/full state exists
  - `dropped_not_found`: dropped at apply-time because target id was not found in current tree
  - `ignored_invalid`: rejected by protocol/config validation
- `detail` is optional, runtime-provided context (examples: `full`, `target`, `queue_overflow`, `stale_seq`, `target_not_found`, parser error name)

Ordering + backpressure guidance:

- ack ordering is monotonic per runtime stdout stream; `queued` may arrive before a later terminal status for the same `seq` (`applied` or `dropped_*`)
- backends should bound in-flight `seq` messages (simple default: keep `<= max_pending_targets` patch messages in flight)
- when receiving `dropped_overflow`, reduce send rate or wait for more terminal acks before sending additional target patches

Optional runtime render/drop telemetry:

```json
{"type":"event","v":1,"name":"rendered","seq":42,"dropped":0,"bytes":512,"changed_cells":27}
{"type":"event","v":1,"name":"dropped","seq":41,"reason":"stale_seq"}
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
- collection: `list`, `vlist`

### Common fields (most nodes)

- `id` (string, required)
- `class` (string, optional, non-empty): theme class hook string; selector matching tokenizes by ASCII whitespace
- layout: `w`/`h` (int?), `flex` (int), `pad` (int), `clip` (bool)
- interaction/state: `hoverable` (bool), `mouseable` (bool), `focusable` (bool), `disabled` (bool), `readonly` (bool)
- focus scoping: `focus_scope` (string, optional, non-empty)
- validation: `validation` (`none|error|warning|success`)
- `style` (object, optional): style overrides

### Controlled State

State-capable widgets support `state_mode`:

- `uncontrolled` (default): runtime is source of truth for local widget state
- `init`: apply backend state once when the widget first appears
- `controlled`: backend is source of truth on every patch

Patch application rule:

- runtime never emits events just because a patch applied widget state
- runtime never auto-selects list items on patch; backend must set `selected_id` when selection is needed

State fields by widget:

- `input`: `value`, `cursor`, `scroll_x`, `selection_start`, `selection_end`
- `textarea`: `value`, `cursor`, `scroll_y`, `selection_start`, `selection_end`
- `list`: `selected_id`, `scroll`
- `vlist`: `selected_index`, `scroll`
- `scroll`: `scroll_y`

Examples:

Controlled input:

```json
{"type":"patch","v":1,"root":{"type":"input","id":"query","state_mode":"controlled","value":"hello","cursor":5}}
```

Controlled list selection:

```json
{"type":"patch","v":1,"root":{"type":"list","id":"results","state_mode":"controlled","selected_id":"row-2","children":[{"type":"text","id":"row-1","text":"A"},{"type":"text","id":"row-2","text":"B"}]}}
```

Controlled scroll viewport:

```json
{"type":"patch","v":1,"root":{"type":"scroll","id":"viewport","state_mode":"controlled","scroll_y":12,"child":{"type":"text","id":"body","text":"...content..."}}}
```

### Virtual List (`type:"vlist"`)

`vlist` represents a logical collection with backend-provided windows:

- required: `total`, `window_start`, `item_id_prefix`, `children`
- optional: `overscan` (default `10`), `req` (debug echo of fulfilled request id)
- runtime-local state: `selected_index`, `scroll` (same `state_mode` rules as other widgets)
- deterministic item id contract: item at global index `i` must have `id == item_id_prefix + i`

Range contract:

- runtime emits `event:vlist_range` when desired visible+overscan rows are not covered by current `children` window
- backend responds with a patch for that `vlist` id, updating `window_start` + `children`

`focus_scope` behavior:

- focus traversal (`focus_next` / `focus_prev`) is trapped within the currently focused node's scope
- `focus_scope_next` / `focus_scope_prev` jump across scope boundaries
- nodes without `focus_scope` are in the default global scope (omit the field)

### Styling (`style`)

`style` is a tri-state override object (inherit/clear/value). Example:

```json
{"type":"text","id":"status","text":"Connected","style":{"fg":"#00FF00","bold":true}}
```

`input`/`textarea` also accept `placeholder_style` and `selection_style`.

`fg` / `bg` accept:

- `#RRGGBB`
- named color
- `$var_name` (theme variable reference)

### Theme Selectors

Selector grammar (single compound selector, no combinators):

`[kind|*][#id]{.class_token}{:state}`

- kind: `vbox|hbox|grid|box|scroll|overlay|text|styled_text|input|textarea|list`
- states: `hover`, `focus`, `active`, `disabled`, `readonly`, `validation_error`, `validation_warning`, `validation_success`

Class matching:

- node `class` is split on ASCII whitespace into tokens
- selector class token matching uses dot-boundary prefix semantics
- `.button` matches token `button`, `button.primary`, `button.primary.large`
- `.button.primary` matches token `button.primary`, `button.primary.large`

### Grid (`type:"grid"`)

`grid` provides table-like layout without manual hbox/vbox nesting:

- track sizing:
  - fixed: number (example `10`)
  - auto: string `"auto"`
  - fractional: string `"<n>fr"` with `n >= 1` (example `"2fr"`)
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

## Schema Drift

For manual schema drift checks and traffic validation workflow, see `../SCHEMA_DRIFT.md`.
