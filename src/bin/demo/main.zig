const std = @import("std");

const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;

const args_mod = @import("args.zig");
const render = @import("render.zig");
const state = @import("state.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    const cfg = try args_mod.parseArgs(args);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_w.interface;

    var focus_id: std.ArrayList(u8) = .empty;
    defer focus_id.deinit(allocator);

    var inputs = [_]state.InputSlot{
        .{ .id = "query-a" },
        .{ .id = "query-b" },
    };
    defer {
        for (&inputs) |*s| s.last.deinit(allocator);
    }

    var lists = [_]state.ListSlot{
        .{ .id = "results-a", .next_item_id = 21 },
        .{ .id = "results-b", .next_item_id = 1021 },
    };
    defer {
        for (&lists) |*s| {
            s.selected.deinit(allocator);
            s.activated.deinit(allocator);
            s.items.deinit(allocator);
        }
    }

    var status_buf: std.ArrayList(u8) = .empty;
    defer status_buf.deinit(allocator);

    var term_rows: ?usize = null;
    var term_cols: ?usize = null;
    const list_height: usize = 8;

    try state.initItems(allocator, &lists[0].items, 1, 20);
    try state.initItems(allocator, &lists[1].items, 1001, 1020);

    var state_on = false;
    var tick: u64 = 0;
    {
        var tick_buf: [64]u8 = undefined;
        const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
        const status_text = try state.buildStatusText(
            allocator,
            &status_buf,
            state_on,
            inputs[0..],
            lists[0..],
            focus_id.items,
            term_rows,
            term_cols,
        );
        try render.emitInitialFull(out, tick_text, status_text, inputs[0..], lists[0..], list_height);
    }
    try out.flush();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.fs.File.stdin().readerStreaming(&stdin_buf);
    var lr = jsonl.LineReader.init(allocator, &stdin_r.interface, 1024 * 1024);
    defer lr.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const rc = try std.posix.poll(fds[0..], cfg.tick_interval_ms);
        if (rc == 0) {
            var tick_buf: [64]u8 = undefined;
            var tick_text: []const u8 = "";
            {
                var i: usize = 0;
                while (i < cfg.flood_burst) : (i += 1) {
                    tick += 1;
                    if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=clock tick={d}\n", .{tick});
                    tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
                    try render.emitTextPatchById(out, "clock", tick_text);

                    state.updateItems(allocator, &lists[0], tick);
                    state.updateItems(allocator, &lists[1], tick + 2);

                    if (!cfg.quiet_tx) {
                        std.debug.print(
                            "PATCH_TX target={s} mode=morph items={d} tick={d}\n",
                            .{ lists[0].id, lists[0].items.items.len, tick },
                        );
                    }
                    try render.emitListMorphPatch(out, lists[0].id, lists[0].items.items, list_height);

                    if (!cfg.quiet_tx) {
                        std.debug.print(
                            "PATCH_TX target={s} mode=morph items={d} tick={d}\n",
                            .{ lists[1].id, lists[1].items.items.len, tick },
                        );
                    }
                    try render.emitListMorphPatch(out, lists[1].id, lists[1].items.items, list_height);
                }
            }

            const status_text = try state.buildStatusText(
                allocator,
                &status_buf,
                state_on,
                inputs[0..],
                lists[0..],
                focus_id.items,
                term_rows,
                term_cols,
            );

            if ((tick % 4) == 0) {
                if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=root mode=morph tick={d}\n", .{tick});
                const layout_alt = (tick % 2) == 1;
                try render.emitRootMorphPatch(out, tick_text, status_text, inputs[0..], lists[0..], layout_alt, list_height);
            }

            if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=status\n", .{});
            try render.emitTextPatchById(out, "status", status_text);

            try out.flush();
            continue;
        }

        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return;
        }

        while (lr.nextLine()) |line| {
            _ = arena.reset(.retain_capacity);
            const msg = protocol.parseMsgLeaky(arena.allocator(), line) catch |e| {
                std.debug.print("backend_demo: EVENT_ERR {s}\n", .{@errorName(e)});
                continue;
            };

            switch (msg) {
                .event => |ev| switch (ev) {
                    .key => |k| {
                        std.debug.print("EVENT_RX name=key key={s}\n", .{k.key});
                        if (std.mem.eql(u8, k.key, "q")) {
                            state_on = !state_on;
                            const status_text = try state.buildStatusText(
                                allocator,
                                &status_buf,
                                state_on,
                                inputs[0..],
                                lists[0..],
                                focus_id.items,
                                term_rows,
                                term_cols,
                            );
                            std.debug.print("PATCH_TX target=status\n", .{});
                            try render.emitTextPatchById(out, "status", status_text);
                            try out.flush();
                        } else if (std.mem.eql(u8, k.key, "x") or std.mem.eql(u8, k.key, "ctrl-c")) {
                            return;
                        }
                    },
                    .focus => |f| {
                        std.debug.print("EVENT_RX name=focus id={s}\n", .{f.id});
                        focus_id.clearRetainingCapacity();
                        if (f.id.len > 0) try focus_id.appendSlice(allocator, f.id);
                        const status_text = try state.buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            inputs[0..],
                            lists[0..],
                            focus_id.items,
                            term_rows,
                            term_cols,
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try render.emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .input => |inp| {
                        std.debug.print(
                            "EVENT_RX name=input id={s} len={d} cursor={d}\n",
                            .{ inp.id, inp.value.len, inp.cursor },
                        );
                        if (state.findInputSlot(inputs[0..], inp.id)) |slot| {
                            slot.last.clearRetainingCapacity();
                            try slot.last.appendSlice(allocator, inp.value);
                        }

                        const status_text = try state.buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            inputs[0..],
                            lists[0..],
                            focus_id.items,
                            term_rows,
                            term_cols,
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try render.emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .select => |s| {
                        std.debug.print("EVENT_RX name=select id={s} item={s}\n", .{ s.id, s.item });
                        if (state.findListSlot(lists[0..], s.id)) |slot| {
                            slot.selected.clearRetainingCapacity();
                            if (s.item.len > 0) try slot.selected.appendSlice(allocator, s.item);
                        }
                        const status_text = try state.buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            inputs[0..],
                            lists[0..],
                            focus_id.items,
                            term_rows,
                            term_cols,
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try render.emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .activate => |a| {
                        std.debug.print("EVENT_RX name=activate id={s} item={s}\n", .{ a.id, a.item });
                        if (state.findListSlot(lists[0..], a.id)) |slot| {
                            slot.activated.clearRetainingCapacity();
                            if (a.item.len > 0) try slot.activated.appendSlice(allocator, a.item);
                        }
                        const status_text = try state.buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            inputs[0..],
                            lists[0..],
                            focus_id.items,
                            term_rows,
                            term_cols,
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try render.emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .resize => |r| {
                        std.debug.print("EVENT_RX name=resize rows={d} cols={d}\n", .{ r.rows, r.cols });
                        term_rows = r.rows;
                        term_cols = r.cols;

                        const status_text = try state.buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            inputs[0..],
                            lists[0..],
                            focus_id.items,
                            term_rows,
                            term_cols,
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try render.emitTextPatchById(out, "status", status_text);

                        try out.flush();
                    },
                },
                else => {},
            }
        }
    }
}
