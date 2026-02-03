const std = @import("std");

const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;

const args_mod = @import("args.zig");
const render = @import("render.zig");
const state = @import("state.zig");

const MD_STREAM_ID: []const u8 = "md-stream";
const MD_PROMPT_ID: []const u8 = "md-prompt";
const MD_ACTIONS_ID: []const u8 = "md-actions";
const MD_ACTION_START: []const u8 = "md-actions-start";
const MD_ACTION_PAUSE: []const u8 = "md-actions-pause";
const MD_ACTION_RESET: []const u8 = "md-actions-reset";

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
        .{ .id = MD_PROMPT_ID },
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

    var md_buf: std.ArrayList(u8) = .empty;
    defer md_buf.deinit(allocator);
    var md_source: std.ArrayList(u8) = .empty;
    defer md_source.deinit(allocator);
    var md_cursor: usize = 0;
    var md_active: bool = false;
    var md_paused: bool = false;

    const md_default =
        "# Streaming markdown demo\n" ++
        "\n" ++
        "Backend appends chunks to a buffer, recompiles the whole document, and sends a `mode=morph` patch.\n" ++
        "\n" ++
        "- **Bold** and *italic* work once delimiters close\n" ++
        "- Inline `code` stays literal inside backticks\n" ++
        "> This is how Claude/Codex-style TUIs can render streaming responses.\n";

    var term_rows: ?usize = null;
    var term_cols: ?usize = null;
    const list_height: usize = 8;

    var arena_tx = std.heap.ArenaAllocator.init(allocator);
    defer arena_tx.deinit();

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
        _ = arena_tx.reset(.retain_capacity);
        try render.emitInitialFull(
            arena_tx.allocator(),
            out,
            tick_text,
            status_text,
            md_buf.items,
            inputs[0..],
            lists[0..],
            list_height,
        );
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
                    try render.emitTextPatchByIdStyled(out, "clock", tick_text, "{\"fg\":\"#22c55e\",\"bold\":true}");

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
                _ = arena_tx.reset(.retain_capacity);
                try render.emitRootMorphPatch(
                    arena_tx.allocator(),
                    out,
                    tick_text,
                    status_text,
                    md_buf.items,
                    inputs[0..],
                    lists[0..],
                    layout_alt,
                    list_height,
                );
            }

            if (!cfg.quiet_tx) std.debug.print("PATCH_TX target=status\n", .{});
            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");

            if (md_active and !md_paused and md_cursor < md_source.items.len) {
                const chunk_len: usize = 24;
                const next = @min(md_source.items.len, md_cursor + chunk_len);
                if (next > md_cursor) {
                    try md_buf.appendSlice(allocator, md_source.items[md_cursor..next]);
                    md_cursor = next;
                    _ = arena_tx.reset(.retain_capacity);
                    if (!cfg.quiet_tx) std.debug.print(
                        "PATCH_TX target={s} mode=morph bytes={d}\n",
                        .{ MD_STREAM_ID, md_buf.items.len },
                    );
                    try render.emitMarkdownMorphPatch(arena_tx.allocator(), out, MD_STREAM_ID, md_buf.items);
                }
                if (md_cursor >= md_source.items.len) md_active = false;
            }

            try out.flush();
            continue;
        }

        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) {
            return;
        }

        _ = lr.readMore() catch |e| {
            if (e == error.LineTooLong) {
                std.debug.print("backend_demo: EVENT_ERR line_too_long\n", .{});
                continue;
            }
            return e;
        };

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
                            try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
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
                        try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                        try out.flush();
                    },
                    .input => |inp| {
                        std.debug.print(
                            "EVENT_RX name=input id={s} len={d} cursor={d}\n",
                            .{ inp.id, inp.value.len, inp.cursor },
                        );
                        if (state.findInputSlot(inputs[0..], inp.id)) |slot| {
                            slot.last.clearRetainingCapacity();
                            slot.last_len = inp.value.len;
                            const cap: usize = if (std.mem.eql(u8, inp.id, MD_PROMPT_ID)) 32 * 1024 else 256;
                            const n = @min(inp.value.len, cap);

                            // Keep status output single-line and bounded.
                            if (!std.mem.eql(u8, inp.id, MD_PROMPT_ID)) {
                                var i: usize = 0;
                                while (i < n) : (i += 1) {
                                    const b = inp.value[i];
                                    const out_b: u8 = if (b < 0x20 or b == 0x7f) ' ' else b;
                                    try slot.last.append(allocator, out_b);
                                }
                            } else {
                                try slot.last.appendSlice(allocator, inp.value[0..n]);
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
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
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
                        try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
                        try out.flush();
                    },
                    .activate => |a| {
                        std.debug.print("EVENT_RX name=activate id={s} item={s}\n", .{ a.id, a.item });
                        if (std.mem.eql(u8, a.id, MD_ACTIONS_ID)) {
                            if (std.mem.eql(u8, a.item, MD_ACTION_START)) {
                                md_buf.clearRetainingCapacity();
                                md_source.clearRetainingCapacity();
                                md_cursor = 0;
                                md_active = true;
                                md_paused = false;

                                const prompt = if (state.findInputSlot(inputs[0..], MD_PROMPT_ID)) |slot|
                                    slot.last.items
                                else
                                    "";
                                if (prompt.len > 0) {
                                    try md_source.appendSlice(allocator, prompt);
                                } else {
                                    try md_source.appendSlice(allocator, md_default);
                                }

                                const chunk_len: usize = 24;
                                const next = @min(md_source.items.len, md_cursor + chunk_len);
                                if (next > md_cursor) {
                                    try md_buf.appendSlice(allocator, md_source.items[md_cursor..next]);
                                    md_cursor = next;
                                }
                                _ = arena_tx.reset(.retain_capacity);
                                try render.emitMarkdownMorphPatch(arena_tx.allocator(), out, MD_STREAM_ID, md_buf.items);
                                try out.flush();
                                continue;
                            } else if (std.mem.eql(u8, a.item, MD_ACTION_PAUSE)) {
                                if (md_active or md_cursor < md_source.items.len) md_paused = !md_paused;
                                continue;
                            } else if (std.mem.eql(u8, a.item, MD_ACTION_RESET)) {
                                md_buf.clearRetainingCapacity();
                                md_source.clearRetainingCapacity();
                                md_cursor = 0;
                                md_active = false;
                                md_paused = false;
                                _ = arena_tx.reset(.retain_capacity);
                                try render.emitMarkdownMorphPatch(arena_tx.allocator(), out, MD_STREAM_ID, md_buf.items);
                                try out.flush();
                                continue;
                            }
                        }
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
                        try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");
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
                        try render.emitTextPatchByIdStyled(out, "status", status_text, "{\"fg\":\"#fbbf24\"}");

                        try out.flush();
                    },
                },
                else => {},
            }
        }
    }
}
