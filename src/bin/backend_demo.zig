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

    var last_input: std.ArrayList(u8) = .empty;
    defer last_input.deinit(allocator);

    var focus_id: std.ArrayList(u8) = .empty;
    defer focus_id.deinit(allocator);

    var selected_item: std.ArrayList(u8) = .empty;
    defer selected_item.deinit(allocator);
    var activated_item: std.ArrayList(u8) = .empty;
    defer activated_item.deinit(allocator);

    var state_on = false;
    var tick: u64 = 0;
    try emitInitialFull(out, tick, state_on);
    try out.flush();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.fs.File.stdin().readerStreaming(&stdin_buf);
    var lr = jsonl.LineReader.init(allocator, &stdin_r.interface, 1024 * 1024);
    defer lr.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var status_buf: std.ArrayList(u8) = .empty;
    defer status_buf.deinit(allocator);

    var items: std.ArrayList(u64) = .empty;
    defer items.deinit(allocator);
    try initItems(allocator, &items);
    var next_item_id: u64 = 21;

    const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;

    while (true) {
        var fds = [_]std.posix.pollfd{
            .{ .fd = stdin_fd, .events = std.posix.POLL.IN, .revents = 0 },
        };

        const rc = try std.posix.poll(fds[0..], 250);
        if (rc == 0) {
            tick += 1;
            const status_text = try buildStatusText(
                allocator,
                &status_buf,
                state_on,
                last_input.items,
                focus_id.items,
                selected_item.items,
                activated_item.items,
            );

            std.debug.print("PATCH_TX target=clock tick={d}\n", .{tick});
            var tick_buf: [64]u8 = undefined;
            const tick_text = try std.fmt.bufPrint(&tick_buf, "Tick: {d}", .{tick});
            try emitTextPatchById(out, "clock", tick_text);

            updateItems(allocator, &items, &next_item_id, tick);
            std.debug.print("PATCH_TX target=results mode=morph items={d} tick={d}\n", .{ items.items.len, tick });
            try emitResultsMorphPatch(out, items.items, 8);

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
                                last_input.items,
                                focus_id.items,
                                selected_item.items,
                                activated_item.items,
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
                            last_input.items,
                            focus_id.items,
                            selected_item.items,
                            activated_item.items,
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
                        last_input.clearRetainingCapacity();
                        try last_input.appendSlice(allocator, inp.value);

                        const status_text = try buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            last_input.items,
                            focus_id.items,
                            selected_item.items,
                            activated_item.items,
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .select => |s| {
                        std.debug.print("EVENT_RX name=select id={s} item={s}\n", .{ s.id, s.item });
                        selected_item.clearRetainingCapacity();
                        if (s.item.len > 0) try selected_item.appendSlice(allocator, s.item);
                        const status_text = try buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            last_input.items,
                            focus_id.items,
                            selected_item.items,
                            activated_item.items,
                        );
                        std.debug.print("PATCH_TX target=status\n", .{});
                        try emitTextPatchById(out, "status", status_text);
                        try out.flush();
                    },
                    .activate => |a| {
                        std.debug.print("EVENT_RX name=activate id={s} item={s}\n", .{ a.id, a.item });
                        activated_item.clearRetainingCapacity();
                        if (a.item.len > 0) try activated_item.appendSlice(allocator, a.item);
                        const status_text = try buildStatusText(
                            allocator,
                            &status_buf,
                            state_on,
                            last_input.items,
                            focus_id.items,
                            selected_item.items,
                            activated_item.items,
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

fn emitInitialFull(writer: anytype, tick: u64, state_on: bool) !void {
    const state_str = if (state_on) "ON" else "OFF";
    try writer.print(
        "{{\"type\":\"patch\",\"root\":{{\"type\":\"vbox\",\"id\":\"root\",\"children\":[" ++
            "{{\"type\":\"text\",\"id\":\"title\",\"text\":\"Tracer Demo\"}}," ++
            "{{\"type\":\"text\",\"id\":\"hint\",\"text\":\"Tab cycles focus (query/results). j/k moves list. Enter activates. q toggles. x exits.\"}}," ++
            "{{\"type\":\"text\",\"id\":\"clock\",\"text\":\"Tick: {d}\"}}," ++
            "{{\"type\":\"input\",\"id\":\"query\",\"placeholder\":\"Type here\"}}," ++
            "{{\"type\":\"list\",\"id\":\"results\",\"height\":8,\"children\":[" ++
            "{{\"type\":\"text\",\"id\":\"item-1\",\"text\":\"Item 1\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-2\",\"text\":\"Item 2\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-3\",\"text\":\"Item 3\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-4\",\"text\":\"Item 4\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-5\",\"text\":\"Item 5\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-6\",\"text\":\"Item 6\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-7\",\"text\":\"Item 7\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-8\",\"text\":\"Item 8\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-9\",\"text\":\"Item 9\"}}," ++
            "{{\"type\":\"text\",\"id\":\"item-10\",\"text\":\"Item 10\"}}" ++
            "]}}," ++
            "{{\"type\":\"text\",\"id\":\"status\",\"text\":\"State: {s}\"}}" ++
            "]}}}}\n",
        .{ tick, state_str },
    );
}

fn writeTextNode(writer: anytype, id: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, id);
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

fn emitResultsMorphPatch(writer: anytype, items: []const u64, height: usize) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":\"results\",\"mode\":\"morph\",\"node\":{\"type\":\"list\",\"id\":\"results\",\"height\":");
    try writer.print("{d}", .{height});
    try writer.writeAll(",\"children\":[");

    for (items, 0..) |n, idx| {
        if (idx != 0) try writer.writeByte(',');
        var id_buf: [64]u8 = undefined;
        const item_id = try std.fmt.bufPrint(&id_buf, "item-{d}", .{n});
        var text_buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&text_buf, "Item {d}", .{n});
        try writeTextNode(writer, item_id, text);
    }

    try writer.writeAll("]}}\n");
}

fn emitTextPatchById(writer: anytype, target: []const u8, text: []const u8) !void {
    try writer.writeAll("{\"type\":\"patch\",\"target\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"node\":{\"type\":\"text\",\"id\":");
    try protocol.writeJsonString(writer, target);
    try writer.writeAll(",\"text\":");
    try protocol.writeJsonString(writer, text);
    try writer.writeAll("}}\n");
}

fn buildStatusText(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    state_on: bool,
    last_input: []const u8,
    focus: []const u8,
    selected_item: []const u8,
    activated_item: []const u8,
) ![]const u8 {
    buf.clearRetainingCapacity();
    const w = buf.writer(allocator);
    const state_str = if (state_on) "ON" else "OFF";
    try w.print("State: {s}", .{state_str});
    if (last_input.len > 0) {
        try w.print(" | Last: {s}", .{last_input});
    }
    if (focus.len > 0) {
        try w.print(" | Focus: {s}", .{focus});
    }
    if (selected_item.len > 0) {
        try w.print(" | Selected: {s}", .{selected_item});
    }
    if (activated_item.len > 0) {
        try w.print(" | Activated: {s}", .{activated_item});
    }
    return buf.items;
}

fn initItems(allocator: std.mem.Allocator, items: *std.ArrayList(u64)) !void {
    var n: u64 = 1;
    while (n <= 20) : (n += 1) {
        try items.append(allocator, n);
    }
}

fn updateItems(allocator: std.mem.Allocator, items: *std.ArrayList(u64), next_item_id: *u64, tick: u64) void {
    if ((tick % 3) == 0) {
        const id = next_item_id.*;
        next_item_id.* += 1;
        _ = items.insert(allocator, 0, id) catch {};
    }

    if (items.items.len > 40) {
        _ = items.pop();
    }

    if (items.items.len >= 2 and (tick % 5) == 1) {
        const tmp = items.items[0];
        items.items[0] = items.items[1];
        items.items[1] = tmp;
    }

    if (items.items.len >= 2 and (tick % 7) == 2) {
        const first = items.items[0];
        var i: usize = 0;
        while (i + 1 < items.items.len) : (i += 1) {
            items.items[i] = items.items[i + 1];
        }
        items.items[items.items.len - 1] = first;
    }
}
