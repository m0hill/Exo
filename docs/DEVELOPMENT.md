# Development

## Build / run

```bash
zig build        # build all binaries
zig build demo   # run tui_runtime with backend_demo
zig build test   # run unit tests
```

## Logs / troubleshooting

- Default log path: `/tmp/tui_trace.log`
- Override: `TUI_LOG_PATH=...`
- Log to stderr: `TUI_LOG_STDERR=1` (or redirect `2>trace.log`)

If the terminal gets stuck after a crash, try `reset`.

## Manual repro notes

`progress.json` includes slice-by-slice manual reproduction steps under `manual_repro`.

