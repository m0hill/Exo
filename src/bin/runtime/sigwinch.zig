const std = @import("std");

pub var winch_w_fd: std.posix.fd_t = -1;

fn sigwinchHandler(_: c_int) callconv(.c) void {
    if (winch_w_fd < 0) return;
    const b: [1]u8 = .{0};
    _ = std.posix.system.write(winch_w_fd, &b, 1);
}

pub fn setFdNonBlocking(fd: std.posix.fd_t) void {
    var fl_flags = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch return;
    fl_flags |= 1 << @bitOffsetOf(std.posix.O, "NONBLOCK");
    _ = std.posix.fcntl(fd, std.posix.F.SETFL, fl_flags) catch return;
}

pub fn installSigwinchHandler() void {
    var sa: std.posix.Sigaction = .{
        .handler = .{ .handler = sigwinchHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &sa, null);
}

pub fn drainPipe(fd: std.posix.fd_t) void {
    var buf: [64]u8 = undefined;
    while (true) {
        const n = std.posix.read(fd, &buf) catch |e| switch (e) {
            error.WouldBlock => break,
            else => break,
        };
        if (n == 0) break;
    }
}
