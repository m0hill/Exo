const std = @import("std");

const termcaps = @import("termcaps.zig");

pub const Size = @import("term_size.zig").Size;

pub const CrashRestoreState = struct {
    stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    stdout_fd: std.posix.fd_t = std.posix.STDOUT_FILENO,
    orig_termios: std.posix.termios = undefined,
    have_orig_termios: bool = false,
    raw_enabled: bool = false,
    screen_enabled: bool = false,
    mouse_enabled_1000: bool = false,
    mouse_enabled_1006: bool = false,
    mouse_enabled_1002: bool = false,
    mouse_enabled_1003: bool = false,
    paste_enabled: bool = false,
};

var crash_state: CrashRestoreState = .{};
var crash_state_active: bool = false;
var crash_restore_in_progress: bool = false;

fn writeAllBestEffort(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.posix.system.write(fd, bytes[off..].ptr, bytes.len - off);
        if (rc <= 0) break;
        off += @as(usize, @intCast(rc));
    }
}

fn updateCrashStateFromTerminal(term: *const Terminal) void {
    crash_state = .{
        .stdin_fd = term.stdin_fd,
        .stdout_fd = term.stdout_fd,
        .orig_termios = term.orig_termios,
        .have_orig_termios = true,
        .raw_enabled = term.raw_enabled,
        .screen_enabled = term.screen_enabled,
        .mouse_enabled_1000 = term.mouse_enabled_1000,
        .mouse_enabled_1006 = term.mouse_enabled_1006,
        .mouse_enabled_1002 = term.mouse_enabled_1002,
        .mouse_enabled_1003 = term.mouse_enabled_1003,
        .paste_enabled = term.paste_enabled,
    };
    crash_state_active = true;
}

fn clearCrashState() void {
    crash_state_active = false;
}

/// Best-effort terminal restore for crash/panic paths.
///
/// - Idempotent: safe to call multiple times.
/// - Allocation-free and avoids std.io (writes escape codes via `write(2)`).
/// - Restores termios only if we previously captured it from `Terminal.init`.
pub fn restoreBestEffort() void {
    if (crash_restore_in_progress) return;
    crash_restore_in_progress = true;
    defer crash_restore_in_progress = false;

    const st: CrashRestoreState = if (crash_state_active) crash_state else .{};

    // Try to leave the terminal in a reasonable state even if we don't know
    // what was enabled.
    writeAllBestEffort(st.stdout_fd, "\x1b[?2004l"); // disable bracketed paste
    writeAllBestEffort(st.stdout_fd, "\x1b[?1003l"); // disable mouse motion
    writeAllBestEffort(st.stdout_fd, "\x1b[?1002l"); // disable mouse motion (button)
    writeAllBestEffort(st.stdout_fd, "\x1b[?1006l"); // disable SGR mouse
    writeAllBestEffort(st.stdout_fd, "\x1b[?1000l"); // disable mouse
    writeAllBestEffort(st.stdout_fd, "\x1b[?25h"); // show cursor
    writeAllBestEffort(st.stdout_fd, "\x1b[?1049l"); // leave alt screen

    if (st.have_orig_termios) {
        std.posix.tcsetattr(st.stdin_fd, .FLUSH, st.orig_termios) catch {};
    }
}

pub fn emergencyExit(code: u8) noreturn {
    restoreBestEffort();
    std.process.exit(code);
}

pub const Options = struct {};

pub const Terminal = struct {
    stdin_fd: std.posix.fd_t,
    stdout_fd: std.posix.fd_t,
    orig_termios: std.posix.termios,
    raw_enabled: bool = false,
    screen_enabled: bool = false,
    mouse_enabled_1000: bool = false,
    mouse_enabled_1006: bool = false,
    mouse_enabled_1002: bool = false,
    mouse_enabled_1003: bool = false,
    paste_enabled: bool = false,
    caps_: termcaps.Caps,

    pub fn init(allocator: std.mem.Allocator, _: Options) !Terminal {
        const stdin_fd: std.posix.fd_t = std.posix.STDIN_FILENO;
        const stdout_fd: std.posix.fd_t = std.posix.STDOUT_FILENO;

        if (!std.posix.isatty(stdin_fd) or !std.posix.isatty(stdout_fd)) return error.NotATty;

        var t: Terminal = .{
            .stdin_fd = stdin_fd,
            .stdout_fd = stdout_fd,
            .orig_termios = try std.posix.tcgetattr(stdin_fd),
            .caps_ = termcaps.detectCaps(allocator, false),
        };
        errdefer t.deinit();
        updateCrashStateFromTerminal(&t);

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
        updateCrashStateFromTerminal(&t);

        // Best-effort terminal capability probing (Device Attributes).
        // Responses are ignored by the input decoder.
        if (t.caps_.ansi) {
            _ = t.writeAll("\x1b[c\x1b[>c") catch {};
        }

        if (t.caps_.ansi and t.caps_.alt_screen) {
            try t.writeAll("\x1b[?1049h"); // alt screen
            t.screen_enabled = true;
            updateCrashStateFromTerminal(&t);
        }

        if (t.caps_.ansi and t.caps_.cursor_visibility) {
            try t.writeAll("\x1b[?25l"); // hide cursor
            updateCrashStateFromTerminal(&t);
        }

        if (t.caps_.ansi and t.caps_.bracketed_paste) {
            try t.writeAll("\x1b[?2004h"); // enable bracketed paste
            t.paste_enabled = true;
            updateCrashStateFromTerminal(&t);
        }

        return t;
    }

    pub fn caps(self: *const Terminal) termcaps.Caps {
        return self.caps_;
    }

    pub fn enableMouseBase(self: *Terminal) !void {
        if (!self.caps_.ansi or !self.caps_.mouse_sgr) return;
        if (!self.mouse_enabled_1000) {
            try self.writeAll("\x1b[?1000h"); // basic mouse press/release + wheel
            self.mouse_enabled_1000 = true;
        }
        if (!self.mouse_enabled_1006) {
            try self.writeAll("\x1b[?1006h"); // SGR extended coordinates
            self.mouse_enabled_1006 = true;
        }
        updateCrashStateFromTerminal(self);
    }

    pub fn disableMouseBase(self: *Terminal) !void {
        if (!self.caps_.ansi or !self.caps_.mouse_sgr) return;
        if (self.mouse_enabled_1006) {
            try self.writeAll("\x1b[?1006l");
            self.mouse_enabled_1006 = false;
        }
        if (self.mouse_enabled_1000) {
            try self.writeAll("\x1b[?1000l");
            self.mouse_enabled_1000 = false;
        }
        updateCrashStateFromTerminal(self);
    }

    pub fn enableMouseMotionAny(self: *Terminal) !void {
        if (!self.caps_.ansi or !self.caps_.mouse_sgr) return;
        if (self.mouse_enabled_1003) return;
        try self.writeAll("\x1b[?1003h");
        self.mouse_enabled_1003 = true;
        updateCrashStateFromTerminal(self);
    }

    pub fn disableMouseMotionAny(self: *Terminal) !void {
        if (!self.caps_.ansi or !self.caps_.mouse_sgr) return;
        if (!self.mouse_enabled_1003) return;
        try self.writeAll("\x1b[?1003l");
        self.mouse_enabled_1003 = false;
        updateCrashStateFromTerminal(self);
    }

    pub fn enableMouseMotionWhileButton(self: *Terminal) !void {
        if (!self.caps_.ansi or !self.caps_.mouse_sgr) return;
        if (self.mouse_enabled_1002) return;
        try self.writeAll("\x1b[?1002h");
        self.mouse_enabled_1002 = true;
        updateCrashStateFromTerminal(self);
    }

    pub fn disableMouseMotionWhileButton(self: *Terminal) !void {
        if (!self.caps_.ansi or !self.caps_.mouse_sgr) return;
        if (!self.mouse_enabled_1002) return;
        try self.writeAll("\x1b[?1002l");
        self.mouse_enabled_1002 = false;
        updateCrashStateFromTerminal(self);
    }

    pub fn deinit(self: *Terminal) void {
        if (self.caps_.ansi) {
            if (self.paste_enabled) {
                _ = self.writeAll("\x1b[?2004l") catch {};
                self.paste_enabled = false;
            }
            if (self.mouse_enabled_1003) {
                _ = self.writeAll("\x1b[?1003l") catch {};
                self.mouse_enabled_1003 = false;
            }
            if (self.mouse_enabled_1002) {
                _ = self.writeAll("\x1b[?1002l") catch {};
                self.mouse_enabled_1002 = false;
            }
            if (self.mouse_enabled_1006) {
                _ = self.writeAll("\x1b[?1006l") catch {};
                self.mouse_enabled_1006 = false;
            }
            if (self.mouse_enabled_1000) {
                _ = self.writeAll("\x1b[?1000l") catch {};
                self.mouse_enabled_1000 = false;
            }
            if (self.caps_.cursor_visibility) {
                _ = self.writeAll("\x1b[?25h") catch {};
            }
            if (self.screen_enabled) {
                _ = self.writeAll("\x1b[?1049l") catch {};
                self.screen_enabled = false;
            }
        }
        if (self.raw_enabled) {
            std.posix.tcsetattr(self.stdin_fd, .FLUSH, self.orig_termios) catch {};
            self.raw_enabled = false;
        }
        clearCrashState();
    }

    pub fn getSize(self: *Terminal) !Size {
        var ws: std.posix.winsize = undefined;
        const request: c_int = @intCast(std.posix.T.IOCGWINSZ);
        const rc = std.posix.system.ioctl(self.stdout_fd, request, @intFromPtr(&ws));
        if (rc != 0) return error.IoctlFailed;
        return .{ .rows = ws.row, .cols = ws.col };
    }

    pub fn read(self: *Terminal, buf: []u8) !usize {
        return std.posix.read(self.stdin_fd, buf);
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = try std.posix.write(self.stdout_fd, bytes[off..]);
            off += n;
        }
    }
};
