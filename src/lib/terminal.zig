const std = @import("std");

pub const Size = @import("term_size.zig").Size;

pub const Terminal = struct {
    stdin_fd: std.posix.fd_t,
    stdout_fd: std.posix.fd_t,
    orig_termios: std.posix.termios,
    raw_enabled: bool = false,
    screen_enabled: bool = false,
    mouse_enabled: bool = false,

    pub fn init() !Terminal {
        const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;
        const stdout_fd: std.posix.fd_t = std.posix.STDOUT_FILENO;

        if (!std.posix.isatty(stdin_fd) or !std.posix.isatty(stdout_fd)) return error.NotATty;
        if (!std.posix.isatty(stdout_fd)) return error.NotATty;

        var t: Terminal = .{
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .orig_termios = try std.posix.tcgetattr(stdin_fd),
        };
        errdefer t.deinit();

        var raw = t.orig_termios;

        // Disable input flags: break handling, parity, strip, newline conversion, flow control
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.IXOFF = false;
        raw.iflag.IXANY = false;

        // Disable output post-processing
        raw.oflag.OPOST = false;

        // Disable local flags: echo, canonical mode, signals, extended input
        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Set 8-bit chars, disable parity
        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        // Read returns after 1 byte, no timeout
        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;

        try std.posix.tcsetattr(stdin_fd, .FLUSH, raw);
        t.raw_enabled = true;

        try t.writeAll("\x1b[?1049h"); // alt screen
        try t.writeAll("\x1b[?25l"); // hide cursor
        // Enable SGR mouse reporting (Tracer 13).
        try t.writeAll("\x1b[?1000h"); // basic mouse press/release
        try t.writeAll("\x1b[?1006h"); // SGR extended coordinates
        t.screen_enabled = true;
        t.mouse_enabled = true;
        return t;
    }

    pub fn deinit(self: *Terminal) void {
        if (self.screen_enabled) {
            if (self.mouse_enabled) {
                _ = self.writeAll("\x1b[?1006l") catch {};
                _ = self.writeAll("\x1b[?1000l") catch {};
                self.mouse_enabled = false;
            }
            _ = self.writeAll("\x1b[?25h") catch {};
            _ = self.writeAll("\x1b[?1049l") catch {};
            self.screen_enabled = false;
        }
        if (self.raw_enabled) {
            std.posix.tcsetattr(self.stdin_fd, .FLUSH, self.orig_termios) catch {};
            self.raw_enabled = false;
        }
    }

    pub fn getSize(self: *Terminal) !Size {
        var ws: std.posix.winsize = undefined;
        const request: c_int = @intCast(std.posix.T.IOCGWINSZ);
        const rc = std.posix.system.ioctl(self.stdout_fd, request, @intFromPtr(&ws));
        if (rc != 0) return error.IoctlFailed;
        return .{ .rows = ws.row, .cols = ws.col };
    }

    pub fn readByte(self: *Terminal) !u8 {
        var b: [1]u8 = undefined;
        const n = try std.posix.read(self.stdin_fd, &b);
        if (n == 0) return error.EndOfStream;
        return b[0];
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try std.posix.write(self.stdout_fd, bytes[off..]);
            off += n;
        }
    }
};
