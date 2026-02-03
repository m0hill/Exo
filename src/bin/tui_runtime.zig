const std = @import("std");

const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;
const render = tui.render;
const renderer_mod = tui.renderer;
const scheduler_mod = tui.scheduler;
const terminal = tui.terminal;
const input = tui.input;
const unicode = tui.unicode;
const mouse = tui.mouse;
const state = tui.state;
const tree = tui.tree;

var winch_w_fd: std.posix.fd_t = -1;

fn sigwinchHandler(_: c_int) callconv(.c) void {
    if (winch_w_fd < 0) return;
    const b: [1]u8 = .{0};
    _ = std.posix.system.write(winch_w_fd, &b, 1);
}

fn setFdNonBlocking(fd: std.posix.fd_t) void {
    var fl_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    fl_flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl_flags) catch return;
}

fn installSigwinchHandler() void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = sigwinchHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sa, null);
}

fn drainPipe(fd: std.posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch |e| switch (e) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
    }
}

const LogSink = struct {
    file: ?std.fs.File = null,

    pub fn deinit(self: *LogSink) void {
        if (self.file) |f| f.close();
        self.file = null;
    }
};

fn envString(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };
}

fn envFlag(allocator: std.mem.Allocator, name: []const u8) bool {
    const v = envString(allocator, name) orelse return false;
    defer allocator.free(v);
    return v.len > 0 and (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"));
}

fn initLogSink(allocator: std.mem.Allocator) !LogSink {
    if (envFlag(allocator, "TUI_LOG_STDERR")) return .{};

    if (!std.posix.isatty(std.posix.STDERR_FILENO)) return .{};

    const path_owned = envString(allocator, "TUI_LOG_PATH");
    defer if (path_owned) |p| allocator.free(p);
    const path = if (path_owned) |p| p else "/tmp/tui_trace.log";
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    return .{ .file = f };
}

fn logPrint(sink: *LogSink, comptime fmt: []const u8, args: anytype) void {
    if (sink.file) |f| {
        var buf: [4096]u8 = undefined;
        var w = f.writerStreaming(&buf);
        w.interface.print(fmt, args) catch {};
        w.interface.flush() catch {};
        return;
    }
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn logWriteAll(sink: *LogSink, bytes: []const u8) void {
    if (sink.file) |f| {
        var buf: [4096]u8 = undefined;
        var w = f.writerStreaming(&buf);
        w.interface.writeAll(bytes) catch {};
        w.interface.flush() catch {};
        return;
    }
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.writeAll(bytes) catch {};
    w.interface.flush() catch {};
}

fn logRender(sink: *LogSink, m: renderer_mod.DrawMetrics) void {
    logPrint(
        sink,
        "RENDER full={s} reason=unknown bytes={d} changed_cells={d} cursor_moves={d}\n",
        .{ if (m.full) "true" else "false", m.bytes, m.changed_cells, m.cursor_moves },
    );
}

fn logRenderReason(sink: *LogSink, reason: []const u8, m: renderer_mod.DrawMetrics) void {
    logPrint(
        sink,
        "RENDER full={s} reason={s} bytes={d} changed_cells={d} cursor_moves={d}\n",
        .{ if (m.full) "true" else "false", reason, m.bytes, m.changed_cells, m.cursor_moves },
    );
}

fn monotonicNowNs() u64 {
    const t = std.time.nanoTimestamp();
    if (t <= 0) return 0;
    return @as(u64, @intCast(t));
}

const resize_debounce_ns: u64 = 100 * std.time.ns_per_ms;
const backend_frame_interval_ns: u64 = 33 * std.time.ns_per_ms;
const max_pending_targets: usize = 256;
const max_backend_lines_per_iter: usize = 128;

fn minTimeoutMs(a: i32, b: i32) i32 {
    if (a < 0) return b;
    if (b < 0) return a;
    return if (a < b) a else b;
}

fn pollTimeoutMsForPendingFrame(now_ns: u64, last_render_ns: u64, has_pending: bool) i32 {
    if (!has_pending) return -1;
    if (last_render_ns == 0) return 0;
    const deadline = last_render_ns + backend_frame_interval_ns;
    if (now_ns >= deadline) return 0;
    const remaining_ns: u64 = deadline - now_ns;
    const ms: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
    return @as(i32, @intCast(if (ms > max_i32) max_i32 else ms));
}

fn pollTimeoutMsForPendingResize(pending_resize: ?terminal.Size, last_resize_tx_ns: u64) i32 {
    if (pending_resize == null) return -1;
    const now_ns = monotonicNowNs();
    if (last_resize_tx_ns == 0) return 0;
    const deadline = last_resize_tx_ns + resize_debounce_ns;
    if (now_ns >= deadline) return 0;
    const remaining_ns: u64 = deadline - now_ns;
    const ms: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
    return @as(i32, @intCast(if (ms > max_i32) max_i32 else ms));
}

fn maybeSendPendingResizeEvent(
    log_sink: *LogSink,
    backend_in: anytype,
    pending_resize: *?terminal.Size,
    last_resize_tx_ns: *u64,
) !void {
    const sz = pending_resize.* orelse return;
    const now_ns = monotonicNowNs();
    if (last_resize_tx_ns.* != 0 and now_ns < last_resize_tx_ns.* + resize_debounce_ns) return;

    const rows: usize = @as(usize, sz.rows);
    const cols: usize = @as(usize, sz.cols);
    logPrint(log_sink, "EVENT_TX name=resize rows={d} cols={d}\n", .{ rows, cols });
    try protocol.writeResizeEventJsonl(backend_in, rows, cols);
    try backend_in.flush();
    last_resize_tx_ns.* = now_ns;
    pending_resize.* = null;
}

fn effectiveTermSize(sz: terminal.Size) terminal.Size {
    var rows = sz.rows;
    var cols = sz.cols;
    if (rows == 0) rows = 24;
    if (cols == 0) cols = 80;
    return .{ .rows = rows, .cols = cols };
}

fn inputVisibleCols(cols: usize) usize {
    const prefix_len: usize = 2; // "> "
    if (cols <= prefix_len) return 0;
    return cols - prefix_len;
}

fn clampLocalStateForResize(widgets: *std.ArrayList(WidgetEntry), root: protocol.Node, size: terminal.Size) void {
    const eff = effectiveTermSize(size);
    const rows: usize = @as(usize, eff.rows);
    const cols: usize = @as(usize, eff.cols);

    for (widgets.items) |*e| {
        switch (e.state) {
            .input => |*s| {
                s.cursor = @min(s.cursor, s.value.items.len);
                if (s.scroll_x > s.value.items.len) s.scroll_x = s.value.items.len;

                var visible_cols: usize = inputVisibleCols(cols);
                if (render.findRectForId(root, rows, cols, e.id.items)) |r| {
                    visible_cols = inputVisibleCols(r.w);
                }
                _ = input.ensure_cursor_visible(&s.scroll_x, s.cursor, s.value.items, visible_cols);
            },
            .list => {},
        }
    }

    for (widgets.items) |*e| {
        switch (e.state) {
            .list => {
                const list_id = e.id.items;
                const l = findListNodeById(root, list_id) orelse continue;
                var visible_height: usize = 0;

                if (render.findRectForId(root, rows, cols, list_id)) |r| {
                    visible_height = r.h;
                    const desired: usize = l.height orelse visible_height;
                    visible_height = @min(desired, visible_height);
                } else {
                    visible_height = l.height orelse rows;
                }

                clampListScrollForNode(widgets, l, visible_height);
            },
            else => {},
        }
    }
}

fn clampListScrollForNode(widgets: *std.ArrayList(WidgetEntry), l: protocol.ListNode, visible_height: usize) void {
    const idx = findWidgetIndex(widgets.items, l.id) orelse return;
    var st = &widgets.items[idx].state.list;

    var selected_index: ?usize = null;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                selected_index = child_idx;
                break;
            }
        }
    }

    st.scroll = state.clampListScroll(st.scroll, selected_index, visible_height, l.children.len);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd_argv = try parseCmdArgs(args);

    var term = terminal.Terminal.init() catch |e| {
        if (e == error.NotATty) {
            std.debug.print("tui_runtime: stdin and stdout must be a TTY (run interactively, not via a pipe)\n", .{});
            return;
        }
        return e;
    };
    defer term.deinit();

    var log_sink = try initLogSink(allocator);
    defer log_sink.deinit();

    var renderer = renderer_mod.Renderer.init(allocator);
    defer renderer.deinit();

    const resolved = try resolveCmdArgv(allocator, cmd_argv);
    defer {
        if (resolved.owned_cmd0) allocator.free(resolved.argv[0]);
        if (resolved.owned_argv) allocator.free(resolved.argv);
    }

    var child = std.process.Child.init(resolved.argv, allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    defer {
        _ = child.wait() catch {};
    }

    const child_in_file = child.stdin orelse return error.Unexpected;
    const child_out_file = child.stdout orelse return error.Unexpected;
    const child_err_file = child.stderr orelse return error.Unexpected;

    var child_in_buf: [4096]u8 = undefined;
    var child_in_w = child_in_file.writerStreaming(&child_in_buf);
    const child_in = &child_in_w.interface;

    var child_out_buf: [4096]u8 = undefined;
    var child_out_r = child_out_file.readerStreaming(&child_out_buf);
    var patch_lr = jsonl.LineReader.init(allocator, &child_out_r.interface, 1024 * 1024);
    defer patch_lr.deinit();

    var current_arena = std.heap.ArenaAllocator.init(allocator);
    defer current_arena.deinit();
    var current_root: ?protocol.Node = null;

    var sched = scheduler_mod.Scheduler.init(allocator, max_pending_targets);
    defer sched.deinit();
    var last_render_ns: u64 = 0;
    var last_sched_counts: scheduler_mod.Counts = sched.counts();

    var focused_id_buf: std.ArrayList(u8) = .empty;
    defer focused_id_buf.deinit(allocator);
    var focused_id: ?[]const u8 = null;
    var auto_focus_done: bool = false;
    var widgets: std.ArrayList(WidgetEntry) = .empty;
    defer deinitWidgetEntries(allocator, &widgets);
    var render_inputs: std.ArrayList(render.InputState) = .empty;
    defer render_inputs.deinit(allocator);
    var render_lists: std.ArrayList(render.ListState) = .empty;
    defer render_lists.deinit(allocator);

    const backend_out_fd = child_out_file.handle;
    const backend_err_fd = child_err_file.handle;
    const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

    const winch_pipe = try std.posix.pipe();
    const winch_r_fd: std.posix.fd_t = winch_pipe[0];
    const winch_w_local: std.posix.fd_t = winch_pipe[1];
    defer {
        std.posix.close(winch_r_fd);
        std.posix.close(winch_w_local);
    }
    setFdNonBlocking(winch_r_fd);
    setFdNonBlocking(winch_w_local);
    winch_w_fd = winch_w_local;
    defer winch_w_fd = -1;
    installSigwinchHandler();

    var last_term_size: terminal.Size = effectiveTermSize(term.getSize() catch .{ .rows = 0, .cols = 0 });
    var pending_resize: ?terminal.Size = null;
    var last_resize_tx_ns: u64 = 0;
    var utf8_pending: Utf8Pending = .{};
    var csi_pending: CsiPending = .{};

    const RenderReason = enum {
        input,
        resize,
        frame,
    };

    while (true) {
        var requested_reason: ?RenderReason = null;
        var resize_changed_this_iter: bool = false;

        const now_ns = monotonicNowNs();
        const resize_timeout_ms = pollTimeoutMsForPendingResize(pending_resize, last_resize_tx_ns);
        const frame_timeout_ms = pollTimeoutMsForPendingFrame(now_ns, last_render_ns, sched.hasPending());
        const poll_timeout_ms = minTimeoutMs(resize_timeout_ms, frame_timeout_ms);

        const backend_events: i16 = if (frame_timeout_ms > 0 and sched.hasPending()) 0 else std.posix.POLL.IN;

        var fds = [_]std.posix.pollfd{
            .{ .fd = backend_out_fd, .events = backend_events, .revents = 0 },
            .{ .fd = backend_err_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = winch_r_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const rc = try std.posix.poll(fds[0..], poll_timeout_ms);
        if (rc == 0) {
            // Debounced resize event and/or frame tick.
            try maybeSendPendingResizeEvent(&log_sink, child_in, &pending_resize, &last_resize_tx_ns);
        } else {
            if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
                break;
            }

            if ((fds[3].revents & std.posix.POLL.IN) != 0) {
                drainPipe(winch_r_fd);
                const next_size_raw = term.getSize() catch last_term_size;
                const next_size = effectiveTermSize(next_size_raw);
                if (next_size.rows != last_term_size.rows or next_size.cols != last_term_size.cols) {
                    last_term_size = next_size;
                    logPrint(
                        &log_sink,
                        "RESIZE rows={d} cols={d}\n",
                        .{ @as(usize, next_size.rows), @as(usize, next_size.cols) },
                    );
                    pending_resize = next_size;
                    resize_changed_this_iter = true;
                    requested_reason = .resize;
                }
            }

            if ((fds[1].revents & std.posix.POLL.IN) != 0) {
                var buf: [4096]u8 = undefined;
                const n = std.posix.read(backend_err_fd, &buf) catch 0;
                if (n > 0) logWriteAll(&log_sink, buf[0..n]);
            }

            if ((fds[2].revents & std.posix.POLL.IN) != 0) {
                const first = try term.readByte();
                const decoded = try decodeKeyWithUtf8(&term, &utf8_pending, &csi_pending, first) orelse continue;

                if (decoded == .mouse and current_root != null) {
                    const rows: usize = @as(usize, last_term_size.rows);
                    const cols: usize = @as(usize, last_term_size.cols);
                    const changed = try handleMouseEvent(
                        allocator,
                        &log_sink,
                        child_in,
                        &widgets,
                        &focused_id_buf,
                        &focused_id,
                        current_root.?,
                        rows,
                        cols,
                        decoded.mouse,
                    );
                    if (changed) requested_reason = .input;
                    continue;
                }

                if (decoded == .tab or decoded == .shift_tab) {
                    if (current_root != null) {
                        const next_focus = try cycleFocusInTree(allocator, current_root.?, focused_id);
                        try setFocusId(allocator, &focused_id_buf, &focused_id, next_focus);
                    } else {
                        try setFocusId(allocator, &focused_id_buf, &focused_id, null);
                    }
                    logPrint(&log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id orelse ""});
                    try protocol.writeFocusEventJsonl(child_in, focused_id orelse "");
                    try child_in.flush();
                    requested_reason = .input;
                } else {
                    // Always allow exit keys.
                    if (decoded == .byte and decoded.byte == 3) {
                        logPrint(&log_sink, "EVENT_TX name=key key=ctrl-c\n", .{});
                        try protocol.writeKeyEventJsonl(child_in, "ctrl-c");
                        try child_in.flush();
                        break;
                    }
                    if (decoded == .byte and decoded.byte == 'x') {
                        logPrint(&log_sink, "EVENT_TX name=key key=x\n", .{});
                        try protocol.writeKeyEventJsonl(child_in, "x");
                        try child_in.flush();
                        break;
                    }

                    if (decoded == .byte and decoded.byte == 'q') {
                        logPrint(&log_sink, "EVENT_TX name=key key=q\n", .{});
                        try protocol.writeKeyEventJsonl(child_in, "q");
                        try child_in.flush();
                    } else if (current_root != null and focused_id != null) {
                        const fk = try focusedKindInTree(allocator, current_root.?, focused_id.?);
                        if (fk) |kind| switch (kind) {
                            .list => {
                                if (decoded == .byte and (decoded.byte == 'j' or decoded.byte == 'k')) {
                                    const delta: isize = if (decoded.byte == 'j') 1 else -1;
                                    const changed = try moveListSelectionForId(
                                        allocator,
                                        &log_sink,
                                        child_in,
                                        &widgets,
                                        current_root.?,
                                        focused_id.?,
                                        delta,
                                    );
                                    if (changed) {
                                        try child_in.flush();
                                        requested_reason = .input;
                                    }
                                } else if (decoded == .byte and (decoded.byte == '\r' or decoded.byte == '\n')) {
                                    try activateListForId(&log_sink, child_in, widgets.items, focused_id.?);
                                    try child_in.flush();
                                }
                            },
                            .input => {
                                const rows: usize = @as(usize, last_term_size.rows);
                                const cols: usize = @as(usize, last_term_size.cols);
                                var visible_cols: usize = inputVisibleCols(cols);
                                if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |r| {
                                    visible_cols = inputVisibleCols(r.w);
                                }

                                const changed = handleFocusedInputKey(
                                    allocator,
                                    &widgets,
                                    focused_id.?,
                                    decoded,
                                    visible_cols,
                                ) catch |e| blk: {
                                    logPrint(&log_sink, "INPUT_ERR reason={s}\n", .{@errorName(e)});
                                    break :blk false;
                                };
                                if (changed) {
                                    try emitInputEventForId(&log_sink, child_in, widgets.items, focused_id.?);
                                    try child_in.flush();
                                    requested_reason = .input;
                                }
                            },
                        };
                    }
                }
            }

            if (requested_reason == null and backend_events != 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
                const n = patch_lr.readMore() catch |e| {
                    if (e == error.LineTooLong) {
                        logPrint(&log_sink, "PATCH_ERR reason=line_too_long\n", .{});
                        continue;
                    }
                    return e;
                };
                if (n == 0) break;
                logPrint(&log_sink, "PATCH_RX bytes={d}\n", .{n});
            }
        }

        // Ensure debounced resize events aren't starved by backend floods.
        try maybeSendPendingResizeEvent(&log_sink, child_in, &pending_resize, &last_resize_tx_ns);

        // Drain backend lines into scheduler (bounded), but don't let patch floods delay input/resize renders.
        if (requested_reason == null) {
            var sched_changed = false;
            var drained: usize = 0;
            while (drained < max_backend_lines_per_iter) {
                const line = patch_lr.nextLine() orelse break;
                drained += 1;

                var next_arena = std.heap.ArenaAllocator.init(allocator);
                defer next_arena.deinit();

                const line_owned = next_arena.allocator().dupe(u8, line) catch |e| {
                    logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                    continue;
                };

                const msg = protocol.parseMsgLeaky(next_arena.allocator(), line_owned) catch |e| {
                    if (e == error.UnknownPatchMode) {
                        logPrint(&log_sink, "PATCH_ERR reason=unknown_mode\n", .{});
                    } else {
                        logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                    }
                    continue;
                };

                switch (msg) {
                    .patch => |p| switch (p) {
                        .full => |f| {
                            try sched.putFullLeaky(&next_arena, f.root);
                            sched_changed = true;
                        },
                        .target => |t| {
                            if (current_root == null and !sched.hasPendingFull()) {
                                logPrint(
                                    &log_sink,
                                    "SCHED_DROP reason=no_root target={s}\n",
                                    .{t.target},
                                );
                                continue;
                            }

                            const r = try sched.putTargetLeaky(&next_arena, t.target, t.node, t.mode);
                            switch (r) {
                                .dropped_overflow => {
                                    logPrint(
                                        &log_sink,
                                        "SCHED_DROP reason=too_many_targets target={s}\n",
                                        .{t.target},
                                    );
                                },
                                else => sched_changed = true,
                            }
                        },
                    },
                    else => {},
                }
            }

            if (sched_changed) {
                const c = sched.counts();
                if (!std.meta.eql(c, last_sched_counts)) {
                    logPrint(
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
        }

        const now_after = monotonicNowNs();
        if (requested_reason == null and pollTimeoutMsForPendingFrame(now_after, last_render_ns, sched.hasPending()) == 0) {
            requested_reason = .frame;
        }

        if (requested_reason) |reason| {
            const flush_res = if (sched.hasPending())
                try sched.flushApplyLeaky(allocator, &current_arena, &current_root)
            else
                scheduler_mod.FlushResult{ .dropped_targets = sched.counts().dropped_targets };

            if (current_root != null) {
                try syncUiAfterPatch(
                    allocator,
                    &log_sink,
                    child_in,
                    &widgets,
                    &focused_id_buf,
                    &focused_id,
                    &auto_focus_done,
                    current_root.?,
                );
                try child_in.flush();

                if (resize_changed_this_iter) {
                    clampLocalStateForResize(&widgets, current_root.?, last_term_size);
                }

                const rs = try buildRenderState(allocator, widgets.items, &render_inputs, &render_lists, focused_id);
                try renderer.draw(&term, current_root.?, rs);
                last_render_ns = monotonicNowNs();

                logPrint(
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
}

fn parseCmdArgs(args: []const []const u8) ![]const []const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--cmd")) {
            if (i + 1 >= args.len) break;
            return args[i + 1 ..];
        }
    }
    std.debug.print("usage: tui_runtime --cmd <backend> [args...]\n", .{});
    return error.InvalidArgs;
}

const ResolvedCmd = struct {
    argv: []const []const u8,
    owned_argv: bool,
    owned_cmd0: bool,
};

fn resolveCmdArgv(allocator: std.mem.Allocator, cmd_argv: []const []const u8) !ResolvedCmd {
    if (cmd_argv.len == 0) return error.InvalidArgs;

    const cmd = cmd_argv[0];
    if (std.mem.indexOfScalar(u8, cmd, '/') != null) {
        return .{ .argv = cmd_argv, .owned_argv = false, .owned_cmd0 = false };
    }

    var self_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_path = try std.fs.selfExePath(&self_path_buf);
    const self_dir = std.fs.path.dirname(self_path) orelse ".";
    const maybe_path = try std.fs.path.join(allocator, &.{ self_dir, cmd });
    errdefer allocator.free(maybe_path);

    if (std.fs.openFileAbsolute(maybe_path, .{})) |f| {
        f.close();
        var out = try allocator.alloc([]const u8, cmd_argv.len);
        out[0] = maybe_path;
        for (cmd_argv[1..], 1..) |arg, idx| out[idx] = arg;
        return .{ .argv = out, .owned_argv = true, .owned_cmd0 = true };
    } else |_| {
        allocator.free(maybe_path);
        return .{ .argv = cmd_argv, .owned_argv = false, .owned_cmd0 = false };
    }
}

fn mapKey(b: u8) ?[]const u8 {
    return switch (b) {
        'q' => "q",
        'x' => "x",
        3 => "ctrl-c",
        else => null,
    };
}

fn readByteIfReady(term: *terminal.Terminal) !?u8 {
    var fds = [_]std.posix.pollfd{
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const rc = try std.posix.poll(fds[0..], 0);
    if (rc == 0) return null;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) return null;
    return try term.readByte();
}

const CsiPending = struct {
    active: bool = false,
    buf: [64]u8 = undefined,
    len: u8 = 0,

    fn reset(self: *CsiPending) void {
        self.active = false;
        self.len = 0;
    }

    fn start(self: *CsiPending) void {
        self.active = true;
        self.len = 0;
    }

    fn feed(self: *CsiPending, b: u8) ?DecodedKey {
        if (!self.active) return null;
        if (@as(usize, self.len) >= self.buf.len) {
            self.reset();
            return null;
        }

        self.buf[@as(usize, self.len)] = b;
        self.len += 1;

        const seq = self.buf[0..@as(usize, self.len)];
        const first = seq[0];

        switch (first) {
            'Z' => {
                self.reset();
                return .shift_tab;
            },
            'D' => {
                self.reset();
                return .left;
            },
            'C' => {
                self.reset();
                return .right;
            },
            'H' => {
                self.reset();
                return .home;
            },
            'F' => {
                self.reset();
                return .end;
            },
            '<' => {
                // SGR mouse: <b;x;yM or <b;x;ym
                if (b == 'M' or b == 'm') {
                    defer self.reset();
                    if (mouse.parseSgrMouseSequence(seq)) |ev| {
                        return .{ .mouse = ev };
                    }
                    return null;
                }
                return null;
            },
            '3', '1', '4' => {
                if (seq.len < 2) return null;
                if (seq[1] != '~') {
                    self.reset();
                    return null;
                }
                const out: DecodedKey = switch (first) {
                    '3' => .delete,
                    '1' => .home,
                    '4' => .end,
                    else => unreachable,
                };
                self.reset();
                return out;
            },
            else => {
                self.reset();
                return null;
            },
        }
    }
};

const DecodedKey = union(enum) {
    byte: u8,
    utf8: Utf8Bytes,
    tab,
    shift_tab,
    left,
    right,
    home,
    end,
    delete,
    word_left,
    word_right,
    mouse: mouse.MouseEvent,
};

const Utf8Bytes = struct {
    bytes: [4]u8,
    len: u3,

    fn slice(self: *const Utf8Bytes) []const u8 {
        return self.bytes[0..@as(usize, self.len)];
    }
};

const Utf8Pending = struct {
    bytes: [4]u8 = undefined,
    len: u3 = 0,
    expect: u3 = 0,

    fn reset(self: *Utf8Pending) void {
        self.len = 0;
        self.expect = 0;
    }
};

fn isUtf8ContinuationByte(b: u8) bool {
    return (b & 0b1100_0000) == 0b1000_0000;
}

fn decodeKey(term: *terminal.Terminal, csi_pending: *CsiPending, first: u8) !?DecodedKey {
    if (first == '\t') return .tab;
    if (first != 0x1b) return .{ .byte = first };

    const b2 = try readByteIfReady(term) orelse return .{ .byte = first };
    switch (b2) {
        '[' => {
            csi_pending.start();

            const b3 = try readByteIfReady(term) orelse return null;
            if (csi_pending.feed(b3)) |ev| return ev;

            while (csi_pending.active) {
                const next = try readByteIfReady(term) orelse break;
                if (csi_pending.feed(next)) |ev| return ev;
            }
            return null;
        },
        'O' => {
            const b3 = try readByteIfReady(term) orelse return null;
            return switch (b3) {
                'H' => .home,
                'F' => .end,
                else => null,
            };
        },
        'b' => return .word_left,
        'f' => return .word_right,
        else => return null,
    }
}

fn decodeKeyWithUtf8(term: *terminal.Terminal, pending: *Utf8Pending, csi_pending: *CsiPending, b: u8) !?DecodedKey {
    if (csi_pending.active) {
        return csi_pending.feed(b);
    }

    if (pending.expect != 0) {
        if (isUtf8ContinuationByte(b)) {
            if (@as(usize, pending.len) >= pending.bytes.len) {
                pending.reset();
                return null;
            }
            pending.bytes[@as(usize, pending.len)] = b;
            pending.len += 1;

            if (pending.len == pending.expect) {
                const out: Utf8Bytes = .{ .bytes = pending.bytes, .len = pending.len };
                pending.reset();
                return .{ .utf8 = out };
            }
            return null;
        }

        // Incomplete sequence; drop and treat this byte as a new key.
        pending.reset();
    }

    if (b == 0x1b or b < 0x80) return decodeKey(term, csi_pending, b);

    const expect = std.unicode.utf8ByteSequenceLength(b) catch return null;
    if (expect <= 1 or expect > 4) return null;

    pending.bytes[0] = b;
    pending.len = 1;
    pending.expect = expect;
    return null;
}

fn cloneNodeLeaky(allocator: std.mem.Allocator, node: protocol.Node) !protocol.Node {
    return switch (node) {
        .text => |t| .{ .text = .{
            .id = try allocator.dupe(u8, t.id),
            .w = t.w,
            .h = t.h,
            .flex = t.flex,
            .text = try allocator.dupe(u8, t.text),
        } },
        .input => |i| .{ .input = .{
            .id = try allocator.dupe(u8, i.id),
            .w = i.w,
            .h = i.h,
            .flex = i.flex,
            .placeholder = if (i.placeholder) |p| try allocator.dupe(u8, p) else null,
        } },
        .vbox => |v| blk: {
            var children = try allocator.alloc(protocol.Node, v.children.len);
            for (v.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .vbox = .{
                .id = try allocator.dupe(u8, v.id),
                .w = v.w,
                .h = v.h,
                .flex = v.flex,
                .pad = v.pad,
                .clip = v.clip,
                .children = children,
            } };
        },
        .hbox => |h| blk: {
            var children = try allocator.alloc(protocol.Node, h.children.len);
            for (h.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .hbox = .{
                .id = try allocator.dupe(u8, h.id),
                .w = h.w,
                .h = h.h,
                .flex = h.flex,
                .pad = h.pad,
                .clip = h.clip,
                .children = children,
            } };
        },
        .list => |l| blk: {
            var children = try allocator.alloc(protocol.Node, l.children.len);
            for (l.children, 0..) |child, idx| {
                children[idx] = try cloneNodeLeaky(allocator, child);
            }
            break :blk .{ .list = .{
                .id = try allocator.dupe(u8, l.id),
                .w = l.w,
                .h = l.h,
                .flex = l.flex,
                .height = l.height,
                .children = children,
            } };
        },
    };
}

fn nodeId(node: protocol.Node) []const u8 {
    return switch (node) {
        .vbox => |v| v.id,
        .hbox => |h| h.id,
        .text => |t| t.id,
        .input => |i| i.id,
        .list => |l| l.id,
    };
}

const FocusKind = enum {
    input,
    list,
};

const Focusable = struct {
    id: []const u8,
    kind: FocusKind,
};

const InputWidgetState = struct {
    value: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    scroll_x: usize = 0,
};

const ListWidgetState = struct {
    selected_id: std.ArrayList(u8) = .empty,
    scroll: usize = 0,
};

const WidgetState = union(enum) {
    input: InputWidgetState,
    list: ListWidgetState,
};

const WidgetEntry = struct {
    id: std.ArrayList(u8) = .empty,
    state: WidgetState,
};

fn deinitWidgetEntries(allocator: std.mem.Allocator, widgets: *std.ArrayList(WidgetEntry)) void {
    for (widgets.items) |*e| {
        e.id.deinit(allocator);
        switch (e.state) {
            .input => |*s| s.value.deinit(allocator),
            .list => |*s| s.selected_id.deinit(allocator),
        }
    }
    widgets.deinit(allocator);
}

fn buildRenderState(
    allocator: std.mem.Allocator,
    widgets: []const WidgetEntry,
    render_inputs: *std.ArrayList(render.InputState),
    render_lists: *std.ArrayList(render.ListState),
    focused_id: ?[]const u8,
) !render.RenderState {
    render_inputs.clearRetainingCapacity();
    render_lists.clearRetainingCapacity();

    for (widgets) |e| {
        switch (e.state) {
            .input => |s| {
                try render_inputs.append(allocator, .{
                    .id = e.id.items,
                    .value = s.value.items,
                    .cursor = s.cursor,
                    .scroll_x = s.scroll_x,
                });
            },
            .list => |s| {
                try render_lists.append(allocator, .{
                    .id = e.id.items,
                    .selected_id = s.selected_id.items,
                    .scroll = s.scroll,
                });
            },
        }
    }

    std.sort.pdq(render.InputState, render_inputs.items, {}, struct {
        fn lessThan(_: void, a: render.InputState, b: render.InputState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);
    std.sort.pdq(render.ListState, render_lists.items, {}, struct {
        fn lessThan(_: void, a: render.ListState, b: render.ListState) bool {
            return std.mem.order(u8, a.id, b.id) == .lt;
        }
    }.lessThan);

    return .{
        .focused_id = focused_id,
        .inputs = render_inputs.items,
        .lists = render_lists.items,
    };
}

fn collectFocusables(allocator: std.mem.Allocator, root: protocol.Node) !std.ArrayList(Focusable) {
    var out: std.ArrayList(Focusable) = .empty;
    errdefer out.deinit(allocator);
    try collectFocusablesInto(allocator, &out, root);
    return out;
}

fn collectFocusablesInto(allocator: std.mem.Allocator, out: *std.ArrayList(Focusable), node: protocol.Node) !void {
    switch (node) {
        .input => |i| {
            try out.append(allocator, .{ .id = i.id, .kind = .input });
        },
        .list => |l| {
            try out.append(allocator, .{ .id = l.id, .kind = .list });
        },
        .vbox => |v| {
            for (v.children) |child| try collectFocusablesInto(allocator, out, child);
        },
        .hbox => |h| {
            for (h.children) |child| try collectFocusablesInto(allocator, out, child);
        },
        .text => {},
    }
}

fn cycleFocusInTree(allocator: std.mem.Allocator, root: protocol.Node, current: ?[]const u8) !?[]const u8 {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);

    if (focusables.items.len == 0) return null;
    if (current == null) return focusables.items[0].id;

    var current_idx: ?usize = null;
    for (focusables.items, 0..) |f, idx| {
        if (std.mem.eql(u8, f.id, current.?)) {
            current_idx = idx;
            break;
        }
    }

    if (current_idx == null) return focusables.items[0].id;
    const idx = current_idx.?;
    if (idx + 1 < focusables.items.len) return focusables.items[idx + 1].id;
    return null;
}

fn focusedKindInTree(allocator: std.mem.Allocator, root: protocol.Node, id: []const u8) !?FocusKind {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);
    for (focusables.items) |f| {
        if (std.mem.eql(u8, f.id, id)) return f.kind;
    }
    return null;
}

fn setFocusId(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    next: ?[]const u8,
) !void {
    if (next == null) {
        buf.clearRetainingCapacity();
        focused_id.* = null;
        return;
    }
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, next.?);
    focused_id.* = buf.items;
}

fn syncUiAfterPatch(
    allocator: std.mem.Allocator,
    log_sink: *LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    focused_id_buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    auto_focus_done: *bool,
    root: protocol.Node,
) !void {
    var focusables = try collectFocusables(allocator, root);
    defer focusables.deinit(allocator);

    pruneWidgetsNotInFocusables(allocator, widgets, focusables.items);
    try ensureWidgetsForFocusables(allocator, widgets, focusables.items);

    if (focused_id.* == null) {
        if (!auto_focus_done.* and focusables.items.len > 0) {
            try setFocusId(allocator, focused_id_buf, focused_id, focusables.items[0].id);
            auto_focus_done.* = true;
            logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
            try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
        }
    } else {
        if (!focusablesContainsId(focusables.items, focused_id.*.?)) {
            const next = if (focusables.items.len > 0) focusables.items[0].id else null;
            try setFocusId(allocator, focused_id_buf, focused_id, next);
            logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id.* orelse ""});
            try protocol.writeFocusEventJsonl(backend_in, focused_id.* orelse "");
        }
    }

    for (focusables.items) |f| {
        if (f.kind != .list) continue;
        try syncListForId(allocator, log_sink, backend_in, widgets, root, f.id);
    }
}

fn optEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn rectContains(r: render.Rect, x: usize, y: usize) bool {
    if (r.w == 0 or r.h == 0) return false;
    if (x < r.x or y < r.y) return false;
    if (x >= r.x + r.w) return false;
    if (y >= r.y + r.h) return false;
    return true;
}

fn listVisibleHeight(rect: render.Rect, l: protocol.ListNode) usize {
    const desired = l.height orelse rect.h;
    return @min(desired, rect.h);
}

fn findSelectedIndexInList(l: protocol.ListNode, selected_id: []const u8) ?usize {
    if (selected_id.len == 0) return null;
    for (l.children, 0..) |child, idx| {
        if (std.mem.eql(u8, nodeId(child), selected_id)) return idx;
    }
    return null;
}

fn handleMouseEvent(
    allocator: std.mem.Allocator,
    log_sink: *LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    focused_id_buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    ev: mouse.MouseEvent,
) !bool {
    switch (ev.kind) {
        .down_left => return try handleMouseDownLeft(
            allocator,
            log_sink,
            backend_in,
            widgets,
            focused_id_buf,
            focused_id,
            root,
            rows,
            cols,
            ev.x,
            ev.y,
        ),
        .wheel_up => return try handleMouseWheel(
            allocator,
            log_sink,
            widgets,
            root,
            rows,
            cols,
            ev.x,
            ev.y,
            -1,
        ),
        .wheel_down => return try handleMouseWheel(
            allocator,
            log_sink,
            widgets,
            root,
            rows,
            cols,
            ev.x,
            ev.y,
            1,
        ),
    }
}

fn handleMouseDownLeft(
    allocator: std.mem.Allocator,
    log_sink: *LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    focused_id_buf: *std.ArrayList(u8),
    focused_id: *?[]const u8,
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
) !bool {
    var hit_idx: ?usize = null;
    var hit_rect: render.Rect = undefined;

    for (widgets.items, 0..) |w, idx| {
        const r = render.findRectForId(root, rows, cols, w.id.items) orelse continue;
        if (rectContains(r, x, y)) {
            hit_idx = idx;
            hit_rect = r;
            break;
        }
    }

    const idx = hit_idx orelse return false;
    const id = widgets.items[idx].id.items;

    var changed: bool = false;
    var need_flush: bool = false;

    if (!optEql(focused_id.*, id)) {
        try setFocusId(allocator, focused_id_buf, focused_id, id);
        logPrint(log_sink, "EVENT_TX name=focus id={s}\n", .{id});
        try protocol.writeFocusEventJsonl(backend_in, id);
        need_flush = true;
        changed = true;
    }

    switch (widgets.items[idx].state) {
        .input => |*st| {
            const visible_cols = inputVisibleCols(hit_rect.w);
            const before_cursor = st.cursor;
            const before_scroll = st.scroll_x;
            st.cursor = st.value.items.len;
            if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
            if (st.scroll_x > st.value.items.len) st.scroll_x = st.value.items.len;
            _ = input.ensure_cursor_visible(&st.scroll_x, st.cursor, st.value.items, visible_cols);
            if (st.cursor != before_cursor or st.scroll_x != before_scroll) changed = true;
        },
        .list => |*st| {
            const l = findListNodeById(root, id) orelse {
                if (need_flush) try backend_in.flush();
                return changed;
            };

            const visible_height = listVisibleHeight(hit_rect, l);
            if (visible_height == 0) {
                if (need_flush) try backend_in.flush();
                return changed;
            }

            const start: usize = @min(st.scroll, l.children.len);
            if (y < hit_rect.y) {
                if (need_flush) try backend_in.flush();
                return changed;
            }
            const row_idx: usize = y - hit_rect.y;
            if (row_idx >= visible_height) {
                if (need_flush) try backend_in.flush();
                return changed;
            }

            const item_idx: usize = start + row_idx;
            if (item_idx >= l.children.len) {
                if (need_flush) try backend_in.flush();
                return changed;
            }

            const next_id = nodeId(l.children[item_idx]);
            const selection_changed = !(st.selected_id.items.len > 0 and std.mem.eql(u8, st.selected_id.items, next_id));
            if (selection_changed) {
                st.selected_id.clearRetainingCapacity();
                try st.selected_id.appendSlice(allocator, next_id);
                logPrint(
                    log_sink,
                    "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
                    .{ id, next_id, item_idx, st.scroll },
                );
                logPrint(log_sink, "EVENT_TX name=select id={s} item={s}\n", .{ id, next_id });
                try protocol.writeSelectEventJsonl(backend_in, id, next_id);
                need_flush = true;
                changed = true;
            }

            const selected_index = findSelectedIndexInList(l, st.selected_id.items);
            const before_scroll = st.scroll;
            st.scroll = state.clampListScroll(st.scroll, selected_index, visible_height, l.children.len);
            if (st.scroll != before_scroll) changed = true;
        },
    }

    if (need_flush) try backend_in.flush();
    return changed;
}

fn handleMouseWheel(
    allocator: std.mem.Allocator,
    log_sink: *LogSink,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    rows: usize,
    cols: usize,
    x: usize,
    y: usize,
    delta: isize,
) !bool {
    _ = allocator;
    _ = log_sink;

    for (widgets.items) |*w| {
        if (w.state != .list) continue;
        const list_id = w.id.items;

        const r = render.findRectForId(root, rows, cols, list_id) orelse continue;
        if (!rectContains(r, x, y)) continue;

        const l = findListNodeById(root, list_id) orelse return false;
        const visible_height = listVisibleHeight(r, l);
        if (visible_height == 0) return false;

        const st = &w.state.list;
        const max_scroll: usize = if (l.children.len > visible_height) l.children.len - visible_height else 0;

        var next: usize = st.scroll;
        if (delta > 0) {
            if (next < max_scroll) next += 1;
        } else if (delta < 0) {
            if (next > 0) next -= 1;
        }

        const selected_index = findSelectedIndexInList(l, st.selected_id.items);
        next = state.clampListScroll(next, selected_index, visible_height, l.children.len);
        if (next == st.scroll) return false;
        st.scroll = next;
        return true;
    }

    return false;
}

fn pruneWidgetsNotInFocusables(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    focusables: []const Focusable,
) void {
    var i: usize = widgets.items.len;
    while (i > 0) {
        i -= 1;
        const id = widgets.items[i].id.items;
        if (focusablesContainsId(focusables, id)) continue;
        deinitWidgetEntry(allocator, &widgets.items[i]);
        _ = widgets.swapRemove(i);
    }
}

fn deinitWidgetEntry(allocator: std.mem.Allocator, e: *WidgetEntry) void {
    e.id.deinit(allocator);
    switch (e.state) {
        .input => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
    }
}

fn focusablesContainsId(focusables: []const Focusable, id: []const u8) bool {
    for (focusables) |f| {
        if (std.mem.eql(u8, f.id, id)) return true;
    }
    return false;
}

fn ensureWidgetsForFocusables(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    focusables: []const Focusable,
) !void {
    for (focusables) |f| {
        _ = try ensureWidgetKind(allocator, widgets, f.id, f.kind);
    }
}

fn ensureWidgetKind(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    id: []const u8,
    kind: FocusKind,
) !usize {
    if (findWidgetIndex(widgets.items, id)) |idx| {
        switch (widgets.items[idx].state) {
            .input => if (kind == .input) return idx else {},
            .list => if (kind == .list) return idx else {},
        }
        // Type changed: reset state.
        deinitWidgetEntryState(allocator, &widgets.items[idx]);
        widgets.items[idx].state = initWidgetState(kind);
        return idx;
    }

    var id_buf: std.ArrayList(u8) = .empty;
    errdefer id_buf.deinit(allocator);
    try id_buf.appendSlice(allocator, id);
    try widgets.append(allocator, .{ .id = id_buf, .state = initWidgetState(kind) });
    return widgets.items.len - 1;
}

fn deinitWidgetEntryState(allocator: std.mem.Allocator, e: *WidgetEntry) void {
    switch (e.state) {
        .input => |*s| s.value.deinit(allocator),
        .list => |*s| s.selected_id.deinit(allocator),
    }
}

fn initWidgetState(kind: FocusKind) WidgetState {
    return switch (kind) {
        .input => .{ .input = .{} },
        .list => .{ .list = .{} },
    };
}

fn findWidgetIndex(widgets: []const WidgetEntry, id: []const u8) ?usize {
    for (widgets, 0..) |e, idx| {
        if (std.mem.eql(u8, e.id.items, id)) return idx;
    }
    return null;
}

fn findListNodeById(root: protocol.Node, id: []const u8) ?protocol.ListNode {
    if (std.mem.eql(u8, nodeId(root), id)) {
        return switch (root) {
            .list => |l| l,
            else => null,
        };
    }

    return switch (root) {
        .vbox => |v| blk: {
            for (v.children) |child| {
                if (findListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .hbox => |h| blk: {
            for (h.children) |child| {
                if (findListNodeById(child, id)) |l| break :blk l;
            }
            break :blk null;
        },
        .list => |l| blk: {
            for (l.children) |child| {
                if (findListNodeById(child, id)) |ll| break :blk ll;
            }
            break :blk null;
        },
        else => null,
    };
}

fn syncListForId(
    allocator: std.mem.Allocator,
    log_sink: *LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    list_id: []const u8,
) !void {
    const l = findListNodeById(root, list_id) orelse return;
    if (l.children.len == 0) {
        if (findWidgetIndex(widgets.items, list_id)) |idx| {
            const st = &widgets.items[idx].state.list;
            st.selected_id.clearRetainingCapacity();
            st.scroll = 0;
        }
        return;
    }

    const idx = try ensureWidgetKind(allocator, widgets, list_id, .list);
    var st = &widgets.items[idx].state.list;

    var selected_index: ?usize = null;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                selected_index = child_idx;
                break;
            }
        }
    }

    var selection_changed = false;
    if (selected_index == null) {
        const new_id = nodeId(l.children[0]);
        st.selected_id.clearRetainingCapacity();
        try st.selected_id.appendSlice(allocator, new_id);
        selected_index = 0;
        selection_changed = true;
    }

    const height = l.height orelse l.children.len;
    const effective_height = if (height == 0) l.children.len else height;

    const sel_idx = selected_index.?;
    const max_scroll = if (l.children.len > effective_height) l.children.len - effective_height else 0;
    if (st.scroll > max_scroll) st.scroll = max_scroll;
    if (sel_idx < st.scroll) st.scroll = sel_idx;
    if (sel_idx >= st.scroll + effective_height) st.scroll = sel_idx - effective_height + 1;

    logPrint(
        log_sink,
        "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
        .{ list_id, st.selected_id.items, sel_idx, st.scroll },
    );
    if (selection_changed) {
        logPrint(log_sink, "EVENT_TX name=select id={s} item={s}\n", .{ list_id, st.selected_id.items });
        try protocol.writeSelectEventJsonl(backend_in, list_id, st.selected_id.items);
    }
}

fn moveListSelectionForId(
    allocator: std.mem.Allocator,
    log_sink: *LogSink,
    backend_in: anytype,
    widgets: *std.ArrayList(WidgetEntry),
    root: protocol.Node,
    list_id: []const u8,
    delta: isize,
) !bool {
    const l = findListNodeById(root, list_id) orelse return false;
    if (l.children.len == 0) return false;

    const idx = try ensureWidgetKind(allocator, widgets, list_id, .list);
    var st = &widgets.items[idx].state.list;

    var current_idx: usize = 0;
    if (st.selected_id.items.len > 0) {
        for (l.children, 0..) |child, child_idx| {
            if (std.mem.eql(u8, nodeId(child), st.selected_id.items)) {
                current_idx = child_idx;
                break;
            }
        }
    }

    const len: isize = @as(isize, @intCast(l.children.len));
    const next_idx_signed = @min(@max(@as(isize, @intCast(current_idx)) + delta, 0), len - 1);
    const next_idx: usize = @as(usize, @intCast(next_idx_signed));
    const next_id = nodeId(l.children[next_idx]);
    if (st.selected_id.items.len > 0 and std.mem.eql(u8, st.selected_id.items, next_id)) return false;

    st.selected_id.clearRetainingCapacity();
    try st.selected_id.appendSlice(allocator, next_id);

    const height = l.height orelse l.children.len;
    const effective_height = if (height == 0) l.children.len else height;
    const max_scroll = if (l.children.len > effective_height) l.children.len - effective_height else 0;
    if (st.scroll > max_scroll) st.scroll = max_scroll;
    if (next_idx < st.scroll) st.scroll = next_idx;
    if (next_idx >= st.scroll + effective_height) st.scroll = next_idx - effective_height + 1;

    logPrint(
        log_sink,
        "LIST_SELECT id={s} item={s} index={d} scroll={d}\n",
        .{ list_id, next_id, next_idx, st.scroll },
    );
    logPrint(log_sink, "EVENT_TX name=select id={s} item={s}\n", .{ list_id, next_id });
    try protocol.writeSelectEventJsonl(backend_in, list_id, next_id);
    return true;
}

fn activateListForId(log_sink: *LogSink, backend_in: anytype, widgets: []const WidgetEntry, list_id: []const u8) !void {
    const idx = findWidgetIndex(widgets, list_id) orelse return;
    const st = widgets[idx].state.list;
    if (st.selected_id.items.len == 0) return;
    logPrint(log_sink, "EVENT_TX name=activate id={s} item={s}\n", .{ list_id, st.selected_id.items });
    try protocol.writeActivateEventJsonl(backend_in, list_id, st.selected_id.items);
}

fn handleFocusedInputKey(
    allocator: std.mem.Allocator,
    widgets: *std.ArrayList(WidgetEntry),
    input_id: []const u8,
    key: DecodedKey,
    visible_cols: usize,
) !bool {
    const idx = try ensureWidgetKind(allocator, widgets, input_id, .input);
    var st = &widgets.items[idx].state.input;

    const before_cursor: usize = st.cursor;
    const before_len: usize = st.value.items.len;
    const before_scroll: usize = st.scroll_x;

    var changed: bool = false;
    switch (key) {
        .byte => |b| changed = try input.handleInputByte(allocator, &st.value, &st.cursor, b),
        .utf8 => |u| changed = try input.insertUtf8Bytes(allocator, &st.value, &st.cursor, u.slice()),
        .left => {
            const next = unicode.prevGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .right => {
            const next = unicode.nextGraphemeBoundary(st.value.items, st.cursor);
            if (next != st.cursor) {
                st.cursor = next;
                changed = true;
            }
        },
        .home => if (st.cursor != 0) {
            st.cursor = 0;
            changed = true;
        },
        .end => if (st.cursor != st.value.items.len) {
            st.cursor = st.value.items.len;
            changed = true;
        },
        .delete => changed = input.delete_at_cursor(&st.value, &st.cursor),
        .word_left => {
            const next = input.word_left(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        .word_right => {
            const next = input.word_right(st.value.items, st.cursor);
            const clamped = unicode.clampGraphemeBoundary(st.value.items, next);
            if (clamped != st.cursor) {
                st.cursor = clamped;
                changed = true;
            }
        },
        else => return false,
    }

    if (!changed and before_cursor == st.cursor and before_len == st.value.items.len and before_scroll == st.scroll_x) return false;

    if (st.cursor > st.value.items.len) st.cursor = st.value.items.len;
    if (st.scroll_x > st.value.items.len) st.scroll_x = st.value.items.len;
    const scroll_changed = input.ensure_cursor_visible(&st.scroll_x, st.cursor, st.value.items, visible_cols);
    return changed or scroll_changed;
}

fn emitInputEventForId(log_sink: *LogSink, backend_in: anytype, widgets: []const WidgetEntry, input_id: []const u8) !void {
    const idx = findWidgetIndex(widgets, input_id) orelse return;
    const st = widgets[idx].state.input;
    logPrint(
        log_sink,
        "EVENT_TX name=input id={s} len={d} cursor={d}\n",
        .{ input_id, st.value.items.len, st.cursor },
    );
    try protocol.writeInputEventJsonl(backend_in, input_id, st.value.items, st.cursor);
}
