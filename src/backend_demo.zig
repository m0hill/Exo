const std = @import("std");
const jsonl = @import("jsonl.zig");
const protocol = @import("protocol.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.fs.File.stdout().writerStreaming(&stdout_buf);
    const out = &stdout_w.interface;

    var state_on = false;
    try emitPatch(out, state_on);
    try out.flush();

    var stdin_buf: [4096]u8 = undefined;
    var stdin_r = std.fs.File.stdin().readerStreaming(&stdin_buf);
    var lr = jsonl.LineReader.init(allocator, &stdin_r.interface, 1024 * 1024);
    defer lr.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    while (true) {
        if (lr.nextLine()) |line| {
            _ = arena.reset(.retain_capacity);
            const msg = protocol.parseMsgLeaky(arena.allocator(), line) catch |e| {
                std.debug.print("backend_demo: EVENT_ERR {s}\n", .{@errorName(e)});
                continue;
            };
            switch (msg) {
                .event => |ev| {
                    if (!std.mem.eql(u8, ev.name, "key")) continue;
                    if (std.mem.eql(u8, ev.key, "q")) {
                        state_on = !state_on;
                        try emitPatch(out, state_on);
                        try out.flush();
                    } else if (std.mem.eql(u8, ev.key, "x") or std.mem.eql(u8, ev.key, "ctrl-c")) {
                        return;
                    }
                },
                else => {},
            }
        } else {
            const n = lr.readMore() catch |e| {
                if (e == error.LineTooLong) {
                    std.debug.print("backend_demo: EVENT_ERR line_too_long\n", .{});
                    continue;
                }
                return e;
            };
            if (n == 0) return;
        }
    }
}

fn emitPatch(writer: anytype, state_on: bool) !void {
    const state_str = if (state_on) "ON" else "OFF";
    try writer.print(
        "{{\"type\":\"patch\",\"root\":{{\"type\":\"vbox\",\"id\":\"root\",\"children\":[{{\"type\":\"text\",\"id\":\"title\",\"text\":\"Tracer Demo\"}},{{\"type\":\"text\",\"id\":\"hint\",\"text\":\"Press q to toggle, x to exit\"}},{{\"type\":\"text\",\"id\":\"state\",\"text\":\"State: {s}\"}}]}}}}\n",
        .{state_str},
    );
}
