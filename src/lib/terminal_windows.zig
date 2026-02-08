const std = @import("std");

const termcaps = @import("termcaps.zig");

pub const Size = @import("term_size.zig").Size;

const windows = std.os.windows;
const kernel32 = windows.kernel32;

// Zig's stdlib doesn't currently expose this console mode flag, but the Win32 API
// constant is stable.
const ENABLE_VIRTUAL_TERMINAL_INPUT: u32 = 0x0200;
const ENABLE_PROCESSED_INPUT: u32 = 0x0001;
const ENABLE_LINE_INPUT: u32 = 0x0002;
const ENABLE_ECHO_INPUT: u32 = 0x0004;

pub const Options = struct {};

pub const Terminal = struct {
    stdin_handle: windows.HANDLE,
    stdout_handle: windows.HANDLE,
    orig_in_mode: u32,
    orig_out_mode: u32,
    raw_enabled: bool = false,
    screen_enabled: bool = false,
    paste_enabled: bool = false,
    mouse_enabled_1000: bool = false,
    mouse_enabled_1006: bool = false,
    mouse_enabled_1002: bool = false,
    mouse_enabled_1003: bool = false,
    vt_out_enabled: bool = false,
    vt_in_enabled: bool = false,
    caps_: termcaps.Caps,

    pub fn init(allocator: std.mem.Allocator, _: Options) !Terminal {
        const stdin_handle = kernel32.GetStdHandle(windows.STD_INPUT_HANDLE) orelse return error.NotATty;
        const stdout_handle = kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return error.NotATty;

        var in_mode: u32 = 0;
        var out_mode: u32 = 0;
        if (kernel32.GetConsoleMode(stdin_handle, &in_mode) == 0) return error.NotATty;
        if (kernel32.GetConsoleMode(stdout_handle, &out_mode) == 0) return error.NotATty;

        var t: Terminal = .{
            .stdin_handle = stdin_handle,
            .stdout_handle = stdout_handle,
            .orig_in_mode = in_mode,
            .orig_out_mode = out_mode,
            .caps_ = termcaps.detectCaps(allocator, true),
        };
        errdefer t.deinit();
        updateCrashStateFromTerminal(&t);

        const enable_out = out_mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
        if (kernel32.SetConsoleMode(stdout_handle, enable_out) == 0) return error.VtUnsupported;
        t.vt_out_enabled = true;

        var new_in = in_mode;
        new_in |= ENABLE_VIRTUAL_TERMINAL_INPUT;
        new_in &= ~ENABLE_ECHO_INPUT;
        new_in &= ~ENABLE_LINE_INPUT;
        new_in &= ~ENABLE_PROCESSED_INPUT;
        if (kernel32.SetConsoleMode(stdin_handle, new_in) == 0) {
            // Restore output mode if input VT can't be enabled.
            _ = kernel32.SetConsoleMode(stdout_handle, out_mode);
            return error.VtUnsupported;
        }
        t.vt_in_enabled = true;
        t.raw_enabled = true;
        updateCrashStateFromTerminal(&t);

        // Best-effort terminal capability probing (Device Attributes).
        // Responses are ignored by the input decoder.
        _ = t.writeAll("\x1b[c\x1b[>c") catch {};

        // VT required: if we couldn't enable it, we exit. Past this point, caps.ansi is true.
        if (!t.vt_out_enabled) {
            t.caps_.ansi = false;
            t.caps_.cursor_address = false;
            t.caps_.clear_screen = false;
            t.caps_.erase_eol = false;
            t.caps_.alt_screen = false;
            t.caps_.cursor_visibility = false;
            t.caps_.bracketed_paste = false;
            t.caps_.mouse_sgr = false;
            t.caps_.osc52 = false;
            t.caps_.color = .mono;
        }

        if (t.caps_.ansi and t.caps_.alt_screen) {
            try t.writeAll("\x1b[?1049h");
            t.screen_enabled = true;
            updateCrashStateFromTerminal(&t);
        }

        if (t.caps_.ansi and t.caps_.cursor_visibility) {
            try t.writeAll("\x1b[?25l");
            updateCrashStateFromTerminal(&t);
        }

        if (t.caps_.ansi and t.caps_.bracketed_paste) {
            try t.writeAll("\x1b[?2004h");
            t.paste_enabled = true;
            updateCrashStateFromTerminal(&t);
        }

        return t;
    }

    pub fn caps(self: *const Terminal) termcaps.Caps {
        return self.caps_;
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

        if (self.vt_in_enabled or self.vt_out_enabled or self.raw_enabled) {
            _ = kernel32.SetConsoleMode(self.stdin_handle, self.orig_in_mode);
            _ = kernel32.SetConsoleMode(self.stdout_handle, self.orig_out_mode);
            self.vt_in_enabled = false;
            self.vt_out_enabled = false;
            self.raw_enabled = false;
        }
        clearCrashState();
    }

    pub fn getSize(self: *Terminal) !Size {
        var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (kernel32.GetConsoleScreenBufferInfo(self.stdout_handle, &info) == 0) {
            return error.GetConsoleScreenBufferInfoFailed;
        }
        const cols: i16 = info.srWindow.Right - info.srWindow.Left + 1;
        const rows: i16 = info.srWindow.Bottom - info.srWindow.Top + 1;
        if (cols <= 0 or rows <= 0) return error.InvalidSize;
        return .{ .rows = @as(u16, @intCast(rows)), .cols = @as(u16, @intCast(cols)) };
    }

    pub fn read(self: *Terminal, buf: []u8) !usize {
        var got: u32 = 0;
        if (kernel32.ReadFile(self.stdin_handle, buf.ptr, @as(u32, @intCast(buf.len)), &got, null) == 0) {
            return error.ReadFailed;
        }
        if (got == 0) return error.EndOfStream;
        return @as(usize, @intCast(got));
    }

    pub fn writeAll(self: *Terminal, bytes: []const u8) !void {
        var off: usize = 0;
        while (off < bytes.len) {
            var wrote: u32 = 0;
            const chunk_len: usize = @min(bytes.len - off, @as(usize, std.math.maxInt(u32)));
            if (kernel32.WriteFile(
                self.stdout_handle,
                bytes[off .. off + chunk_len].ptr,
                @as(u32, @intCast(chunk_len)),
                &wrote,
                null,
            ) == 0) return error.WriteFailed;
            if (wrote == 0) return error.WriteFailed;
            off += @as(usize, @intCast(wrote));
        }
    }

    pub fn enableMouseBase(self: *Terminal) !void {
        if (!self.caps_.ansi or !self.caps_.mouse_sgr) return;
        if (!self.mouse_enabled_1000) {
            try self.writeAll("\x1b[?1000h");
            self.mouse_enabled_1000 = true;
        }
        if (!self.mouse_enabled_1006) {
            try self.writeAll("\x1b[?1006h");
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
};

pub const CrashRestoreState = struct {
    stdin_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    stdout_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    orig_in_mode: u32 = 0,
    orig_out_mode: u32 = 0,
    have_modes: bool = false,
    screen_enabled: bool = false,
    paste_enabled: bool = false,
    mouse_enabled_1000: bool = false,
    mouse_enabled_1006: bool = false,
    mouse_enabled_1002: bool = false,
    mouse_enabled_1003: bool = false,
};

var crash_state: CrashRestoreState = .{};
var crash_state_active: bool = false;
var crash_restore_in_progress: bool = false;

fn updateCrashStateFromTerminal(term: *const Terminal) void {
    crash_state = .{
        .stdin_handle = term.stdin_handle,
        .stdout_handle = term.stdout_handle,
        .orig_in_mode = term.orig_in_mode,
        .orig_out_mode = term.orig_out_mode,
        .have_modes = true,
        .screen_enabled = term.screen_enabled,
        .paste_enabled = term.paste_enabled,
        .mouse_enabled_1000 = term.mouse_enabled_1000,
        .mouse_enabled_1006 = term.mouse_enabled_1006,
        .mouse_enabled_1002 = term.mouse_enabled_1002,
        .mouse_enabled_1003 = term.mouse_enabled_1003,
    };
    crash_state_active = true;
}

fn clearCrashState() void {
    crash_state_active = false;
}

fn writeAllBestEffort(handle: windows.HANDLE, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        var wrote: u32 = 0;
        const chunk_len: usize = @min(bytes.len - off, @as(usize, std.math.maxInt(u32)));
        if (kernel32.WriteFile(
            handle,
            bytes[off .. off + chunk_len].ptr,
            @as(u32, @intCast(chunk_len)),
            &wrote,
            null,
        ) == 0) break;
        if (wrote == 0) break;
        off += @as(usize, @intCast(wrote));
    }
}

pub fn restoreBestEffort() void {
    if (crash_restore_in_progress) return;
    crash_restore_in_progress = true;
    defer crash_restore_in_progress = false;

    const st: CrashRestoreState = if (crash_state_active) crash_state else .{};
    if (st.stdout_handle != windows.INVALID_HANDLE_VALUE) {
        writeAllBestEffort(st.stdout_handle, "\x1b[?2004l");
        writeAllBestEffort(st.stdout_handle, "\x1b[?1003l");
        writeAllBestEffort(st.stdout_handle, "\x1b[?1002l");
        writeAllBestEffort(st.stdout_handle, "\x1b[?1006l");
        writeAllBestEffort(st.stdout_handle, "\x1b[?1000l");
        writeAllBestEffort(st.stdout_handle, "\x1b[?25h");
        writeAllBestEffort(st.stdout_handle, "\x1b[?1049l");
    }

    if (st.have_modes and st.stdin_handle != windows.INVALID_HANDLE_VALUE and st.stdout_handle != windows.INVALID_HANDLE_VALUE) {
        _ = kernel32.SetConsoleMode(st.stdin_handle, st.orig_in_mode);
        _ = kernel32.SetConsoleMode(st.stdout_handle, st.orig_out_mode);
    }
}

pub fn emergencyExit(code: u8) noreturn {
    restoreBestEffort();
    std.process.exit(code);
}
