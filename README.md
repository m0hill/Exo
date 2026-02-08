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
zig build bench
```

**Docs**

- `docs/PROTOCOL.md` — JSONL protocol, node schema, styling, terminal caps/env overrides
- `protocol.schema.json` — canonical JSON Schema artifact for JSONL message validation/SDK generation
- `SCHEMA_DRIFT.md` — manual checklist for schema drift + real-traffic validation
- `docs/DEVELOPMENT.md` — build/run tips, logging, troubleshooting
- `docs/PERFORMANCE.md` — benchmark workloads, perf targets, runtime tuning knobs

## Unicode/Text Guarantees

- Grapheme-aware editing/rendering (cursor movement, selection, wrapping) for modern UTF-8 text.
- Width calculation follows terminal-style Unicode width behavior, including emoji ZWJ/flags/modifiers and variation selectors.
- `\\r` is ignored for layout/editing; `\\t` expands to tab stops (default 4 columns).
- Ambiguous East Asian width defaults to narrow (`1` cell), configurable to wide (`2` cells).
- Out of scope (for now): full bidi reordering/shaping and terminal-font-specific glyph shaping quirks.
