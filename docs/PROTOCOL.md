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

Rules:

- each rule is `{ "key": string, "mods": number (optional, default 0), "action": string }`
- `mods` uses the runtime bitmask: `shift=1`, `ctrl=2`, `alt=4`
- contexts are optional: `global`, `input`, `textarea`, `list`, `scroll`, `action`
- omitted contexts keep runtime defaults
- explicit empty arrays clear defaults for that context
- matching is exact (`key` + `mods`), context-first and then `global`
- malformed rules reject the entire config message

Action names:

- focus/actions: `noop`, `focus_next`, `focus_prev`, `focus_scope_next`, `focus_scope_prev`, `focus_clear`, `action_activate`
- list: `list_prev`, `list_next`, `list_activate`
- scroll: `scroll_line_up`, `scroll_line_down`, `scroll_page_up`, `scroll_page_down`, `scroll_home`, `scroll_end`
- input: `input_left`, `input_right`, `input_word_left`, `input_word_right`, `input_home`, `input_end`, `input_delete`, `input_backspace`
- textarea: `textarea_left`, `textarea_right`, `textarea_up`, `textarea_down`, `textarea_word_left`, `textarea_word_right`, `textarea_home`, `textarea_end`, `textarea_page_up`, `textarea_page_down`, `textarea_delete`, `textarea_backspace`, `textarea_newline`

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
- focus scoping: `focus_scope` (string, optional; alias `focus_group` accepted on input)
- validation: `validation` (`none|error|warning|success`)
- `style` (object, optional): style overrides

`focus_scope` behavior:

- focus traversal (`focus_next` / `focus_prev`) is trapped within the currently focused node's scope
- `focus_scope_next` / `focus_scope_prev` jump across scope boundaries
- nodes without `focus_scope` are in the default global scope (`null`)

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
