const std = @import("std");
const builtin = @import("builtin");

const termcaps = @import("termcaps.zig");

const winclip = if (builtin.os.tag == .windows) struct {
    const windows = std.os.windows;
    const cc = std.builtin.CallingConvention.winapi;

    pub const GMEM_MOVEABLE: u32 = 0x0002;
    pub const CF_UNICODETEXT: u32 = 13;

    pub extern fn GlobalAlloc(uFlags: u32, dwBytes: usize) callconv(cc) ?windows.HANDLE;
    pub extern fn GlobalFree(hMem: windows.HANDLE) callconv(cc) ?windows.HANDLE;
    pub extern fn GlobalLock(hMem: windows.HANDLE) callconv(cc) ?*anyopaque;
    pub extern fn GlobalUnlock(hMem: windows.HANDLE) callconv(cc) windows.BOOL;

    pub extern fn OpenClipboard(hWndNewOwner: ?windows.HWND) callconv(cc) windows.BOOL;
    pub extern fn CloseClipboard() callconv(cc) windows.BOOL;
    pub extern fn EmptyClipboard() callconv(cc) windows.BOOL;
    pub extern fn SetClipboardData(uFormat: u32, hMem: windows.HANDLE) callconv(cc) ?windows.HANDLE;
    pub extern fn GetClipboardData(uFormat: u32) callconv(cc) ?windows.HANDLE;
} else struct {};

pub const Target = enum {
    clipboard,
};

pub const Error = error{
    Unsupported,
    TooLarge,
    SystemFailure,
    InvalidData,
};

pub const Options = struct {
    /// Maximum UTF-8 payload bytes sent via OSC 52.
    max_osc52_bytes: usize = 100 * 1024,
};

pub fn writeText(term: anytype, allocator: std.mem.Allocator, caps: termcaps.Caps, opts: Options, data: []const u8) Error!void {
    if (tryWriteHostClipboard(allocator, data)) return;
    if (caps.ansi and caps.osc52) {
        try writeOsc52(term, allocator, caps, opts, data);
        return;
    }
    return error.Unsupported;
}

pub fn readText(allocator: std.mem.Allocator) Error![]u8 {
    return tryReadHostClipboard(allocator);
}

fn tryWriteHostClipboard(allocator: std.mem.Allocator, data: []const u8) bool {
    _ = allocator;
    return switch (builtin.os.tag) {
        .windows => blk: {
            writeWindowsClipboard(data) catch break :blk false;
            break :blk true;
        },
        .macos => blk: {
            writeViaCommand(data, &.{"pbcopy"}) catch break :blk false;
            break :blk true;
        },
        else => blk: {
            writeLinuxWaylandX11(data) catch break :blk false;
            break :blk true;
        },
    };
}

fn tryReadHostClipboard(allocator: std.mem.Allocator) Error![]u8 {
    return switch (builtin.os.tag) {
        .windows => readWindowsClipboard(allocator),
        .macos => readViaCommand(allocator, &.{"pbpaste"}),
        else => readLinuxWaylandX11(allocator),
    };
}

fn commandTermOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

fn writeViaCommand(data: []const u8, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Pipe;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const in = child.stdin orelse {
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.SystemFailure;
    };
    in.writeAll(data) catch {
        in.close();
        _ = child.kill() catch {};
        _ = child.wait() catch {};
        return error.SystemFailure;
    };
    in.close();
    const term = child.wait() catch return error.SystemFailure;
    if (!commandTermOk(term)) return error.SystemFailure;
}

fn readViaCommand(allocator: std.mem.Allocator, argv: []const []const u8) Error![]u8 {
    var child = std.process.Child.init(argv, std.heap.page_allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    child.spawn() catch return error.Unsupported;
    errdefer _ = child.kill() catch {};

    const out = child.stdout orelse return error.SystemFailure;
    defer out.close();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);

    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = out.read(&tmp) catch return error.SystemFailure;
        if (n == 0) break;
        if (buf.items.len + n > 1024 * 1024) return error.TooLarge;
        buf.appendSlice(allocator, tmp[0..n]) catch return error.SystemFailure;
    }
    const term = child.wait() catch return error.SystemFailure;
    if (!commandTermOk(term)) return error.SystemFailure;
    return buf.toOwnedSlice(allocator) catch return error.SystemFailure;
}

fn writeLinuxWaylandX11(data: []const u8) !void {
    // Prefer Wayland.
    if (writeViaCommand(data, &.{"wl-copy"})) |_| return else |_| {}
    // X11 fallbacks.
    if (writeViaCommand(data, &.{ "xclip", "-selection", "clipboard" })) |_| return else |_| {}
    if (writeViaCommand(data, &.{ "xsel", "--clipboard", "--input" })) |_| return else |_| {}
    return error.Unsupported;
}

fn readLinuxWaylandX11(allocator: std.mem.Allocator) Error![]u8 {
    if (readViaCommand(allocator, &.{ "wl-paste", "-n" })) |v| return v else |_| {}
    if (readViaCommand(allocator, &.{ "xclip", "-selection", "clipboard", "-o" })) |v| return v else |_| {}
    if (readViaCommand(allocator, &.{ "xsel", "--clipboard", "--output" })) |v| return v else |_| {}
    return error.Unsupported;
}

pub fn writeOsc52(term: anytype, allocator: std.mem.Allocator, caps: termcaps.Caps, opts: Options, data: []const u8) Error!void {
    if (data.len > opts.max_osc52_bytes) return error.TooLarge;

    const enc_len = std.base64.standard.Encoder.calcSize(data.len);
    const b64: []u8 = allocator.alloc(u8, enc_len) catch return error.SystemFailure;
    defer allocator.free(b64);
    _ = std.base64.standard.Encoder.encode(b64, data);

    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(allocator);

    seq.appendSlice(allocator, "\x1b]52;c;") catch return error.SystemFailure;
    seq.appendSlice(allocator, b64) catch return error.SystemFailure;
    seq.append(allocator, 0x07) catch return error.SystemFailure; // BEL

    const payload = seq.items;
    if (caps.tmux) {
        // ESC P tmux; ESC <payload> ESC \
        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);
        wrapped.appendSlice(allocator, "\x1bPtmux;\x1b") catch return error.SystemFailure;
        wrapped.appendSlice(allocator, payload) catch return error.SystemFailure;
        wrapped.appendSlice(allocator, "\x1b\\") catch return error.SystemFailure;
        term.writeAll(wrapped.items) catch return error.SystemFailure;
        return;
    }
    if (caps.screen) {
        // ESC P ESC <payload> ESC \
        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);
        wrapped.appendSlice(allocator, "\x1bP\x1b") catch return error.SystemFailure;
        wrapped.appendSlice(allocator, payload) catch return error.SystemFailure;
        wrapped.appendSlice(allocator, "\x1b\\") catch return error.SystemFailure;
        term.writeAll(wrapped.items) catch return error.SystemFailure;
        return;
    }

    term.writeAll(payload) catch return error.SystemFailure;
}

fn writeWindowsClipboard(data: []const u8) !void {
    if (winclip.OpenClipboard(null) == 0) return error.SystemFailure;
    defer _ = winclip.CloseClipboard();

    if (winclip.EmptyClipboard() == 0) return error.SystemFailure;

    const wlen = std.unicode.calcUtf16LeLen(data) catch return error.InvalidData;
    const bytes_needed: usize = (wlen + 1) * 2;

    var hmem_opt = winclip.GlobalAlloc(winclip.GMEM_MOVEABLE, bytes_needed);
    if (hmem_opt == null) return error.SystemFailure;
    errdefer if (hmem_opt) |hm| {
        _ = winclip.GlobalFree(hm);
    };

    const hm = hmem_opt.?;
    const lock_ptr = winclip.GlobalLock(hm) orelse return error.SystemFailure;
    defer _ = winclip.GlobalUnlock(hm);

    const out_u16: [*]u16 = @ptrCast(@alignCast(lock_ptr));
    _ = std.unicode.utf8ToUtf16Le(out_u16[0..wlen], data) catch return error.InvalidData;
    out_u16[wlen] = 0;

    if (winclip.SetClipboardData(winclip.CF_UNICODETEXT, hm) == null) return error.SystemFailure;
    // Ownership transferred to the system.
    hmem_opt = null;
}

fn readWindowsClipboard(allocator: std.mem.Allocator) Error![]u8 {
    if (winclip.OpenClipboard(null) == 0) return error.SystemFailure;
    defer _ = winclip.CloseClipboard();

    const h = winclip.GetClipboardData(winclip.CF_UNICODETEXT) orelse return error.Unsupported;
    const lock_ptr = winclip.GlobalLock(h) orelse return error.SystemFailure;
    defer _ = winclip.GlobalUnlock(h);

    const p: [*]const u16 = @ptrCast(@alignCast(lock_ptr));
    var n: usize = 0;
    while (true) : (n += 1) {
        if (p[n] == 0) break;
        if (n > 1024 * 1024) return error.TooLarge;
    }

    const out = std.unicode.utf16LeToUtf8Alloc(allocator, p[0..n]) catch |e| switch (e) {
        error.OutOfMemory => return error.SystemFailure,
        else => return error.InvalidData,
    };
    if (out.len > 1024 * 1024) {
        allocator.free(out);
        return error.TooLarge;
    }
    return out;
}
