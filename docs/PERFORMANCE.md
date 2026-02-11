# Performance + Scalability

## Targets

The synthetic bench harness tracks these representative workloads:

- `full_tree_patch_30fps`: average frame time <= `33ms`
- `small_target_patch`: average frame time <= `4ms`
- `huge_list_target_patch`: average frame time <= `8ms`
- `heavy_markdown`: average frame time <= `20ms`
- `protocol_parse_large_patch`: average parse time <= `6ms`

Run:

```bash
zig build bench
zig build bench -- --iters 200
```

## Harness

- Bench executable: `src/test/bench.zig`
- Build task: `zig build bench`
- Uses `src/test/testing_terminal.zig` (no real TTY)
- Uses synthetic full patches, target patches, large lists, markdown compilation, and large patch JSON parsing

## Runtime Knobs

Runtime supports environment-controlled backpressure/coalescing behavior:

- `TUI_MAX_FPS` (default `30`)
- `TUI_MAX_PENDING_TARGETS` (default `256`)
- `TUI_MAX_BACKEND_LINES_PER_ITER` (default `128`)
- `TUI_QUEUE_OVERFLOW` (`drop_newest` default, or `drop_oldest`)
- `TUI_PERF=1` enables per-iteration perf logs
- `TUI_EMIT_RENDER_EVENTS=1` enables `rendered` / `dropped` protocol events

## Instrumentation

When `TUI_PERF=1`, runtime logs include:

- parse time (`parse_ns`), lines, and bytes
- scheduler flush time (`sched_flush_ns`)
- renderer layout+paint-to-frame time (`render_to_frame_ns`)
- terminal diff/write time (`diff_flush_ns`)
- bytes written and changed cells

Renderer metrics are surfaced through `Renderer.last_metrics`.

## Tree and Layout Caches

- Patch application can use a retained `id -> path` index (`tree.IdIndex`) to avoid repeated full-tree recursive walks.
- Runtime pointer/hover hit-testing now uses a retained layout lookup cache (`render.LayoutCache`) for repeated `id -> rect` queries within an iteration.

## Sequencing / Acks

- Backend patches may include optional `seq`.
- Runtime drops stale sequences (`<=` last seen sequence) and can emit:
  - `{"type":"event","name":"dropped",...}`
  - `{"type":"event","name":"rendered",...}`

## Large Collections Strategy

Implemented virtualization strategy:

- Use `type:"vlist"` for very large collections (`total` rows).
- Runtime keeps local `scroll`/selection and requests needed windows via `event:vlist_range`.
- Backend responds with targeted morph patches for that `vlist` id (`window_start` + `children`).
- Keep child ids deterministic (`item_id_prefix + index`) so hover/select/activate stay stable.
- Prefer targeted patching (`patch` with `target`) over full snapshots whenever possible.
