# `Exo` (Zig) — terminal UI over JSONL

`Exo` is a small TUI runtime + library for building terminal UIs where a backend process emits
newline-delimited JSON (**JSONL**) patches and receives input/focus/pointer events back.

**Why use it**

- Keep UI logic in your backend (any language) and stream UI updates over pipes.
- Fast terminal rendering (frame diffing + optional morph patches).
- Capability-gated terminal features (degrades gracefully across terminals).

**What’s in this repo**

- `tui_runtime`: runs in a real TTY, renders patches, sends events back to the backend
- `backend_demo`: demo backend that drives `tui_runtime`
- `src/lib`: the reusable Zig library (`tui` module) including protocol, renderer, markdown, widget helpers

**Quick start**

```bash
zig build demo
zig build test
```

**Docs**

- `docs/PROTOCOL.md` — JSONL protocol, node schema, styling, terminal caps/env overrides
- `docs/DEVELOPMENT.md` — build/run tips, logging, troubleshooting

