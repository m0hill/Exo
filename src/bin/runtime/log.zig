const std = @import("std");

pub const LogSink = struct {
    file: ?std.fs.File = null,

    pub fn deinit(self: *LogSink) void {
        if (self.file) |f| f.close();
        self.file = null;
    }
};

fn envString(allocator: std.mem.Allocator, name: []const u8) ?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => null,
    };
}

fn envFlag(allocator: std.mem.Allocator, name: []const u8) bool {
    const v = envString(allocator, name) orelse return false;
    defer allocator.free(v);
    return v.len > 0 and (std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true"));
}

pub fn initLogSink(allocator: std.mem.Allocator) !LogSink {
    if (envFlag(allocator, "TUI_LOG_STDERR")) return .{};

    if (!std.posix.isatty(std.posix.STDERR_FILENO)) return .{};

    const path_owned = envString(allocator, "TUI_LOG_PATH");
    defer if (path_owned) |p| allocator.free(p);
    const path = if (path_owned) |p| p else "/tmp/tui_trace.log";
    const f = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    return .{ .file = f };
}

pub fn logPrint(sink: *LogSink, comptime fmt: []const u8, args: anytype) void {
    if (sink.file) |f| {
        var buf: [4096]u8 = undefined;
        var w = f.writerStreaming(&buf);
        w.interface.print(fmt, args) catch {};
        w.interface.flush() catch {};
        return;
    }
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

pub fn logWriteAll(sink: *LogSink, bytes: []const u8) void {
    if (sink.file) |f| {
        var buf: [4096]u8 = undefined;
        var w = f.writerStreaming(&buf);
        w.interface.writeAll(bytes) catch {};
        w.interface.flush() catch {};
        return;
    }
    var buf: [4096]u8 = undefined;
    var w = std.fs.File.stderr().writerStreaming(&buf);
    w.interface.writeAll(bytes) catch {};
    w.interface.flush() catch {};
}

pub fn logRender(sink: *LogSink, m: anytype) void {
    logPrint(
        sink,
        "RENDER full={s} reason=unknown bytes={d} changed_cells={d} cursor_moves={d}\n",
        .{ if (m.full) "true" else "false", m.bytes, m.changed_cells, m.cursor_moves },
    );
}

pub fn logRenderReason(sink: *LogSink, reason: []const u8, m: anytype) void {
    logPrint(
        sink,
        "RENDER full={s} reason={s} bytes={d} changed_cells={d} cursor_moves={d}\n",
        .{ if (m.full) "true" else "false", reason, m.bytes, m.changed_cells, m.cursor_moves },
    );
}
