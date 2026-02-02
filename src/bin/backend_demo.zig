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
        "{{\"type\":\"patch\",\"root\":{{\"type\":\"vbox\",\"id\":\"root\",\"children\":[" ++ "{{\"type\":\"text\",\"id\":\"title\",\"text\":\"Tracer Demo\"}}," ++ "{{\"type\":\"text\",\"id\":\"hint\",\"text\":\"Tab to focus input, type, q toggles, x exits\"}}," ++ "{{\"type\":\"text\",\"id\":\"clock\",\"text\":\"Tick: {d}\"}}," ++ "{{\"type\":\"input\",\"id\":\"query\",\"placeholder\":\"Type here\"}}," ++ "{{\"type\":\"text\",\"id\":\"status\",\"text\":\"State: {s}\"}}" ++ "]}}}}\n",
        .{ tick, state_str },
    );
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
    return buf.items;
}
