const std = @import("std");

const tui = @import("tui");
const protocol = tui.protocol;
const render = tui.render;
const renderer_mod = tui.renderer;
const scheduler_mod = tui.scheduler;
const terminal = tui.terminal;
const clipboard = tui.clipboard;
const keys = tui.keys;
const key_decode = tui.key_decode;

const cmd = @import("cmd.zig");
const log = @import("log.zig");
const timing = @import("timing.zig");
const ui = @import("ui/mod.zig");
const pointer = @import("ui/pointer.zig");
const iomux_mod = @import("iomux.zig");

fn keyEventAsciiByte(ev: keys.KeyEvent) ?u8 {
    return switch (ev.key) {
        .text => |s| if (s.len == 1 and s[0] < 0x80) s[0] else null,
        else => null,
    };
}

fn keyEventIsCtrlLetter(ev: keys.KeyEvent, letter: u8) bool {
    if (!ev.mods.ctrl or ev.mods.alt or ev.mods.shift) return false;
    const b = keyEventAsciiByte(ev) orelse return false;
    return b == letter;
}

fn keyEventIsText(ev: keys.KeyEvent, b: u8) bool {
    if (ev.mods.ctrl or ev.mods.alt or ev.mods.shift) return false;
    const got = keyEventAsciiByte(ev) orelse return false;
    return got == b;
}

fn keyEventIsNamed(ev: keys.KeyEvent, k: keys.NamedKey) bool {
    return switch (ev.key) {
        .named => |kk| kk == k,
        else => false,
    };
}

fn isInputLocalKey(ev: keys.KeyEvent) bool {
    switch (ev.key) {
        .text => |s| {
            if (!ev.mods.alt and !ev.mods.ctrl and !ev.mods.shift) return true;
            if (ev.mods.alt and !ev.mods.ctrl and !ev.mods.shift and s.len == 1) {
                return s[0] == 'b' or s[0] == 'f';
            }
            return false;
        },
        .named => |k| switch (k) {
            .left, .right, .home, .end, .delete, .backspace, .insert => return !ev.mods.ctrl and !ev.mods.shift,
            else => return false,
        },
        else => return false,
    }
}

fn isListLocalKey(ev: keys.KeyEvent) bool {
    if (ev.mods.ctrl or ev.mods.alt or ev.mods.shift) return false;
    if (keyEventIsNamed(ev, .up) or keyEventIsNamed(ev, .down) or keyEventIsNamed(ev, .enter)) return true;
    const b = keyEventAsciiByte(ev) orelse return false;
    return b == 'j' or b == 'k';
}

fn isScrollLocalKey(ev: keys.KeyEvent) bool {
    if (ev.mods.ctrl or ev.mods.alt or ev.mods.shift) return false;
    if (keyEventIsNamed(ev, .page_up) or keyEventIsNamed(ev, .page_down) or keyEventIsNamed(ev, .home) or keyEventIsNamed(ev, .end)) return true;
    const b = keyEventAsciiByte(ev) orelse return false;
    return b == 'j' or b == 'k';
}

fn isTextareaLocalKey(ev: keys.KeyEvent) bool {
    switch (ev.key) {
        .text => return !ev.mods.ctrl and !ev.mods.shift,
        .named => |k| switch (k) {
            .left,
            .right,
            .up,
            .down,
            .home,
            .end,
            .page_up,
            .page_down,
            .delete,
            .backspace,
            .enter,
            => return !ev.mods.ctrl and !ev.mods.shift,
            else => return false,
        },
        else => return false,
    }
}

fn sendKeyEventToBackend(log_sink: *log.LogSink, backend_in: anytype, ev: keys.KeyEvent) !void {
    var fbuf: [4]u8 = undefined;
    const key_str = keys.keyToString(ev.key, &fbuf);
    const mods_mask = ev.mods.toMask();
    const seq: ?[]const u8 = switch (ev.key) {
        .unknown_escape => |s| s,
        else => null,
    };

    if (seq) |s| {
        log.logPrint(log_sink, "EVENT_TX name=key key={s} mods={d} seq_len={d}\n", .{ key_str, mods_mask, s.len });
    } else if (mods_mask != 0) {
        log.logPrint(log_sink, "EVENT_TX name=key key={s} mods={d}\n", .{ key_str, mods_mask });
    } else {
        log.logPrint(log_sink, "EVENT_TX name=key key={s}\n", .{key_str});
    }
    try protocol.writeKeyEventJsonlFull(backend_in, key_str, mods_mask, seq);
}

fn maybeSendPendingResizeEvent(
    log_sink: *log.LogSink,
    backend_in: anytype,
    pending_resize: *?terminal.Size,
    last_resize_tx_ns: *u64,
) !void {
    const sz = pending_resize.* orelse return;
    const now_ns = timing.monotonicNowNs();
    if (last_resize_tx_ns.* != 0 and now_ns < last_resize_tx_ns.* + timing.resize_debounce_ns) return;

    const rows: usize = @as(usize, sz.rows);
    const cols: usize = @as(usize, sz.cols);
    log.logPrint(log_sink, "EVENT_TX name=resize rows={d} cols={d}\n", .{ rows, cols });
    try protocol.writeResizeEventJsonl(backend_in, rows, cols);
    try backend_in.flush();
    last_resize_tx_ns.* = now_ns;
    pending_resize.* = null;
}

pub fn run() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd_argv = try cmd.parseCmdArgs(args);

    var term = terminal.Terminal.init(allocator, .{}) catch |e| {
        if (e == error.NotATty) {
            std.debug.print("tui_runtime: stdin and stdout must be a TTY (run interactively, not via a pipe)\n", .{});
            return;
        }
        return e;
    };
    var term_restored: bool = false;
    defer if (!term_restored) term.deinit();

    var log_sink = try log.initLogSink(allocator);
    defer log_sink.deinit();

    var renderer = renderer_mod.Renderer.initWithMode(allocator, term.caps().color);
    defer renderer.deinit();

    const resolved = try cmd.resolveCmdArgv(allocator, cmd_argv);
    defer {
        if (resolved.owned_cmd0) allocator.free(resolved.argv[0]);
        if (resolved.owned_argv) allocator.free(resolved.argv);
    }

    var child = std.process.Child.init(resolved.argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var wait_child: bool = true;
    defer {
        if (wait_child) {
            _ = child.wait() catch {};
        } else {
            _ = child.kill() catch {};
        }
    }

    const child_in_file = child.stdin orelse return error.Unexpected;
    const child_out_file = child.stdout orelse return error.Unexpected;
    const child_err_file = child.stderr orelse return error.Unexpected;

    var child_in_buf: [4096]u8 = undefined;
    var child_in_w = child_in_file.writerStreaming(&child_in_buf);
    const child_in = &child_in_w.interface;

    var current_arena = std.heap.ArenaAllocator.init(allocator);
    defer current_arena.deinit();
    var current_root: ?protocol.Node = null;

    var sched = scheduler_mod.Scheduler.init(allocator, timing.max_pending_targets);
    defer sched.deinit();
    var last_render_ns: u64 = 0;
    var last_sched_counts: scheduler_mod.Counts = sched.counts();

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(allocator);
    var focused_id: ?[]const u8 = null;
    var hover_id_buf: std.ArrayList(u8) = .empty;
    defer hover_id_buf.deinit(allocator);
    var hover_id: ?[]const u8 = null;
    var hover_item_buf: std.ArrayList(u8) = .empty;
    defer hover_item_buf.deinit(allocator);
    var hover_item: ?[]const u8 = null;
    var pointer_engine: pointer.PointerEngine = .{};
    defer pointer_engine.deinit(allocator);
    var last_mouse_x: usize = 0;
    var last_mouse_y: usize = 0;
    var have_last_mouse_pos: bool = false;
    var auto_focus_done: bool = false;
    var widgets: std.ArrayList(ui.WidgetEntry) = .empty;
    defer ui.deinitWidgetEntries(allocator, &widgets);
    var render_inputs: std.ArrayList(render.InputState) = .empty;
    defer render_inputs.deinit(allocator);
    var render_textareas: std.ArrayList(render.TextareaState) = .empty;
    defer render_textareas.deinit(allocator);
    var render_lists: std.ArrayList(render.ListState) = .empty;
    defer render_lists.deinit(allocator);
    var render_scrolls: std.ArrayList(render.ScrollState) = .empty;
    defer render_scrolls.deinit(allocator);

    var mux = try iomux_mod.IOMux.init(allocator, &term, child_out_file, child_err_file);
    defer mux.deinit();
    try mux.start();

    var last_term_size: terminal.Size = ui.effectiveTermSize(term.getSize() catch .{ .rows = 0, .cols = 0 });
    var pending_resize: ?terminal.Size = null;
    var last_resize_tx_ns: u64 = 0;
    var decoder = try key_decode.Decoder.init(allocator, .{});
    defer decoder.deinit();
    var emergency_last_ns: u64 = 0;
    const emergency_window_ns: u64 = 900 * std.time.ns_per_ms;

    const RenderReason = enum {
        input,
        resize,
        frame,
    };

    const ExitReason = union(enum) {
        normal,
        backend_closed,
        signal: iomux_mod.ExitSignal,
    };
    var exit_reason: ExitReason = .normal;

    while (true) {
        var requested_reason: ?RenderReason = null;
        var resize_changed_this_iter: bool = false;
        var handled_input_this_iter: bool = false;
        var exit_now: bool = false;

        const now_ns = timing.monotonicNowNs();
        const resize_timeout_ms = timing.pollTimeoutMsForPendingResize(pending_resize, last_resize_tx_ns);
        const frame_timeout_ms = timing.pollTimeoutMsForPendingFrame(now_ns, last_render_ns, sched.hasPending());
        const decoder_timeout_ms: i32 = blk: {
            const deadline_ns = decoder.nextDeadlineNs() orelse break :blk -1;
            if (now_ns >= deadline_ns) break :blk 0;
            const remaining_ns: u64 = deadline_ns - now_ns;
            const ms_u64: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
            const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
            break :blk @as(i32, @intCast(if (ms_u64 > max_i32) max_i32 else ms_u64));
        };
        const poll_timeout_ms = timing.minTimeoutMs(timing.minTimeoutMs(resize_timeout_ms, frame_timeout_ms), decoder_timeout_ms);
        const ev_opt = mux.recvTimeout(poll_timeout_ms);
        while (true) {
            const tick_ns = timing.monotonicNowNs();
            const decoded = decoder.tick(tick_ns) orelse break;
            switch (decoded) {
                .key => |ev| {
                    try sendKeyEventToBackend(&log_sink, child_in, ev);
                    try child_in.flush();
                    requested_reason = .input;
                },
                .paste => |p| log.logPrint(&log_sink, "PASTE_DROP reason=timeout bytes={d}\n", .{p.len}),
                .mouse => {},
            }
        }
        var sched_changed_live: bool = false;
        if (ev_opt) |ev| {
            switch (ev) {
                .backend_closed => {
                    log.logPrint(&log_sink, "BACKEND_CLOSED\n", .{});
                    exit_reason = .backend_closed;
                    wait_child = false;
                    exit_now = true;
                },
                .exit_signal => |sig| {
                    log.logPrint(&log_sink, "SIGNAL_RX name={s}\n", .{switch (sig) {
                        .sigint => "sigint",
                        .sigterm => "sigterm",
                        .ctrl_close => "ctrl_close",
                    }});
                    exit_reason = .{ .signal = sig };
                    wait_child = false;
                    exit_now = true;
                },
                .resize => |raw| {
                    const next_size = ui.effectiveTermSize(raw);
                    if (next_size.rows != last_term_size.rows or next_size.cols != last_term_size.cols) {
                        last_term_size = next_size;
                        log.logPrint(
                            &log_sink,
                            "RESIZE rows={d} cols={d}\n",
                            .{ @as(usize, next_size.rows), @as(usize, next_size.cols) },
                        );
                        pending_resize = next_size;
                        resize_changed_this_iter = true;
                        requested_reason = .resize;
                    }
                },
                .backend_stderr => |bytes| {
                    defer allocator.free(bytes);
                    if (bytes.len > 0) log.logWriteAll(&log_sink, bytes);
                },
                .backend_line => |line| {
                    defer allocator.free(line);

                    var next_arena = std.heap.ArenaAllocator.init(allocator);
                    defer next_arena.deinit();

                    const line_owned = next_arena.allocator().dupe(u8, line) catch |e| {
                        log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                        break;
                    };

                    const msg = protocol.parseMsgLeaky(next_arena.allocator(), line_owned) catch |e| {
                        if (e == error.UnknownPatchMode) {
                            log.logPrint(&log_sink, "PATCH_ERR reason=unknown_mode\n", .{});
                        } else {
                            log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                        }
                        break;
                    };

                    switch (msg) {
                        .patch => |p| switch (p) {
                            .full => |f| {
                                sched.putFullLeaky(&next_arena, f.root) catch |e| {
                                    log.logPrint(&log_sink, "SCHED_ERR reason={s}\n", .{@errorName(e)});
                                    break;
                                };
                                sched_changed_live = true;
                            },
                            .target => |t| {
                                if (current_root == null and !sched.hasPendingFull()) {
                                    log.logPrint(&log_sink, "SCHED_DROP reason=no_root target={s}\n", .{t.target});
                                    break;
                                }

                                const r = sched.putTargetLeaky(&next_arena, t.target, t.node, t.mode) catch |e| {
                                    log.logPrint(&log_sink, "SCHED_ERR reason={s}\n", .{@errorName(e)});
                                    break;
                                };
                                switch (r) {
                                    .dropped_overflow => log.logPrint(
                                        &log_sink,
                                        "SCHED_DROP reason=too_many_targets target={s}\n",
                                        .{t.target},
                                    ),
                                    else => sched_changed_live = true,
                                }
                            },
                        },
                        .clipboard => |c| {
                            switch (c) {
                                .write => |w| {
                                    const caps = term.caps();
                                    clipboard.writeText(&term, allocator, caps, .{}, w.data) catch |e| {
                                        const reason: []const u8 = switch (e) {
                                            error.Unsupported => "unsupported",
                                            error.TooLarge => "too_large",
                                            else => "system_failure",
                                        };
                                        try protocol.writeClipboardEventJsonl(child_in, .write, false, 0, null, reason);
                                        try child_in.flush();
                                        break;
                                    };
                                    try protocol.writeClipboardEventJsonl(child_in, .write, true, 0, null, null);
                                    try child_in.flush();
                                },
                                .read => |r| {
                                    const payload_owned = clipboard.readText(allocator) catch |e| {
                                        const reason: []const u8 = switch (e) {
                                            error.Unsupported => "unsupported",
                                            error.TooLarge => "too_large",
                                            else => "system_failure",
                                        };
                                        try protocol.writeClipboardEventJsonl(child_in, .read, false, r.request_id, null, reason);
                                        try child_in.flush();
                                        break;
                                    };
                                    defer allocator.free(payload_owned);

                                    const focused_kind: ?ui.FocusKind = blk: {
                                        const fid = focused_id orelse break :blk null;
                                        for (widgets.items) |w| {
                                            if (!std.mem.eql(u8, w.id.items, fid)) continue;
                                            break :blk switch (w.state) {
                                                .input => .input,
                                                .list => .list,
                                                .scroll => .scroll,
                                                .textarea => .textarea,
                                                .action => .action,
                                            };
                                        }
                                        break :blk null;
                                    };
                                    const focused_is_text_edit = focused_kind != null and (focused_kind.? == .input or focused_kind.? == .textarea);
                                    if (focused_is_text_edit and current_root != null and focused_id != null) {
                                        const rows: usize = @as(usize, last_term_size.rows);
                                        const cols: usize = @as(usize, last_term_size.cols);
                                        const changed = switch (focused_kind.?) {
                                            .input => blk: {
                                                var visible_cols: usize = ui.inputVisibleCols(cols);
                                                if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |rect| {
                                                    visible_cols = ui.inputVisibleCols(rect.w);
                                                }
                                                const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                                break :blk ui.handleFocusedInputPaste(
                                                    allocator,
                                                    &widgets,
                                                    focused_id.?,
                                                    payload_owned,
                                                    readonly,
                                                    visible_cols,
                                                );
                                            },
                                            .textarea => blk: {
                                                var visible_rows: usize = rows;
                                                var visible_cols: usize = cols;
                                                if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |rect| {
                                                    visible_rows = rect.h;
                                                    visible_cols = rect.w;
                                                }
                                                const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                                break :blk ui.handleFocusedTextareaPaste(
                                                    allocator,
                                                    &widgets,
                                                    focused_id.?,
                                                    payload_owned,
                                                    readonly,
                                                    visible_rows,
                                                    visible_cols,
                                                );
                                            },
                                            else => false,
                                        } catch |e| blk: {
                                            log.logPrint(&log_sink, "INPUT_PASTE_ERR reason={s}\n", .{@errorName(e)});
                                            break :blk false;
                                        };
                                        if (changed) {
                                            try ui.emitInputEventForId(&log_sink, child_in, widgets.items, focused_id.?);
                                            requested_reason = .input;
                                        }
                                    }

                                    try protocol.writeClipboardEventJsonl(child_in, .read, true, r.request_id, payload_owned, null);
                                    try protocol.writePasteEventJsonl(child_in, .clipboard, payload_owned.len);
                                    try child_in.flush();
                                },
                            }
                        },
                        else => {},
                    }
                },
                .stdin_bytes => |bytes| {
                    defer allocator.free(bytes);
                    const max_decoded_per_iter: usize = 256;
                    var processed: usize = 0;
                    var pending_input_event: bool = false;
                    var need_backend_flush: bool = false;

                    const focused_kind: ?ui.FocusKind = blk: {
                        const fid = focused_id orelse break :blk null;
                        for (widgets.items) |w| {
                            if (!std.mem.eql(u8, w.id.items, fid)) continue;
                            break :blk switch (w.state) {
                                .input => .input,
                                .list => .list,
                                .scroll => .scroll,
                                .textarea => .textarea,
                                .action => .action,
                            };
                        }
                        break :blk null;
                    };
                    const focused_is_text_edit = focused_kind != null and (focused_kind.? == .input or focused_kind.? == .textarea);

                    const byte_now_ns = timing.monotonicNowNs();
                    for (bytes) |b| {
                        if (processed >= max_decoded_per_iter) break;
                        const decoded = decoder.feedByte(b, byte_now_ns) orelse continue;
                        processed += 1;

                        switch (decoded) {
                            .mouse => |mev| if (current_root != null) {
                                if (mev.kind == .move and have_last_mouse_pos and mev.x == last_mouse_x and mev.y == last_mouse_y) {
                                    continue;
                                }
                                last_mouse_x = mev.x;
                                last_mouse_y = mev.y;
                                have_last_mouse_pos = true;
                                const rows: usize = @as(usize, last_term_size.rows);
                                const cols: usize = @as(usize, last_term_size.cols);
                                const changed = try ui.handleMouseEvent(
                                    allocator,
                                    &log_sink,
                                    child_in,
                                    &widgets,
                                    &focused_id_buf,
                                    &focused_id,
                                    &hover_id_buf,
                                    &hover_id,
                                    &hover_item_buf,
                                    &hover_item,
                                    current_root.?,
                                    rows,
                                    cols,
                                    mev,
                                );
                                const wrote_pointer = try pointer_engine.handleMouseEvent(
                                    allocator,
                                    child_in,
                                    widgets.items,
                                    current_root.?,
                                    rows,
                                    cols,
                                    mev,
                                    timing.monotonicNowNs(),
                                );
                                if (wrote_pointer) need_backend_flush = true;
                                if (changed) requested_reason = .input;
                                handled_input_this_iter = true;
                                continue;
                            } else {},
                            .paste => |payload| {
                                try protocol.writePasteEventJsonl(child_in, .bracketed, payload.len);
                                need_backend_flush = true;
                                if (focused_is_text_edit and current_root != null and focused_id != null and focused_kind != null) {
                                    const rows: usize = @as(usize, last_term_size.rows);
                                    const cols: usize = @as(usize, last_term_size.cols);
                                    const changed = switch (focused_kind.?) {
                                        .input => blk: {
                                            var visible_cols: usize = ui.inputVisibleCols(cols);
                                            if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |r| {
                                                visible_cols = ui.inputVisibleCols(r.w);
                                            }
                                            const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                            break :blk ui.handleFocusedInputPaste(
                                                allocator,
                                                &widgets,
                                                focused_id.?,
                                                payload,
                                                readonly,
                                                visible_cols,
                                            );
                                        },
                                        .textarea => blk: {
                                            var visible_rows: usize = rows;
                                            var visible_cols: usize = cols;
                                            if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |r| {
                                                visible_rows = r.h;
                                                visible_cols = r.w;
                                            }
                                            const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                            break :blk ui.handleFocusedTextareaPaste(
                                                allocator,
                                                &widgets,
                                                focused_id.?,
                                                payload,
                                                readonly,
                                                visible_rows,
                                                visible_cols,
                                            );
                                        },
                                        else => false,
                                    } catch |e| blk: {
                                        log.logPrint(&log_sink, "INPUT_PASTE_ERR reason={s}\n", .{@errorName(e)});
                                        break :blk false;
                                    };
                                    if (changed) {
                                        pending_input_event = true;
                                        requested_reason = .input;
                                    }
                                } else {
                                    log.logPrint(&log_sink, "PASTE_DROP reason=not_text_edit bytes={d}\n", .{payload.len});
                                }
                                continue;
                            },
                            .key => |kev| {
                                const key_now_ns = timing.monotonicNowNs();
                                if (emergency_last_ns != 0 and key_now_ns > emergency_last_ns + emergency_window_ns) {
                                    emergency_last_ns = 0;
                                }

                                if (keyEventIsCtrlLetter(kev, 'g')) {
                                    if (emergency_last_ns != 0 and key_now_ns <= emergency_last_ns + emergency_window_ns) {
                                        log.logPrint(&log_sink, "EMERGENCY_EXIT chord=ctrl-g ctrl-g\n", .{});
                                        _ = child.kill() catch {};
                                        terminal.emergencyExit(0);
                                    }
                                    emergency_last_ns = key_now_ns;
                                    continue;
                                }

                                if (!handled_input_this_iter and keyEventIsNamed(kev, .tab) and !kev.mods.alt and !kev.mods.ctrl) {
                                    if (current_root != null) {
                                        const dir: isize = if (kev.mods.shift) -1 else 1;
                                        const next_focus = try ui.cycleFocusInTreeDir(allocator, current_root.?, focused_id, dir);
                                        try ui.setFocusId(allocator, &focused_id_buf, &focused_id, next_focus);
                                    } else {
                                        try ui.setFocusId(allocator, &focused_id_buf, &focused_id, null);
                                    }
                                    log.logPrint(&log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id orelse ""});
                                    try protocol.writeFocusEventJsonl(child_in, focused_id orelse "");
                                    need_backend_flush = true;
                                    requested_reason = .input;
                                    continue;
                                }

                                if (!handled_input_this_iter and keyEventIsNamed(kev, .escape) and !kev.mods.alt and !kev.mods.ctrl and !kev.mods.shift) {
                                    if (focused_id != null) {
                                        try ui.setFocusId(allocator, &focused_id_buf, &focused_id, null);
                                        log.logPrint(&log_sink, "EVENT_TX name=focus id=\n", .{});
                                        try protocol.writeFocusEventJsonl(child_in, "");
                                        need_backend_flush = true;
                                        requested_reason = .input;
                                        continue;
                                    }
                                }

                                if (keyEventIsCtrlLetter(kev, 'c')) {
                                    try sendKeyEventToBackend(&log_sink, child_in, kev);
                                    need_backend_flush = true;
                                    continue;
                                }

                                var consumed: bool = false;
                                if (!handled_input_this_iter and focused_id != null and current_root != null and focused_kind != null) {
                                    switch (focused_kind.?) {
                                        .input => if (isInputLocalKey(kev)) {
                                            const rows: usize = @as(usize, last_term_size.rows);
                                            const cols: usize = @as(usize, last_term_size.cols);
                                            var visible_cols: usize = ui.inputVisibleCols(cols);
                                            if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |r| {
                                                visible_cols = ui.inputVisibleCols(r.w);
                                            }
                                            const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                            consumed = ui.handleFocusedInputKey(
                                                allocator,
                                                &widgets,
                                                focused_id.?,
                                                kev,
                                                readonly,
                                                visible_cols,
                                            ) catch false;
                                            if (consumed) {
                                                pending_input_event = true;
                                                requested_reason = .input;
                                                handled_input_this_iter = true;
                                            }
                                        },
                                        .list => if (isListLocalKey(kev)) {
                                            const rows: usize = @as(usize, last_term_size.rows);
                                            const cols: usize = @as(usize, last_term_size.cols);
                                            consumed = ui.handleFocusedListKey(
                                                allocator,
                                                &log_sink,
                                                child_in,
                                                &widgets,
                                                current_root.?,
                                                rows,
                                                cols,
                                                focused_id.?,
                                                kev,
                                            ) catch false;
                                            if (consumed) {
                                                requested_reason = .input;
                                                handled_input_this_iter = true;
                                                need_backend_flush = true;
                                            }
                                        },
                                        .scroll => if (isScrollLocalKey(kev)) {
                                            const rows: usize = @as(usize, last_term_size.rows);
                                            const cols: usize = @as(usize, last_term_size.cols);
                                            const changed = ui.handleFocusedScrollKey(
                                                allocator,
                                                &log_sink,
                                                child_in,
                                                &widgets,
                                                current_root.?,
                                                rows,
                                                cols,
                                                focused_id.?,
                                                kev,
                                            ) catch false;
                                            if (changed) {
                                                need_backend_flush = true;
                                                requested_reason = .input;
                                            }
                                            consumed = changed;
                                        },
                                        .textarea => if (isTextareaLocalKey(kev)) {
                                            const rows: usize = @as(usize, last_term_size.rows);
                                            const cols: usize = @as(usize, last_term_size.cols);
                                            var visible_rows: usize = rows;
                                            var visible_cols: usize = cols;
                                            if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |r| {
                                                visible_rows = r.h;
                                                visible_cols = r.w;
                                            }
                                            const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                            const changed = ui.handleFocusedTextareaKey(
                                                allocator,
                                                &widgets,
                                                focused_id.?,
                                                kev,
                                                readonly,
                                                visible_rows,
                                                visible_cols,
                                            ) catch false;
                                            if (changed) {
                                                pending_input_event = true;
                                                requested_reason = .input;
                                            }
                                            consumed = changed;
                                        },
                                        .action => {
                                            const pressed_space: bool = switch (kev.key) {
                                                .text => |s| s.len == 1 and s[0] == ' ' and !kev.mods.ctrl and !kev.mods.alt and !kev.mods.shift,
                                                else => false,
                                            };
                                            const pressed_enter: bool = keyEventIsNamed(kev, .enter) and !kev.mods.ctrl and !kev.mods.alt and !kev.mods.shift;
                                            if (pressed_space or pressed_enter) {
                                                consumed = true;
                                                try ui.activateActionForId(&log_sink, child_in, focused_id.?);
                                                need_backend_flush = true;
                                                requested_reason = .input;
                                            }
                                        },
                                    }
                                }

                                if (!consumed and !focused_is_text_edit) {
                                    try sendKeyEventToBackend(&log_sink, child_in, kev);
                                    need_backend_flush = true;
                                }
                            },
                        }
                    }

                    if (pending_input_event and focused_id != null) {
                        try ui.emitInputEventForId(&log_sink, child_in, widgets.items, focused_id.?);
                        need_backend_flush = true;
                    }
                    if (need_backend_flush) try child_in.flush();
                },
            }
        }

        if (sched_changed_live) {
            const c = sched.counts();
            if (!std.meta.eql(c, last_sched_counts)) {
                log.logPrint(
                    &log_sink,
                    "SCHED_PENDING full={s} targets={d} coalesced_full={d} coalesced_targets={d} dropped={d}\n",
                    .{
                        if (c.pending_full) "true" else "false",
                        c.pending_targets,
                        c.coalesced_full,
                        c.coalesced_targets,
                        c.dropped_targets,
                    },
                );
                last_sched_counts = c;
            }
        }

        if (exit_now) break;

        try maybeSendPendingResizeEvent(&log_sink, child_in, &pending_resize, &last_resize_tx_ns);

        const now_after = timing.monotonicNowNs();
        if (requested_reason == null and timing.pollTimeoutMsForPendingFrame(now_after, last_render_ns, sched.hasPending()) == 0) {
            requested_reason = .frame;
        }

        if (requested_reason) |reason| {
            const flush_res = if (sched.hasPending())
                try sched.flushApplyLeaky(allocator, &current_arena, &current_root)
            else
                scheduler_mod.FlushResult{ .dropped_targets = sched.counts().dropped_targets };

            if (current_root != null) {
                const rows: usize = @as(usize, last_term_size.rows);
                const cols: usize = @as(usize, last_term_size.cols);
                const has_hoverables = ui.treeHasHoverables(current_root.?);
                const has_mouseables = tui.mouseable.treeHasMouseables(current_root.?);
                const mouse_needed = has_hoverables or has_mouseables;
                const motion_needed = has_hoverables or has_mouseables;
                if (mouse_needed) {
                    try term.enableMouseBase();
                    if (motion_needed) {
                        try term.enableMouseMotionAny();
                    } else {
                        try term.disableMouseMotionAny();
                    }
                } else {
                    try term.disableMouseMotionAny();
                    try term.disableMouseMotionWhileButton();
                    try term.disableMouseBase();
                }

                try ui.syncUiAfterPatch(
                    allocator,
                    &log_sink,
                    child_in,
                    &widgets,
                    &focused_id_buf,
                    &focused_id,
                    &auto_focus_done,
                    current_root.?,
                    rows,
                    cols,
                );

                // If the tree changes under the pointer (morph patches, modals, etc), refresh hover once.
                const hover_x_opt: ?usize = if (have_last_mouse_pos) last_mouse_x else null;
                const hover_y_opt: ?usize = if (have_last_mouse_pos) last_mouse_y else null;
                if (try ui.refreshHoverAfterPatch(
                    allocator,
                    &log_sink,
                    child_in,
                    widgets.items,
                    &hover_id_buf,
                    &hover_id,
                    &hover_item_buf,
                    &hover_item,
                    current_root.?,
                    rows,
                    cols,
                    hover_x_opt,
                    hover_y_opt,
                )) {
                    // fall through; flushed below
                }
                if (try pointer_engine.refreshAfterPatch(
                    allocator,
                    child_in,
                    widgets.items,
                    current_root.?,
                    rows,
                    cols,
                    hover_x_opt,
                    hover_y_opt,
                )) {
                    // fall through; flushed below
                }
                pointer_engine.pruneAfterPatch(current_root.?);
                try child_in.flush();

                if (resize_changed_this_iter) {
                    ui.clampLocalStateForResize(&widgets, current_root.?, last_term_size);
                }

                const rs = try ui.buildRenderState(
                    allocator,
                    widgets.items,
                    &render_inputs,
                    &render_textareas,
                    &render_lists,
                    &render_scrolls,
                    focused_id,
                    hover_id,
                    hover_item,
                    pointer_engine.activeId(),
                );
                try renderer.drawWithCaps(&term, term.caps(), current_root.?, rs);
                last_render_ns = timing.monotonicNowNs();

                log.logPrint(
                    &log_sink,
                    "RENDER reason={s} targets_applied={d} dropped={d} bytes={d} changed_cells={d} cursor_moves={d}\n",
                    .{
                        switch (reason) {
                            .input => "input",
                            .resize => "resize",
                            .frame => "frame",
                        },
                        flush_res.targets_applied,
                        flush_res.dropped_targets,
                        renderer.last_metrics.bytes,
                        renderer.last_metrics.changed_cells,
                        renderer.last_metrics.cursor_moves,
                    },
                );
            }
        }
    }

    if (!term_restored) {
        term.deinit();
        term_restored = true;
    }

    switch (exit_reason) {
        .signal => |sig| log.logPrint(&log_sink, "EXIT reason=signal name={s}\n", .{switch (sig) {
            .sigint => "sigint",
            .sigterm => "sigterm",
            .ctrl_close => "ctrl_close",
        }}),
        .backend_closed => log.logPrint(&log_sink, "EXIT reason=backend_closed\n", .{}),
        .normal => {},
    }
}
