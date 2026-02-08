# Development

## Build / run

```bash
zig build        # build all binaries
zig build demo   # run tui_runtime with backend_demo
zig build test   # run unit tests
zig build bench  # run synthetic perf benchmarks
```

## Logs / troubleshooting

- Default log path: `/tmp/tui_trace.log`
- Override: `TUI_LOG_PATH=...`
- Log to stderr: `TUI_LOG_STDERR=1` (or redirect `2>trace.log`)

If the terminal gets stuck after a crash, try `reset`.

## Performance tracing

- `TUI_PERF=1` logs per-iteration parse/scheduler/render timings.
- `TUI_MAX_FPS`, `TUI_MAX_PENDING_TARGETS`, `TUI_MAX_BACKEND_LINES_PER_ITER`, `TUI_QUEUE_OVERFLOW`
  tune runtime backpressure behavior.

## Unicode knobs

- `TUI_UNICODE_AMBIGUOUS_WIDTH=narrow|wide` (`narrow` default)
- `TUI_TAB_WIDTH=<n>` tab stop width for input/textarea/text layout (`4` default)
- `TUI_UNICODE_FAST_APPROX=1` opt into a faster approximation mode when needed

Notes:

- Wrapping/cursor/selection are grapheme-based.
- `\\r` is ignored; tabs expand to configured stops.
- Full bidi shaping/reordering is intentionally not implemented yet.

## Manual repro notes

`progress.json` includes slice-by-slice manual reproduction steps under `manual_repro`.
