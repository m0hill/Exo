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

### Clipboard (backend → runtime)

Write:

```json
{"type":"clipboard","op":"write","data":"copied text","target":"clipboard"}
```

Read:

```json
{"type":"clipboard","op":"read","request_id":1,"target":"clipboard"}
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

## Nodes

Nodes form a tree. Every node has a required `id` and a `type`.

Node types (current):

- containers: `vbox`, `hbox`, `box`, `scroll`, `overlay`
- text: `text`, `styled_text`
- inputs: `input`, `textarea`
- collection: `list`

### Common fields (most nodes)

- `id` (string, required)
- layout: `w`/`h` (int?), `flex` (int), `pad` (int), `clip` (bool)
- interaction/state: `hoverable` (bool), `mouseable` (bool), `focusable` (bool), `disabled` (bool), `readonly` (bool)
- validation: `validation` (`none|error|warning|success`)
- `style` (object, optional): style overrides

### Styling (`style`)

`style` is a tri-state override object (inherit/clear/value). Example:

```json
{"type":"text","id":"status","text":"Connected","style":{"fg":"#00FF00","bold":true}}
```

`input`/`textarea` also accept `placeholder_style`.

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
