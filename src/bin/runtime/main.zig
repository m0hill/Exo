const std = @import("std");

const tui = @import("tui");
const app = @import("app.zig");

fn crashPanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    tui.terminal.restoreBestEffort();
    std.debug.defaultPanic(msg, first_trace_addr);
}

pub const panic = std.debug.FullPanic(crashPanic);

pub fn main() !void {
    app.run() catch |e| switch (e) {
        error.BrokenPipe, error.WriteFailed => return,
        else => return e,
    };
}
