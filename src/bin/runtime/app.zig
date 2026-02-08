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
const tree = tui.tree;

const cmd = @import("cmd.zig");
const log = @import("log.zig");
const timing = @import("timing.zig");
const ui = @import("ui/mod.zig");
const pointer = @import("ui/pointer.zig");
const iomux_mod = @import("iomux.zig");
const keybindings = @import("keybindings.zig");

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

fn keyEventToProtocolParts(ev: keys.KeyEvent, fbuf: *[4]u8) struct { key: []const u8, mods: u8, seq: ?[]const u8 } {
    return .{
        .key = keys.keyToString(ev.key, fbuf),
        .mods = ev.mods.toMask(),
        .seq = switch (ev.key) {
            .unknown_escape => |s| s,
            else => null,
        },
    };
}

fn sendKeyEventToBackend(log_sink: *log.LogSink, backend_in: anytype, ev: keys.KeyEvent) !void {
    var fbuf: [4]u8 = undefined;
    const parts = keyEventToProtocolParts(ev, &fbuf);

    if (parts.seq) |s| {
        log.logPrint(log_sink, "EVENT_TX name=key key={s} mods={d} seq_len={d}\n", .{ parts.key, parts.mods, s.len });
    } else if (parts.mods != 0) {
        log.logPrint(log_sink, "EVENT_TX name=key key={s} mods={d}\n", .{ parts.key, parts.mods });
    } else {
        log.logPrint(log_sink, "EVENT_TX name=key key={s}\n", .{parts.key});
    }
    try protocol.writeKeyEventJsonlFull(backend_in, parts.key, parts.mods, parts.seq);
}

fn colorModeString(mode: tui.color.ColorMode) []const u8 {
    return switch (mode) {
        .mono => "mono",
        .ansi16 => "ansi16",
        .ansi256 => "ansi256",
        .truecolor => "truecolor",
    };
}

fn queueOverflowString(policy: timing.QueueOverflowPolicy) []const u8 {
    return switch (policy) {
        .drop_newest => "drop_newest",
        .drop_oldest => "drop_oldest",
    };
}

fn sendHelloEventToBackend(
    log_sink: *log.LogSink,
    backend_in: anytype,
    caps: tui.termcaps.Caps,
    runtime_cfg: timing.RuntimeConfig,
) !void {
    log.logPrint(
        log_sink,
        "EVENT_TX name=hello protocol_version={d} color={s} max_fps={d} max_pending_targets={d} max_backend_lines={d} overflow={s}\n",
        .{
            protocol.PROTOCOL_VERSION,
            colorModeString(caps.color),
            runtime_cfg.max_fps,
            runtime_cfg.max_pending_targets,
            runtime_cfg.max_backend_lines_per_iter,
            queueOverflowString(runtime_cfg.queue_overflow),
        },
    );
    try protocol.writeHelloEventJsonl(backend_in, protocol.PROTOCOL_VERSION, .{
        .ansi = caps.ansi,
        .alt_screen = caps.alt_screen,
        .bracketed_paste = caps.bracketed_paste,
        .mouse_sgr = caps.mouse_sgr,
        .osc52 = caps.osc52,
        .color = colorModeString(caps.color),
    }, .{
        .max_fps = runtime_cfg.max_fps,
        .frame_interval_ns = runtime_cfg.frame_interval_ns,
        .max_pending_targets = runtime_cfg.max_pending_targets,
        .max_backend_lines_per_iter = runtime_cfg.max_backend_lines_per_iter,
        .queue_overflow = queueOverflowString(runtime_cfg.queue_overflow),
    });
    try backend_in.flush();
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

const ErrorEventLimiter = struct {
    last_emit_ns: u64 = 0,
    interval_ns: u64 = 200 * std.time.ns_per_ms,

    fn allow(self: *ErrorEventLimiter, now_ns: u64) bool {
        if (self.last_emit_ns != 0 and now_ns < self.last_emit_ns + self.interval_ns) return false;
        self.last_emit_ns = now_ns;
        return true;
    }
};

fn emitRuntimeErrorEvent(
    log_sink: *log.LogSink,
    backend_in: anytype,
    limiter: *ErrorEventLimiter,
    code: []const u8,
    message: []const u8,
    seq: ?u64,
    context: ?[]const u8,
) !void {
    const now_ns = timing.monotonicNowNs();
    if (!limiter.allow(now_ns)) {
        log.logPrint(log_sink, "EVENT_DROP name=error code={s} reason=rate_limit\n", .{code});
        return;
    }
    if (context) |ctx| {
        log.logPrint(log_sink, "EVENT_TX name=error code={s} message={s} context={s}\n", .{ code, message, ctx });
    } else {
        log.logPrint(log_sink, "EVENT_TX name=error code={s} message={s}\n", .{ code, message });
    }
    try protocol.writeErrorEventJsonl(backend_in, code, message, seq, context);
    try backend_in.flush();
}

fn configRejectedKeyForParseError(parse_err: anyerror) []const u8 {
    return switch (parse_err) {
        error.UnknownThemeName => "theme",
        error.UnknownKeyAction, error.InvalidKeybindingRule => "keybindings",
        else => "config",
    };
}

fn parseErrIsKeybindingsReject(parse_err: anyerror) bool {
    return parse_err == error.UnknownKeyAction or parse_err == error.InvalidKeybindingRule;
}

fn buildConfigRejectEntries(
    parse_err: anyerror,
    has_theme_key: bool,
    storage: *[2]protocol.ConfigAckRejected,
) []const protocol.ConfigAckRejected {
    storage[0] = .{
        .key = configRejectedKeyForParseError(parse_err),
        .reason = @errorName(parse_err),
    };
    var len: usize = 1;
    if (has_theme_key and parseErrIsKeybindingsReject(parse_err)) {
        storage[len] = .{
            .key = "theme",
            .reason = "keybindings_rejected",
        };
        len += 1;
    }
    return storage[0..len];
}

const BackendMsgKind = enum {
    patch,
    config,
    clipboard,
    other,
};

const BackendLineHint = struct {
    kind: BackendMsgKind = .other,
    seq: ?u64 = null,
    has_theme_key: bool = false,
};

fn parseBackendLineHint(allocator: std.mem.Allocator, line: []const u8) BackendLineHint {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch return .{};
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return .{},
    };
    const type_val = obj.get("type") orelse return .{};
    const type_str = switch (type_val) {
        .string => |s| s,
        else => return .{},
    };
    var seq: ?u64 = null;
    if (obj.get("seq")) |seq_val| {
        switch (seq_val) {
            .integer => |n| {
                if (n >= 0) seq = @as(u64, @intCast(n));
            },
            else => {},
        }
    }
    if (std.mem.eql(u8, type_str, "patch")) return .{ .kind = .patch, .seq = seq };
    if (std.mem.eql(u8, type_str, "clipboard")) return .{ .kind = .clipboard, .seq = seq };
    if (!std.mem.eql(u8, type_str, "config")) return .{ .kind = .other, .seq = seq };
    return .{
        .kind = .config,
        .seq = seq,
        .has_theme_key = obj.get("theme") != null,
    };
}

fn emitAckEvent(
    log_sink: *log.LogSink,
    backend_in: anytype,
    seq: u64,
    status: []const u8,
    detail: ?[]const u8,
) !void {
    if (detail) |d| {
        log.logPrint(log_sink, "EVENT_TX name=ack seq={d} status={s} detail={s}\n", .{ seq, status, d });
    } else {
        log.logPrint(log_sink, "EVENT_TX name=ack seq={d} status={s}\n", .{ seq, status });
    }
    try protocol.writeAckEventJsonl(backend_in, seq, status, detail);
    try backend_in.flush();
}

pub fn writeConfigRejectAckAndErrorEvents(
    writer: anytype,
    parse_err: anyerror,
    has_theme_key: bool,
) !void {
    var rejected_storage: [2]protocol.ConfigAckRejected = undefined;
    const rejected = buildConfigRejectEntries(parse_err, has_theme_key, &rejected_storage);
    try protocol.writeConfigAckEventJsonl(writer, .{
        .applied = &.{},
        .rejected = rejected,
    });
    try protocol.writeErrorEventJsonl(
        writer,
        "config_rejected",
        "backend config rejected",
        null,
        @errorName(parse_err),
    );
}

fn emitConfigAckEvent(
    log_sink: *log.LogSink,
    backend_in: anytype,
    applied: []const []const u8,
    rejected: []const protocol.ConfigAckRejected,
) !void {
    log.logPrint(log_sink, "EVENT_TX name=config_ack applied={d} rejected={d}\n", .{ applied.len, rejected.len });
    try protocol.writeConfigAckEventJsonl(backend_in, .{
        .applied = applied,
        .rejected = rejected,
    });
    try backend_in.flush();
}

fn emitConfigRejectAckEvent(
    log_sink: *log.LogSink,
    backend_in: anytype,
    parse_err: anyerror,
    has_theme_key: bool,
) !void {
    var rejected_storage: [2]protocol.ConfigAckRejected = undefined;
    const rejected = buildConfigRejectEntries(parse_err, has_theme_key, &rejected_storage);
    try emitConfigAckEvent(log_sink, backend_in, &.{}, rejected);
}

fn contextForFocusedKind(kind: ui.FocusKind) keybindings.Context {
    return switch (kind) {
        .input => .input,
        .textarea => .textarea,
        .list => .list,
        .scroll => .scroll,
        .action => .action,
    };
}

fn findRectNoScrollCached(
    cache: *render.LayoutCache,
    root: *const protocol.Node,
    rows: usize,
    cols: usize,
    id: []const u8,
) ?render.Rect {
    if (cache.root == null or cache.root.? != root or cache.rows != rows or cache.cols != cols or cache.scrolls.len != 0) {
        cache.reset(root, rows, cols, &.{});
    }
    return cache.findRect(id);
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

    const runtime_cfg = try timing.loadRuntimeConfig(allocator);
    log.logPrint(
        &log_sink,
        "RUNTIME_CFG max_fps={d} frame_interval_ns={d} max_pending_targets={d} max_backend_lines={d} overflow={s} perf={s} rendered_events={s}\n",
        .{
            runtime_cfg.max_fps,
            runtime_cfg.frame_interval_ns,
            runtime_cfg.max_pending_targets,
            runtime_cfg.max_backend_lines_per_iter,
            switch (runtime_cfg.queue_overflow) {
                .drop_newest => "drop_newest",
                .drop_oldest => "drop_oldest",
            },
            if (runtime_cfg.perf_log) "true" else "false",
            if (runtime_cfg.emit_render_events) "true" else "false",
        },
    );

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
    // IOMux owns these read pipes and closes them on teardown. Clear child-owned
    // references so kill()/wait() does not attempt to close them a second time.
    child.stdout = null;
    child.stderr = null;

    var child_in_buf: [4096]u8 = undefined;
    var child_in_w = child_in_file.writerStreaming(&child_in_buf);
    const child_in = &child_in_w.interface;
    try sendHelloEventToBackend(&log_sink, child_in, term.caps(), runtime_cfg);

    var current_arena = std.heap.ArenaAllocator.init(allocator);
    defer current_arena.deinit();
    var current_root: ?protocol.Node = null;

    var sched = scheduler_mod.Scheduler.initWithOptions(allocator, .{
        .max_pending_targets = runtime_cfg.max_pending_targets,
        .overflow_policy = switch (runtime_cfg.queue_overflow) {
            .drop_newest => .drop_newest,
            .drop_oldest => .drop_oldest,
        },
    });
    defer sched.deinit();
    var id_index = tree.IdIndex.init(allocator);
    defer id_index.deinit();
    var last_patch_seq_seen: u64 = 0;
    var has_patch_seq_seen: bool = false;
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
    var keymap = try keybindings.KeymapState.initDefaults(allocator);
    defer keymap.deinit();
    var active_theme: render.Theme = render.default_theme;
    var error_event_limiter: ErrorEventLimiter = .{};
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
        var iter_parse_ns: u64 = 0;
        var iter_parse_lines: usize = 0;
        var iter_parse_bytes: usize = 0;
        var no_scroll_layout_cache = render.LayoutCache.init(allocator);
        defer no_scroll_layout_cache.deinit();

        const now_ns = timing.monotonicNowNs();
        const resize_timeout_ms = timing.pollTimeoutMsForPendingResize(pending_resize, last_resize_tx_ns);
        const frame_timeout_ms = timing.pollTimeoutMsForPendingFrame(now_ns, last_render_ns, sched.hasPending(), runtime_cfg.frame_interval_ns);
        const decoder_timeout_ms: i32 = blk: {
            const deadline_ns = decoder.nextDeadlineNs() orelse break :blk -1;
            if (now_ns >= deadline_ns) break :blk 0;
            const remaining_ns: u64 = deadline_ns - now_ns;
            const ms_u64: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
            const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
            break :blk @as(i32, @intCast(if (ms_u64 > max_i32) max_i32 else ms_u64));
        };
        const poll_timeout_ms = timing.minTimeoutMs(timing.minTimeoutMs(resize_timeout_ms, frame_timeout_ms), decoder_timeout_ms);
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
        var events_processed: usize = 0;
        var next_timeout_ms: i32 = poll_timeout_ms;
        while (events_processed < runtime_cfg.max_backend_lines_per_iter) : (events_processed += 1) {
            const ev = mux.recvTimeout(next_timeout_ms) orelse break;
            next_timeout_ms = 0;
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
                    const parse_start_ns = timing.monotonicNowNs();
                    iter_parse_lines += 1;
                    iter_parse_bytes += line.len;

                    var next_arena = std.heap.ArenaAllocator.init(allocator);
                    defer next_arena.deinit();

                    const line_owned = next_arena.allocator().dupe(u8, line) catch |e| {
                        log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                        break;
                    };
                    const line_hint = parseBackendLineHint(next_arena.allocator(), line_owned);

                    const msg = protocol.parseMsgLeaky(next_arena.allocator(), line_owned) catch |e| {
                        iter_parse_ns += timing.monotonicNowNs() - parse_start_ns;
                        if (e == error.UnknownPatchMode) {
                            log.logPrint(&log_sink, "PATCH_ERR reason=unknown_mode\n", .{});
                            emitRuntimeErrorEvent(
                                &log_sink,
                                child_in,
                                &error_event_limiter,
                                "invalid_patch_shape",
                                "backend patch rejected: unknown patch mode",
                                null,
                                @errorName(e),
                            ) catch {};
                        } else if (line_hint.kind == .config and
                            (e == error.UnknownKeyAction or
                                e == error.InvalidKeybindingRule or
                                e == error.UnknownThemeName or
                                e == error.MissingField or
                                e == error.WrongType))
                        {
                            log.logPrint(&log_sink, "CONFIG_ERR reason={s}\n", .{@errorName(e)});
                            emitConfigRejectAckEvent(&log_sink, child_in, e, line_hint.has_theme_key) catch {};
                            emitRuntimeErrorEvent(
                                &log_sink,
                                child_in,
                                &error_event_limiter,
                                "config_rejected",
                                "backend config rejected",
                                null,
                                @errorName(e),
                            ) catch {};
                        } else if (e == error.InvalidPatchShape) {
                            log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                            emitRuntimeErrorEvent(
                                &log_sink,
                                child_in,
                                &error_event_limiter,
                                "invalid_patch_shape",
                                "backend patch rejected: invalid shape",
                                null,
                                @errorName(e),
                            ) catch {};
                        } else if (e == error.InvalidJson) {
                            log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                            emitRuntimeErrorEvent(
                                &log_sink,
                                child_in,
                                &error_event_limiter,
                                "invalid_line",
                                "backend line rejected: invalid JSON",
                                null,
                                @errorName(e),
                            ) catch {};
                        } else {
                            log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                            emitRuntimeErrorEvent(
                                &log_sink,
                                child_in,
                                &error_event_limiter,
                                "invalid_line",
                                "backend line rejected by protocol parser",
                                null,
                                @errorName(e),
                            ) catch {};
                        }
                        if (line_hint.seq) |seq| {
                            emitAckEvent(&log_sink, child_in, seq, "ignored_invalid", @errorName(e)) catch {};
                        }
                        break;
                    };
                    iter_parse_ns += timing.monotonicNowNs() - parse_start_ns;

                    switch (msg) {
                        .patch => |p| switch (p) {
                            .full => |f| {
                                if (f.seq) |seq| {
                                    if (has_patch_seq_seen and seq <= last_patch_seq_seen) {
                                        log.logPrint(&log_sink, "SCHED_DROP reason=stale_seq seq={d}\n", .{seq});
                                        if (runtime_cfg.emit_render_events) {
                                            try protocol.writeDroppedEventJsonl(child_in, seq, "stale_seq");
                                            try child_in.flush();
                                        }
                                        emitAckEvent(&log_sink, child_in, seq, "dropped_stale", "stale_seq") catch {};
                                        break;
                                    }
                                    has_patch_seq_seen = true;
                                    last_patch_seq_seen = seq;
                                }

                                sched.putFullLeakyWithSeq(&next_arena, f.root, f.seq) catch |e| {
                                    log.logPrint(&log_sink, "SCHED_ERR reason={s}\n", .{@errorName(e)});
                                    break;
                                };
                                if (f.seq) |seq| {
                                    emitAckEvent(&log_sink, child_in, seq, "queued", "full") catch {};
                                }
                                sched_changed_live = true;
                            },
                            .target => |t| {
                                if (t.seq) |seq| {
                                    if (has_patch_seq_seen and seq <= last_patch_seq_seen) {
                                        log.logPrint(&log_sink, "SCHED_DROP reason=stale_seq seq={d} target={s}\n", .{ seq, t.target });
                                        if (runtime_cfg.emit_render_events) {
                                            try protocol.writeDroppedEventJsonl(child_in, seq, "stale_seq");
                                            try child_in.flush();
                                        }
                                        emitAckEvent(&log_sink, child_in, seq, "dropped_stale", "stale_seq") catch {};
                                        break;
                                    }
                                    has_patch_seq_seen = true;
                                    last_patch_seq_seen = seq;
                                }

                                if (current_root == null and !sched.hasPendingFull()) {
                                    log.logPrint(&log_sink, "SCHED_DROP reason=no_root target={s}\n", .{t.target});
                                    if (t.seq) |seq| {
                                        emitAckEvent(&log_sink, child_in, seq, "dropped_no_root", "no_root") catch {};
                                    }
                                    break;
                                }

                                const r = sched.putTargetLeakyWithSeq(&next_arena, t.target, t.node, t.mode, t.seq) catch |e| {
                                    log.logPrint(&log_sink, "SCHED_ERR reason={s}\n", .{@errorName(e)});
                                    break;
                                };
                                switch (r) {
                                    .dropped_overflow => {
                                        log.logPrint(
                                            &log_sink,
                                            "SCHED_DROP reason=too_many_targets target={s}\n",
                                            .{t.target},
                                        );
                                        if (runtime_cfg.emit_render_events and t.seq != null) {
                                            try protocol.writeDroppedEventJsonl(child_in, t.seq.?, "queue_overflow");
                                            try child_in.flush();
                                        }
                                        if (t.seq) |seq| {
                                            emitAckEvent(&log_sink, child_in, seq, "dropped_overflow", "queue_overflow") catch {};
                                        }
                                    },
                                    .stored_new => {
                                        if (t.seq) |seq| {
                                            emitAckEvent(&log_sink, child_in, seq, "queued", "target") catch {};
                                        }
                                        sched_changed_live = true;
                                    },
                                    .stored_overwrite => {
                                        if (t.seq) |seq| {
                                            emitAckEvent(&log_sink, child_in, seq, "coalesced", "target_overwrite") catch {};
                                        }
                                        sched_changed_live = true;
                                    },
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
                                        if (w.seq) |seq| {
                                            emitAckEvent(&log_sink, child_in, seq, "applied", reason) catch {};
                                        }
                                        break;
                                    };
                                    try protocol.writeClipboardEventJsonl(child_in, .write, true, 0, null, null);
                                    try child_in.flush();
                                    if (w.seq) |seq| {
                                        emitAckEvent(&log_sink, child_in, seq, "applied", null) catch {};
                                    }
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
                                        if (r.seq) |seq| {
                                            emitAckEvent(&log_sink, child_in, seq, "applied", reason) catch {};
                                        }
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
                                                if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |rect| {
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
                                                if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |rect| {
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
                                    if (r.seq) |seq| {
                                        emitAckEvent(&log_sink, child_in, seq, "applied", null) catch {};
                                    }
                                },
                            }
                        },
                        .config => |cfg| {
                            var applied_keys: [2][]const u8 = undefined;
                            var rejected_keys: [2]protocol.ConfigAckRejected = undefined;
                            var applied_len: usize = 0;
                            var rejected_len: usize = 0;

                            if (cfg.keybindings) |kb| {
                                keymap.applyConfigReplace(kb) catch |e| {
                                    log.logPrint(&log_sink, "CONFIG_ERR reason={s}\n", .{@errorName(e)});
                                    rejected_keys[rejected_len] = .{
                                        .key = "keybindings",
                                        .reason = @errorName(e),
                                    };
                                    rejected_len += 1;
                                    if (cfg.theme != null) {
                                        rejected_keys[rejected_len] = .{
                                            .key = "theme",
                                            .reason = "keybindings_rejected",
                                        };
                                        rejected_len += 1;
                                    }
                                    emitConfigAckEvent(
                                        &log_sink,
                                        child_in,
                                        applied_keys[0..applied_len],
                                        rejected_keys[0..rejected_len],
                                    ) catch {};
                                    emitRuntimeErrorEvent(
                                        &log_sink,
                                        child_in,
                                        &error_event_limiter,
                                        "config_rejected",
                                        "backend config rejected",
                                        null,
                                        @errorName(e),
                                    ) catch {};
                                    if (cfg.seq) |seq| {
                                        emitAckEvent(&log_sink, child_in, seq, "ignored_invalid", @errorName(e)) catch {};
                                    }
                                    break;
                                };
                                log.logPrint(&log_sink, "CONFIG_APPLY kind=keybindings\n", .{});
                                applied_keys[applied_len] = "keybindings";
                                applied_len += 1;
                            }
                            if (cfg.theme) |theme_name| {
                                active_theme = render.themeFromName(theme_name);
                                log.logPrint(&log_sink, "CONFIG_APPLY kind=theme name={s}\n", .{@tagName(theme_name)});
                                applied_keys[applied_len] = "theme";
                                applied_len += 1;
                            }
                            if (applied_len != 0 or rejected_len != 0) {
                                try emitConfigAckEvent(
                                    &log_sink,
                                    child_in,
                                    applied_keys[0..applied_len],
                                    rejected_keys[0..rejected_len],
                                );
                            }
                            if (cfg.seq) |seq| {
                                emitAckEvent(&log_sink, child_in, seq, "applied", null) catch {};
                            }
                        },
                        .theme => |tm| {
                            active_theme = render.themeFromName(tm.name);
                            log.logPrint(&log_sink, "CONFIG_APPLY kind=theme name={s}\n", .{@tagName(tm.name)});
                        },
                        else => {},
                    }
                },
                .stdin_bytes => |bytes| {
                    defer allocator.free(bytes);
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
                        const decoded = decoder.feedByte(b, byte_now_ns) orelse continue;

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
                                            if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |r| {
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
                                            if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |r| {
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

                                if (keyEventIsCtrlLetter(kev, 'c')) {
                                    var prefer_local_copy: bool = false;
                                    if (!handled_input_this_iter and focused_kind != null) {
                                        var fbuf_copy: [4]u8 = undefined;
                                        const parts_copy = keyEventToProtocolParts(kev, &fbuf_copy);
                                        const ctx_copy = contextForFocusedKind(focused_kind.?);
                                        if (keymap.resolve(ctx_copy, parts_copy.key, parts_copy.mods)) |copy_action| {
                                            prefer_local_copy = copy_action == .textarea_copy or copy_action == .input_copy;
                                        }
                                    }
                                    if (!prefer_local_copy) {
                                        try sendKeyEventToBackend(&log_sink, child_in, kev);
                                        need_backend_flush = true;
                                        continue;
                                    }
                                }

                                var consumed: bool = false;
                                if (!handled_input_this_iter) {
                                    var fbuf: [4]u8 = undefined;
                                    const parts = keyEventToProtocolParts(kev, &fbuf);
                                    const context = if (focused_kind) |fk| contextForFocusedKind(fk) else keybindings.Context.global;

                                    if (keymap.resolve(context, parts.key, parts.mods)) |action| {
                                        switch (action) {
                                            .noop => consumed = true,
                                            .focus_next, .focus_prev, .focus_scope_next, .focus_scope_prev => {
                                                if (current_root != null) {
                                                    const dir: isize = if (action == .focus_prev or action == .focus_scope_prev) -1 else 1;
                                                    const next_focus = switch (action) {
                                                        .focus_scope_next, .focus_scope_prev => try ui.cycleFocusScopeInTreeDir(allocator, current_root.?, focused_id, dir),
                                                        else => try ui.cycleFocusInTreeDir(allocator, current_root.?, focused_id, dir),
                                                    };
                                                    try ui.setFocusId(allocator, &focused_id_buf, &focused_id, next_focus);
                                                } else {
                                                    try ui.setFocusId(allocator, &focused_id_buf, &focused_id, null);
                                                }
                                                log.logPrint(&log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id orelse ""});
                                                try protocol.writeFocusEventJsonl(child_in, focused_id orelse "");
                                                need_backend_flush = true;
                                                requested_reason = .input;
                                                consumed = true;
                                            },
                                            .focus_clear => {
                                                if (focused_id != null) {
                                                    try ui.setFocusId(allocator, &focused_id_buf, &focused_id, null);
                                                    log.logPrint(&log_sink, "EVENT_TX name=focus id=\n", .{});
                                                    try protocol.writeFocusEventJsonl(child_in, "");
                                                    need_backend_flush = true;
                                                    requested_reason = .input;
                                                    consumed = true;
                                                }
                                            },
                                            else => if (focused_id != null and focused_kind != null and current_root != null) {
                                                const rows: usize = @as(usize, last_term_size.rows);
                                                const cols: usize = @as(usize, last_term_size.cols);
                                                switch (focused_kind.?) {
                                                    .input => {
                                                        var visible_cols: usize = ui.inputVisibleCols(cols);
                                                        if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |r| {
                                                            visible_cols = ui.inputVisibleCols(r.w);
                                                        }
                                                        const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                                        if (action == .input_copy) {
                                                            const selected = ui.inputSelectedTextAlloc(allocator, widgets.items, focused_id.?) catch null;
                                                            if (selected) |payload| {
                                                                defer allocator.free(payload);
                                                                clipboard.writeText(&term, allocator, term.caps(), .{}, payload) catch {};
                                                                consumed = true;
                                                            } else {
                                                                consumed = false;
                                                            }
                                                        } else if (action == .input_paste) {
                                                            const payload = clipboard.readText(allocator) catch null;
                                                            if (payload) |text| {
                                                                defer allocator.free(text);
                                                                consumed = ui.handleFocusedInputPaste(
                                                                    allocator,
                                                                    &widgets,
                                                                    focused_id.?,
                                                                    text,
                                                                    readonly,
                                                                    visible_cols,
                                                                ) catch false;
                                                                if (consumed) {
                                                                    pending_input_event = true;
                                                                    requested_reason = .input;
                                                                } else {
                                                                    consumed = true;
                                                                }
                                                            } else {
                                                                consumed = false;
                                                            }
                                                        } else {
                                                            consumed = ui.applyInputAction(
                                                                allocator,
                                                                &widgets,
                                                                focused_id.?,
                                                                action,
                                                                readonly,
                                                                visible_cols,
                                                            ) catch false;
                                                            if (consumed) {
                                                                pending_input_event = true;
                                                                requested_reason = .input;
                                                            }
                                                        }
                                                    },
                                                    .textarea => {
                                                        var visible_rows: usize = rows;
                                                        var visible_cols: usize = cols;
                                                        if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |r| {
                                                            visible_rows = r.h;
                                                            visible_cols = r.w;
                                                        }
                                                        const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                                        if (action == .textarea_copy) {
                                                            const selected = ui.textareaSelectedTextAlloc(allocator, widgets.items, focused_id.?) catch null;
                                                            if (selected) |payload| {
                                                                defer allocator.free(payload);
                                                                clipboard.writeText(&term, allocator, term.caps(), .{}, payload) catch {};
                                                                consumed = true;
                                                            } else {
                                                                consumed = false;
                                                            }
                                                        } else if (action == .textarea_paste) {
                                                            const payload = clipboard.readText(allocator) catch null;
                                                            if (payload) |text| {
                                                                defer allocator.free(text);
                                                                consumed = ui.handleFocusedTextareaPaste(
                                                                    allocator,
                                                                    &widgets,
                                                                    focused_id.?,
                                                                    text,
                                                                    readonly,
                                                                    visible_rows,
                                                                    visible_cols,
                                                                ) catch false;
                                                                if (consumed) {
                                                                    pending_input_event = true;
                                                                    requested_reason = .input;
                                                                } else {
                                                                    consumed = true;
                                                                }
                                                            } else {
                                                                consumed = false;
                                                            }
                                                        } else {
                                                            consumed = ui.applyTextareaAction(
                                                                allocator,
                                                                &widgets,
                                                                focused_id.?,
                                                                action,
                                                                readonly,
                                                                visible_rows,
                                                                visible_cols,
                                                            ) catch false;
                                                            if (consumed) {
                                                                pending_input_event = true;
                                                                requested_reason = .input;
                                                            }
                                                        }
                                                    },
                                                    .list => {
                                                        consumed = ui.applyListAction(
                                                            allocator,
                                                            &log_sink,
                                                            child_in,
                                                            &widgets,
                                                            current_root.?,
                                                            rows,
                                                            cols,
                                                            focused_id.?,
                                                            action,
                                                        ) catch false;
                                                        if (consumed) {
                                                            need_backend_flush = true;
                                                            requested_reason = .input;
                                                        }
                                                    },
                                                    .scroll => {
                                                        consumed = ui.applyScrollAction(
                                                            allocator,
                                                            &log_sink,
                                                            child_in,
                                                            &widgets,
                                                            current_root.?,
                                                            rows,
                                                            cols,
                                                            focused_id.?,
                                                            action,
                                                        ) catch false;
                                                        if (consumed) {
                                                            need_backend_flush = true;
                                                            requested_reason = .input;
                                                        }
                                                    },
                                                    .action => {
                                                        consumed = ui.applyActionWidgetAction(
                                                            &log_sink,
                                                            child_in,
                                                            focused_id.?,
                                                            action,
                                                        ) catch false;
                                                        if (consumed) {
                                                            need_backend_flush = true;
                                                            requested_reason = .input;
                                                        }
                                                    },
                                                }
                                            },
                                        }
                                    }

                                    if (!consumed and focused_id != null and current_root != null and focused_kind != null) {
                                        switch (focused_kind.?) {
                                            .input => {
                                                const rows: usize = @as(usize, last_term_size.rows);
                                                const cols: usize = @as(usize, last_term_size.cols);
                                                var visible_cols: usize = ui.inputVisibleCols(cols);
                                                if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |r| {
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
                                                }
                                            },
                                            .textarea => {
                                                const rows: usize = @as(usize, last_term_size.rows);
                                                const cols: usize = @as(usize, last_term_size.cols);
                                                var visible_rows: usize = rows;
                                                var visible_cols: usize = cols;
                                                if (findRectNoScrollCached(&no_scroll_layout_cache, &current_root.?, rows, cols, focused_id.?)) |r| {
                                                    visible_rows = r.h;
                                                    visible_cols = r.w;
                                                }
                                                const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);
                                                consumed = ui.handleFocusedTextareaKey(
                                                    allocator,
                                                    &widgets,
                                                    focused_id.?,
                                                    kev,
                                                    readonly,
                                                    visible_rows,
                                                    visible_cols,
                                                ) catch false;
                                                if (consumed) {
                                                    pending_input_event = true;
                                                    requested_reason = .input;
                                                }
                                            },
                                            else => {},
                                        }
                                    }

                                    if (consumed) {
                                        handled_input_this_iter = true;
                                    }
                                }

                                if (!consumed) {
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
                .backend_line_too_long => {
                    log.logPrint(&log_sink, "PATCH_ERR reason=line_too_long\n", .{});
                },
            }
            if (exit_now) break;
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
        if (requested_reason == null and timing.pollTimeoutMsForPendingFrame(now_after, last_render_ns, sched.hasPending(), runtime_cfg.frame_interval_ns) == 0) {
            requested_reason = .frame;
        }

        if (requested_reason) |reason| {
            const flush_start_ns = timing.monotonicNowNs();
            const flush_res = if (sched.hasPending())
                try sched.flushApplyLeakyWithIndex(allocator, &current_arena, &current_root, &id_index)
            else
                scheduler_mod.FlushResult{ .dropped_targets = sched.counts().dropped_targets };
            const sched_flush_ns = timing.monotonicNowNs() - flush_start_ns;
            for (flush_res.applied_seqs) |seq| {
                emitAckEvent(&log_sink, child_in, seq, "applied", null) catch {};
            }
            for (flush_res.not_found_seqs) |seq| {
                emitAckEvent(&log_sink, child_in, seq, "dropped_not_found", "target_not_found") catch {};
            }

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
                pointer_engine.pruneAfterPatchWithIndex(current_root.?, &id_index);
                try child_in.flush();

                if (resize_changed_this_iter) {
                    ui.clampLocalStateForResize(&widgets, current_root.?, last_term_size);
                }

                var rs = try ui.buildRenderState(
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
                rs.theme = &active_theme;
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
                if (runtime_cfg.emit_render_events and flush_res.max_seq_applied != null) {
                    try protocol.writeRenderedEventJsonl(
                        child_in,
                        flush_res.max_seq_applied.?,
                        flush_res.dropped_targets,
                        renderer.last_metrics.bytes,
                        renderer.last_metrics.changed_cells,
                    );
                    try child_in.flush();
                }
                if (runtime_cfg.perf_log) {
                    log.logPrint(
                        &log_sink,
                        "PERF parse_ns={d} parse_lines={d} parse_bytes={d} sched_flush_ns={d} render_to_frame_ns={d} diff_flush_ns={d} bytes={d} changed_cells={d}\n",
                        .{
                            iter_parse_ns,
                            iter_parse_lines,
                            iter_parse_bytes,
                            sched_flush_ns,
                            renderer.last_metrics.render_to_frame_ns,
                            renderer.last_metrics.diff_flush_ns,
                            renderer.last_metrics.bytes,
                            renderer.last_metrics.changed_cells,
                        },
                    );
                }
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
