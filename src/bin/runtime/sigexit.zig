const std = @import("std");

pub const ExitSignal = enum {
    sigint,
    sigterm,
};

pub var sig_w_fd: std.posix.fd_t = -1;

fn handler(sig: c_int) callconv(.c) void {
    if (sig_w_fd < 0) return;
    const b: [1]u8 = .{@as(u8, @intCast(sig))};
    _ = std.posix.system.write(sig_w_fd, &b, 1);
}

pub fn installSigintSigtermHandlers() void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = handler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

pub fn drainPipe(fd: std.posix.fd_t) ?ExitSignal {
    var saw_int: bool = false;
    var saw_term: bool = false;

    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch |e| switch (e) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
        for (buf[0..n]) |b| {
            if (b == @as(u8, @intCast(std.posix.SIG.INT))) saw_int = true;
            if (b == @as(u8, @intCast(std.posix.SIG.TERM))) saw_term = true;
        }
    }

    if (saw_term) return .sigterm;
    if (saw_int) return .sigint;
    return null;
}
