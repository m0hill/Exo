const std = @import("std");
const tui = @import("tui");
const jsonl = tui.jsonl;
const protocol = tui.protocol;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_w.interface;

    var focus_id: std.ArrayList(u8) = .empty;
    defer focus_id.deinit(allocator);

    var inputs = [_]InputSlot{
        .{ .id = "query-a" },
        .{ .id = "query-b" },
    };
    defer {
        for (&inputs) |*s| s.last.deinit(allocator);
    }

    var lists = [_]ListSlot{
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

    try initItems(allocator, &lists[0].items, 1, 20);
    try initItems(allocator, &lists[1].items, 1001, 1020);

    var state_on = false;
    var tick: u64 = 0;
    {
        var tick_buf: [64]u8 = undefined;
        const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
        const status_text = try buildStatusText(
            allocator,
            &status_buf,
            state_on,
            inputs[0..],
            lists[0..],
            focus_id.items,
            term_rows,
            term_cols,
        );
        try emitInitialFull(out, tick_text, status_text, inputs[0..], lists[0..], list_height);
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

        const rc = try std.posix.poll(fds[0..], 250);
        if (rc == 0) {
            tick += 1;
            std.debug.print("PATCH_TX target=clock tick={d}\n", .{tick});
            var tick_buf: [64]u8 = undefined;
            const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
            try emitTextPatchById(out, "clock", tick_text);

            updateItems(allocator, &lists[0], tick);
            updateItems(allocator, &lists[1], tick + 2);

            std.debug.print(
                "PATCH_TX target={s} mode=morph items={d} tick={d}\n",
                .{ lists[0].id, lists[0].items.items.len, tick },
            );
            try emitListMorphPatch(out, lists[0].id, lists[0].items.items, list_height);

            std.debug.print(
                "PATCH_TX target={s} mode=morph items={d} tick={d}\n",
                .{ lists[1].id, lists[1].items.items.len, tick },
            );
            try emitListMorphPatch(out, lists[1].id, lists[1].items.items, list_height);

            const status_text = try buildStatusText(
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
                std.debug.print("PATCH_TX target=root mode=morph tick={d}\n", .{tick});
                const layout_alt = (tick % 2) == 1;
                try emitRootMorphPatch(out, tick_text, status_text, inputs[0..], lists[0..], layout_alt, list_height);
            }

            // Keep status fresh so selection/activation changes show up even while idle.
            std.debug.print("PATCH_TX target=status\n", .{});
            try emitTextPatchById(out, "status", status_text);

            try out.flush();
            continue;
        }

        if ((fds[0].revents & (std.posix.POLL.HUP | std.posix.POLL.ERR | std.posix.POLL.NVAL)) != 0) return;
        if ((fds[0].revents & std.posix.POLL.IN) == 0) continue;

        const n = lr.readMore() catch |e| {
            if (e == error.LineTooLong) {
                std.debug.print("backend_demo: EVENT_ERR line_too_long\n", .{});
                continue;
            }
            return e;
        };
        if (n == 0) return;

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
                            const status_text = try buildStatusText(
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
                            try emitTextPatchById(out, "status", status_text);
                            try out.flush();
                        } else if (std.mem.eql(u8, k.key, "x") or std.mem.eql(u8, k.key, "ctrl-c")) {
                            return;
                        }
                    },
                    .focus => |f| {
                        std.debug.print("EVENT_RX name=focus id={s}\n", .{f.id});
                        focus_id.clearRetainingCapacity();
                        if (f.id.len > 0) try focus_id.appendSlice(allocator, f.id);
                        const status_text = try buildStatusText(
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
                        try emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .input => |inp| {
                        std.debug.print(
                            "EVENT_RX name=input id={s} len={d} cursor={d}\n",
                            .{ inp.id, inp.value.len, inp.cursor },
                        );
                        if (findInputSlot(inputs[0..], inp.id)) |slot| {
                            slot.last.clearRetainingCapacity();
                            try slot.last.appendSlice(allocator, inp.value);
                        }

                        const status_text = try buildStatusText(
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
                        try emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .select => |s| {
                        std.debug.print("EVENT_RX name=select id={s} item={s}\n", .{ s.id, s.item });
                        if (findListSlot(lists[0..], s.id)) |slot| {
                            slot.selected.clearRetainingCapacity();
                            if (s.item.len > 0) try slot.selected.appendSlice(allocator, s.item);
                        }
                        const status_text = try buildStatusText(
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
                        try emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .activate => |a| {
                        std.debug.print("EVENT_RX name=activate id={s} item={s}\n", .{ a.id, a.item });
                        if (findListSlot(lists[0..], a.id)) |slot| {
                            slot.activated.clearRetainingCapacity();
                            if (a.item.len > 0) try slot.activated.appendSlice(allocator, a.item);
                        }
                        const status_text = try buildStatusText(
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
                        try emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .resize => |r| {
                        std.debug.print("EVENT_RX name=resize rows={d} cols={d}\n", .{ r.rows, r.cols });
                        term_rows = r.rows;
                        term_cols = r.cols;

                        const status_text = try buildStatusText(
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
                        try emitTextPatchById(out, "status", status_text);

                        try out.flush();
                    },
                },
                else => {},
            }
        }
    }
}

const InputSlot = struct {
    id: []const u8,
    last: std.ArrayList(u8) = .empty,
};

const ListSlot = struct {
    id: []const u8,
    selected: std.ArrayList(u8) = .empty,
    activated: std.ArrayList(u8) = .empty,
    items: std.ArrayList(u64) = .empty,
    next_item_id: u64,
};

fn emitInitialFull(
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    inputs: []const InputSlot,
    lists: []const ListSlot,
    list_height: usize,
) !void {
    try writer.writeAll("{\"type\":\"patch\",\"root\":");
    try writeRootNode(writer, tick_text, status_text, inputs, lists, false, list_height);
    try writer.writeAll("}\n");
}

fn emitRootMorphPatch(
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    inputs: []const InputSlot,
    lists: []const ListSlot,
    layout_alt: bool,
    list_height: usize,
) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":\"root\",\"mode\":\"morph\",\"node\":");
    try writeRootNode(writer, tick_text, status_text, inputs, lists, layout_alt, list_height);
    try writer.writeAll("}\n");
}

fn writeTextNode(writer: anytype, id: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, id);
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeByte('}');
}

fn writeTextNodeLayout(
    writer: anytype,
    id: []const u8,
    text: []const u8,
    w: ?usize,
    h: ?usize,
    flex: usize,
) !void {
    try writer.writeAll("{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (h) |vh| try writer.print(",\"h\":{d}", .{vh});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeByte('}');
}

fn writeInputNode(writer: anytype, id: []const u8, placeholder: []const u8) !void {
    try writer.writeAll("{\"type\":\"input\",\"id\":");
    try protocol.writeJsonString(writer, id);
    try writer.writeAll(",\"placeholder\":");
    try protocol.writeJsonString(writer, placeholder);
    try writer.writeByte('}');
}

fn writeInputNodeLayout(writer: anytype, id: []const u8, placeholder: []const u8, w: ?usize, h: ?usize, flex: usize) !void {
    try writer.writeAll("{\"type\":\"input\",\"id\":");
    try protocol.writeJsonString(writer, id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (h) |vh| try writer.print(",\"h\":{d}", .{vh});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
    try writer.writeAll(",\"placeholder\":");
    try protocol.writeJsonString(writer, placeholder);
    try writer.writeByte('}');
}

fn emitListMorphPatch(writer: anytype, list_id: []const u8, items: []const u64, height: usize) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, list_id);
    try writer.writeAll(",\"mode\":\"morph\",\"node\":");
    try writeListNode(writer, list_id, height, items);
    try writer.writeAll("}\n");
}

fn emitTextPatchById(writer: anytype, target: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"node\":{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"h\":1");
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeAll("}}\n");
}

fn buildStatusText(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    state_on: bool,
    inputs: []const InputSlot,
    lists: []const ListSlot,
    focus: []const u8,
    term_rows: ?usize,
    term_cols: ?usize,
) ![]const u8 {
    buf.clearRetainingCapacity();
    const w = buf.writer(allocator);
    const state_str = if (state_on) "ON" else "OFF";
    try w.print("State: {s}", .{state_str});
    if (term_rows != null and term_cols != null) {
        try w.print(" | Size: {d}x{d}", .{ term_rows.?, term_cols.? });
    }
    if (focus.len > 0) {
        try w.print(" | Focus: {s}", .{focus});
    }
    for (inputs) |in| {
        if (in.last.items.len > 0) {
            try w.print(" | {s}: {s}", .{ in.id, in.last.items });
        }
    }
    for (lists) |ls| {
        if (ls.selected.items.len > 0) {
            try w.print(" | {s} sel={s}", .{ ls.id, ls.selected.items });
        }
        if (ls.activated.items.len > 0) {
            try w.print(" act={s}", .{ls.activated.items});
        }
    }
    return buf.items;
}

fn initItems(allocator: std.mem.Allocator, items: *std.ArrayList(u64), start: u64, end_inclusive: u64) !void {
    var n: u64 = start;
    while (n <= end_inclusive) : (n += 1) {
        try items.append(allocator, n);
    }
}

fn updateItems(allocator: std.mem.Allocator, slot: *ListSlot, tick: u64) void {
    if ((tick % 3) == 0) {
        const id = slot.next_item_id;
        slot.next_item_id += 1;
        _ = slot.items.insert(allocator, 0, id) catch {};
    }

    if (slot.items.items.len > 40) {
        _ = slot.items.pop();
    }

    if (slot.items.items.len >= 2 and (tick % 5) == 1) {
        const tmp = slot.items.items[0];
        slot.items.items[0] = slot.items.items[1];
        slot.items.items[1] = tmp;
    }

    if (slot.items.items.len >= 2 and (tick % 7) == 2) {
        const first = slot.items.items[0];
        var i: usize = 0;
        while (i + 1 < slot.items.items.len) : (i += 1) {
            slot.items.items[i] = slot.items.items[i + 1];
        }
        slot.items.items[slot.items.items.len - 1] = first;
    }
}

fn findInputSlot(inputs: []InputSlot, id: []const u8) ?*InputSlot {
    for (inputs) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

fn findListSlot(lists: []ListSlot, id: []const u8) ?*ListSlot {
    for (lists) |*s| {
        if (std.mem.eql(u8, s.id, id)) return s;
    }
    return null;
}

fn writeRootNode(
    writer: anytype,
    tick_text: []const u8,
    status_text: []const u8,
    inputs: []const InputSlot,
    lists: []const ListSlot,
    layout_alt: bool,
    list_height: usize,
) !void {
    try writer.writeAll("{\"type\":\"vbox\",\"id\":\"root\",\"children\":[");
    try writeTextNodeLayout(writer, "title", "Tracer Demo", null, 1, 0);
    try writer.writeByte(',');
    try writeTextNodeLayout(
        writer,
        "hint",
        "Unicode demo: e\u{0301} 漢 🇯🇵 👩‍👩‍👧‍👦\nTab cycles focus by tree order. Arrows/Home/End edit inputs. Alt-b/Alt-f word jump. j/k moves list. Enter activates. q toggles. x exits.\nMake the terminal narrow to see this line soft-wrap on typical widths without any backend changes.",
        null,
        3,
        0,
    );
    try writer.writeByte(',');
    try writeTextNodeLayout(writer, "clock", tick_text, null, 1, 0);
    try writer.writeByte(',');

    try writer.writeAll("{\"type\":\"hbox\",\"id\":\"body\",\"flex\":1,\"pad\":1,\"clip\":true,\"children\":[");
    if (!layout_alt) {
        try writePanelNode(
            writer,
            "panel-a",
            "Panel A",
            inputs[0].id,
            lists[0].id,
            lists[0].items.items,
            status_text,
            list_height,
            30,
            0,
        );
        try writer.writeByte(',');
        try writePanelNode(
            writer,
            "panel-b",
            "Panel B",
            inputs[1].id,
            lists[1].id,
            lists[1].items.items,
            status_text,
            list_height,
            null,
            1,
        );
    } else {
        try writePanelNode(
            writer,
            "panel-b",
            "Panel B",
            inputs[1].id,
            lists[1].id,
            lists[1].items.items,
            status_text,
            list_height,
            null,
            1,
        );
        try writer.writeByte(',');
        try writePanelNode(
            writer,
            "panel-a",
            "Panel A",
            inputs[0].id,
            lists[0].id,
            lists[0].items.items,
            status_text,
            list_height,
            30,
            0,
        );
    }
    try writer.writeAll("]}");

    try writer.writeByte(',');
    try writeTextNodeLayout(writer, "status", status_text, null, 1, 0);
    try writer.writeAll("]}");
}

fn writePanelNode(
    writer: anytype,
    panel_id: []const u8,
    title: []const u8,
    input_id: []const u8,
    list_id: []const u8,
    list_items: []const u64,
    status_text: []const u8,
    list_height: usize,
    w: ?usize,
    flex: usize,
) !void {
    try writer.writeAll("{\"type\":\"vbox\",\"id\":");
    try protocol.writeJsonString(writer, panel_id);
    if (w) |vw| try writer.print(",\"w\":{d}", .{vw});
    if (flex != 0) try writer.print(",\"flex\":{d}", .{flex});
    try writer.writeAll(",\"pad\":1,\"clip\":true,\"children\":[");

    var title_id_buf: [64]u8 = undefined;
    const title_id = try std.fmt.bufPrint(&title_id_buf, "{s}-title", .{panel_id});
    try writeTextNode(writer, title_id, title);
    try writer.writeByte(',');
    if (std.mem.eql(u8, panel_id, "panel-a")) {
        try writeTextNodeLayout(
            writer,
            "panel-a-long",
            "This long line should be clipped inside Panel A. It must not overwrite the other column when the terminal is narrow.",
            null,
            2,
            0,
        );
        try writer.writeByte(',');
    } else {
        try writeTextNodeLayout(writer, "panel-b-status", status_text, null, 2, 0);
        try writer.writeByte(',');
    }
    try writeInputNodeLayout(writer, input_id, "Type here: e\u{0301} 漢 🇯🇵", null, 1, 0);
    try writer.writeByte(',');
    try writeListNode(writer, list_id, list_height, list_items);

    try writer.writeAll("]}");
}

fn writeListNode(writer: anytype, list_id: []const u8, height: usize, items: []const u64) !void {
    try writer.writeAll("{\"type\":\"list\",\"id\":");
    try protocol.writeJsonString(writer, list_id);
    try writer.writeAll(",\"height\":");
    try writer.print("{d}", .{height});
    try writer.writeAll(",\"children\":[");

    for (items, 0..) |n, idx| {
        if (idx != 0) try writer.writeByte(',');
        var id_buf: [96]u8 = undefined;
        const item_id = try std.fmt.bufPrint(&id_buf, "{s}-item-{d}", .{ list_id, n });
        var text_buf: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "Item {d}", .{n});
        try writeTextNode(writer, item_id, text);
    }

    try writer.writeAll("]}");
}
