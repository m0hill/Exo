const std = @import("std");

const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;
const render = tui.render;
const renderer_mod = tui.renderer;
const scheduler_mod = tui.scheduler;
const terminal = tui.terminal;
const keys = tui.keys;
const key_decode = tui.key_decode;

const cmd = @import("cmd.zig");
const log = @import("log.zig");
const sigexit = @import("sigexit.zig");
const sigwinch = @import("sigwinch.zig");
const timing = @import("timing.zig");
const ui = @import("ui/mod.zig");
const pointer = @import("ui/pointer.zig");

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
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const cmd_argv = try cmd.parseCmdArgs(args);

    var term = terminal.Terminal.init() catch |e| {
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

    var renderer = renderer_mod.Renderer.init(allocator);
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

    var child_out_buf: [4096]u8 = undefined;
    var child_out_r = child_out_file.readerStreaming(&child_out_buf);
    var patch_lr = jsonl.LineReader.init(allocator, &child_out_r.interface, 1024 * 1024);
    defer patch_lr.deinit();

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
    sigwinch.setFdNonBlocking(winch_r_fd);
    sigwinch.setFdNonBlocking(winch_w_local);
    sigwinch.winch_w_fd = winch_w_local;
    defer sigwinch.winch_w_fd = -1;
    sigwinch.installSigwinchHandler();

    const sig_pipe = try std.posix.pipe();
    const sig_r_fd: std.posix.fd_t = sig_pipe[0];
    const sig_w_local: std.posix.fd_t = sig_pipe[1];
    defer {
        std.posix.close(sig_r_fd);
        std.posix.close(sig_w_local);
    }
    sigwinch.setFdNonBlocking(sig_r_fd);
    sigwinch.setFdNonBlocking(sig_w_local);
    sigexit.sig_w_fd = sig_w_local;
    defer sigexit.sig_w_fd = -1;
    sigexit.installSigintSigtermHandlers();

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
        signal: sigexit.ExitSignal,
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

        const backend_events: i16 = if (frame_timeout_ms > 0 and sched.hasPending()) 0 else std.posix.POLL.IN;

        const fd_backend_out: usize = 0;
        const fd_backend_err: usize = 1;
        const fd_stdin: usize = 2;
        const fd_winch: usize = 3;
        const fd_sig: usize = 4;

        var fds = [_]std.posix.pollfd{
            .{ .fd = backend_out_fd, .events = backend_events, .revents = 0 },
            .{ .fd = backend_err_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = winch_r_fd, .events = std.posix.POLL.IN, .revents = 0 },
            .{ .fd = sig_r_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const rc = try std.posix.poll(fds[0..], poll_timeout_ms);
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
        if (rc == 0) {
            try maybeSendPendingResizeEvent(&log_sink, child_in, &pending_resize, &last_resize_tx_ns);
        } else {
            if ((fds[fd_backend_out].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
                exit_reason = .backend_closed;
                wait_child = false;
                break;
            }

            if ((fds[fd_sig].revents & std.posix.POLL.IN) != 0) {
                if (sigexit.drainPipe(sig_r_fd)) |sig| {
                    log.logPrint(&log_sink, "SIGNAL_RX name={s}\n", .{switch (sig) {
                        .sigint => "sigint",
                        .sigterm => "sigterm",
                    }});
                    exit_reason = .{ .signal = sig };
                    wait_child = false;
                    break;
                }
            }

            if ((fds[fd_winch].revents & std.posix.POLL.IN) != 0) {
                sigwinch.drainPipe(winch_r_fd);
                const next_size_raw = term.getSize() catch last_term_size;
                const next_size = ui.effectiveTermSize(next_size_raw);
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
            }

            if ((fds[fd_backend_err].revents & std.posix.POLL.IN) != 0) {
                var buf: [4096]u8 = undefined;
                const n = std.posix.read(backend_err_fd, &buf) catch 0;
                if (n > 0) log.logWriteAll(&log_sink, buf[0..n]);
            }

            if ((fds[fd_stdin].revents & std.posix.POLL.IN) != 0) {
                const max_stdin_events_per_iter: usize = 256;
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

                while (processed < max_stdin_events_per_iter) : (processed += 1) {
                    if (processed != 0) {
                        var p = [_]std.posix.pollfd{
                            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
                        };
                        const rc2 = try std.posix.poll(p[0..], 0);
                        if (rc2 == 0 or (p[0].revents & std.posix.POLL.IN) == 0) break;
                    }

                    const first = try term.readByte();
                    const byte_now_ns = timing.monotonicNowNs();
                    const decoded = decoder.feedByte(first, byte_now_ns) orelse continue;

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
                            if (wrote_pointer) try child_in.flush();
                            if (changed) requested_reason = .input;
                            handled_input_this_iter = true;
                            continue;
                        } else {},
                        .paste => |payload| {
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
                        .key => |ev| {
                            const key_now_ns = timing.monotonicNowNs();
                            if (emergency_last_ns != 0 and key_now_ns > emergency_last_ns + emergency_window_ns) {
                                emergency_last_ns = 0;
                            }

                            if (keyEventIsCtrlLetter(ev, 'g')) {
                                if (emergency_last_ns != 0 and key_now_ns <= emergency_last_ns + emergency_window_ns) {
                                    log.logPrint(&log_sink, "EMERGENCY_EXIT chord=ctrl-g ctrl-g\n", .{});
                                    _ = child.kill() catch {};
                                    terminal.emergencyExit(0);
                                }
                                emergency_last_ns = key_now_ns;
                                continue;
                            }

                            if (!handled_input_this_iter and keyEventIsNamed(ev, .tab) and !ev.mods.alt and !ev.mods.ctrl) {
                                if (current_root != null) {
                                    const dir: isize = if (ev.mods.shift) -1 else 1;
                                    const next_focus = try ui.cycleFocusInTreeDir(allocator, current_root.?, focused_id, dir);
                                    try ui.setFocusId(allocator, &focused_id_buf, &focused_id, next_focus);
                                } else {
                                    try ui.setFocusId(allocator, &focused_id_buf, &focused_id, null);
                                }
                                log.logPrint(&log_sink, "EVENT_TX name=focus id={s}\n", .{focused_id orelse ""});
                                try protocol.writeFocusEventJsonl(child_in, focused_id orelse "");
                                if (current_root != null and focused_id != null) {
                                    const rows: usize = @as(usize, last_term_size.rows);
                                    const cols: usize = @as(usize, last_term_size.cols);
                                    const scrolled = try ui.ensureVisibleForFocusId(
                                        allocator,
                                        &log_sink,
                                        child_in,
                                        &widgets,
                                        current_root.?,
                                        rows,
                                        cols,
                                        focused_id.?,
                                    );
                                    if (scrolled) need_backend_flush = true;
                                }
                                need_backend_flush = true;
                                requested_reason = .input;
                                continue;
                            }

                            if (keyEventIsCtrlLetter(ev, 'c')) {
                                try sendKeyEventToBackend(&log_sink, child_in, ev);
                                need_backend_flush = true;
                                wait_child = false;
                                exit_now = true;
                                break;
                            }

                            if (keyEventIsText(ev, 'x') and !focused_is_text_edit) {
                                try sendKeyEventToBackend(&log_sink, child_in, ev);
                                need_backend_flush = true;
                                wait_child = false;
                                exit_now = true;
                                break;
                            }

                            if (keyEventIsText(ev, 'q') and !focused_is_text_edit) {
                                try sendKeyEventToBackend(&log_sink, child_in, ev);
                                need_backend_flush = true;
                                continue;
                            }

                            var consumed: bool = false;
                            if (current_root != null and focused_id != null) {
                                const fk = try ui.focusedKindInTree(allocator, current_root.?, focused_id.?);
                                if (fk) |kind| switch (kind) {
                                    .list => if (isListLocalKey(ev)) {
                                        consumed = true;
                                        if (keyEventIsNamed(ev, .up) or keyEventIsNamed(ev, .down) or keyEventIsText(ev, 'j') or keyEventIsText(ev, 'k')) {
                                            const delta: isize = if (keyEventIsNamed(ev, .down) or keyEventIsText(ev, 'j')) 1 else -1;
                                            const changed = try ui.moveListSelectionForId(
                                                allocator,
                                                &log_sink,
                                                child_in,
                                                &widgets,
                                                current_root.?,
                                                focused_id.?,
                                                delta,
                                            );
                                            if (changed) {
                                                need_backend_flush = true;
                                                requested_reason = .input;
                                            }
                                        } else if (keyEventIsNamed(ev, .enter)) {
                                            try ui.activateListForId(&log_sink, child_in, widgets.items, focused_id.?);
                                            need_backend_flush = true;
                                        }
                                    },
                                    .input => if (isInputLocalKey(ev)) {
                                        consumed = true;
                                        const rows: usize = @as(usize, last_term_size.rows);
                                        const cols: usize = @as(usize, last_term_size.cols);
                                        var visible_cols: usize = ui.inputVisibleCols(cols);
                                        if (render.findRectForId(current_root.?, rows, cols, focused_id.?)) |r| {
                                            visible_cols = ui.inputVisibleCols(r.w);
                                        }
                                        const readonly = ui.nodeReadonlyInTree(current_root.?, focused_id.?);

                                        const changed = ui.handleFocusedInputKey(
                                            allocator,
                                            &widgets,
                                            focused_id.?,
                                            ev,
                                            readonly,
                                            visible_cols,
                                        ) catch |e| blk: {
                                            log.logPrint(&log_sink, "INPUT_ERR reason={s}\n", .{@errorName(e)});
                                            break :blk false;
                                        };
                                        if (changed) {
                                            pending_input_event = true;
                                            requested_reason = .input;
                                        }
                                    },
                                    .textarea => if (isTextareaLocalKey(ev)) {
                                        consumed = true;
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
                                            ev,
                                            readonly,
                                            visible_rows,
                                            visible_cols,
                                        ) catch |e| blk: {
                                            log.logPrint(&log_sink, "TEXTAREA_ERR reason={s}\n", .{@errorName(e)});
                                            break :blk false;
                                        };
                                        if (changed) {
                                            pending_input_event = true;
                                            requested_reason = .input;
                                        }
                                    },
                                    .scroll => if (isScrollLocalKey(ev)) {
                                        consumed = true;
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
                                            ev,
                                        ) catch |e| blk: {
                                            log.logPrint(&log_sink, "SCROLL_ERR reason={s}\n", .{@errorName(e)});
                                            break :blk false;
                                        };
                                        if (changed) {
                                            need_backend_flush = true;
                                            requested_reason = .input;
                                        }
                                    },
                                    .action => {
                                        const pressed_space: bool = switch (ev.key) {
                                            .text => |s| s.len == 1 and s[0] == ' ' and !ev.mods.ctrl and !ev.mods.alt and !ev.mods.shift,
                                            else => false,
                                        };
                                        const pressed_enter: bool = keyEventIsNamed(ev, .enter) and !ev.mods.ctrl and !ev.mods.alt and !ev.mods.shift;
                                        if (pressed_space or pressed_enter) {
                                            consumed = true;
                                            try ui.activateActionForId(&log_sink, child_in, focused_id.?);
                                            need_backend_flush = true;
                                            requested_reason = .input;
                                        }
                                    },
                                };
                            }

                            if (!consumed and !focused_is_text_edit) {
                                try sendKeyEventToBackend(&log_sink, child_in, ev);
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
            }

            if (exit_now) break;

            if (requested_reason == null and backend_events != 0 and (fds[fd_backend_out].revents & std.posix.POLL.IN) != 0) {
                const n = patch_lr.readMore() catch |e| {
                    if (e == error.LineTooLong) {
                        log.logPrint(&log_sink, "PATCH_ERR reason=line_too_long\n", .{});
                        continue;
                    }
                    return e;
                };
                if (n == 0) break;
                log.logPrint(&log_sink, "PATCH_RX bytes={d}\n", .{n});
            }
        }

        try maybeSendPendingResizeEvent(&log_sink, child_in, &pending_resize, &last_resize_tx_ns);

        if (requested_reason == null) {
            var sched_changed = false;
            var drained: usize = 0;
            while (drained < timing.max_backend_lines_per_iter) {
                const line = patch_lr.nextLine() orelse break;
                drained += 1;

                var next_arena = std.heap.ArenaAllocator.init(allocator);
                defer next_arena.deinit();

                const line_owned = next_arena.allocator().dupe(u8, line) catch |e| {
                    log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
                    continue;
                };

                const msg = protocol.parseMsgLeaky(next_arena.allocator(), line_owned) catch |e| {
                    if (e == error.UnknownPatchMode) {
                        log.logPrint(&log_sink, "PATCH_ERR reason=unknown_mode\n", .{});
                    } else {
                        log.logPrint(&log_sink, "PATCH_ERR reason={s}\n", .{@errorName(e)});
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
                                log.logPrint(
                                    &log_sink,
                                    "SCHED_DROP reason=no_root target={s}\n",
                                    .{t.target},
                                );
                                continue;
                            }

                            const r = try sched.putTargetLeaky(&next_arena, t.target, t.node, t.mode);
                            switch (r) {
                                .dropped_overflow => {
                                    log.logPrint(
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
        }

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
                try renderer.draw(&term, current_root.?, rs);
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
        }}),
        .backend_closed => log.logPrint(&log_sink, "EXIT reason=backend_closed\n", .{}),
        .normal => {},
    }
}
