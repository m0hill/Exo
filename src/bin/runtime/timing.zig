const std = @import("std");

pub const QueueOverflowPolicy = enum {
    drop_newest,
    drop_oldest,
};

pub const RuntimeConfig = struct {
    max_fps: u32 = 30,
    frame_interval_ns: u64 = 33 * std.time.ns_per_ms,
    max_pending_targets: usize = 256,
    max_backend_lines_per_iter: usize = 128,
    queue_overflow: QueueOverflowPolicy = .drop_newest,
    perf_log: bool = false,
    emit_render_events: bool = false,
};

pub fn loadRuntimeConfig(allocator: std.mem.Allocator) !RuntimeConfig {
    var out: RuntimeConfig = .{};

    if (try readEnvUsize(allocator, "TUI_MAX_FPS")) |v| {
        const fps = @as(u32, @intCast(@max(@as(usize, 1), @min(@as(usize, 1000), v))));
        out.max_fps = fps;
        out.frame_interval_ns = std.time.ns_per_s / @as(u64, fps);
    }
    if (try readEnvUsize(allocator, "TUI_MAX_PENDING_TARGETS")) |v| {
        out.max_pending_targets = @max(@as(usize, 1), v);
    }
    if (try readEnvUsize(allocator, "TUI_MAX_BACKEND_LINES_PER_ITER")) |v| {
        out.max_backend_lines_per_iter = @max(@as(usize, 1), v);
    }
    if (try readEnvStringOwned(allocator, "TUI_QUEUE_OVERFLOW")) |s| {
        defer allocator.free(s);
        if (std.ascii.eqlIgnoreCase(s, "drop_oldest")) {
            out.queue_overflow = .drop_oldest;
        } else if (std.ascii.eqlIgnoreCase(s, "drop_newest")) {
            out.queue_overflow = .drop_newest;
        }
    }
    if (try readEnvBool(allocator, "TUI_PERF")) |v| out.perf_log = v;
    if (try readEnvBool(allocator, "TUI_EMIT_RENDER_EVENTS")) |v| out.emit_render_events = v;

    return out;
}

pub fn monotonicNowNs() u64 {
    const t = std.time.nanoTimestamp();
    if (t <= 0) return 0;
    return @as(u64, @intCast(t));
}

pub const resize_debounce_ns: u64 = 100 * std.time.ns_per_ms;

pub fn minTimeoutMs(a: i32, b: i32) i32 {
    if (a < 0) return b;
    if (b < 0) return a;
    return if (a < b) a else b;
}

pub fn pollTimeoutMsForPendingFrame(
    now_ns: u64,
    last_render_ns: u64,
    has_pending: bool,
    frame_interval_ns: u64,
) i32 {
    if (!has_pending) return -1;
    if (last_render_ns == 0) return 0;
    const deadline = last_render_ns + frame_interval_ns;
    if (now_ns >= deadline) return 0;
    const remaining_ns: u64 = deadline - now_ns;
    const ms: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
    return @as(i32, @intCast(if (ms > max_i32) max_i32 else ms));
}

fn readEnvStringOwned(allocator: std.mem.Allocator, name: []const u8) !?[]u8 {
    return std.process.getEnvVarOwned(allocator, name) catch |e| switch (e) {
        error.EnvironmentVariableNotFound => null,
        else => e,
    };
}

fn readEnvBool(allocator: std.mem.Allocator, name: []const u8) !?bool {
    const s = try readEnvStringOwned(allocator, name) orelse return null;
    defer allocator.free(s);
    if (std.ascii.eqlIgnoreCase(s, "1") or std.ascii.eqlIgnoreCase(s, "true") or std.ascii.eqlIgnoreCase(s, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(s, "0") or std.ascii.eqlIgnoreCase(s, "false") or std.ascii.eqlIgnoreCase(s, "no")) return false;
    return null;
}

fn readEnvUsize(allocator: std.mem.Allocator, name: []const u8) !?usize {
    const s = try readEnvStringOwned(allocator, name) orelse return null;
    defer allocator.free(s);
    return std.fmt.parseUnsigned(usize, s, 10) catch null;
}

pub fn pollTimeoutMsForPendingResize(pending_resize: anytype, last_resize_tx_ns: u64) i32 {
    if (pending_resize == null) return -1;
    const now_ns = monotonicNowNs();
    if (last_resize_tx_ns == 0) return 0;
    const deadline = last_resize_tx_ns + resize_debounce_ns;
    if (now_ns >= deadline) return 0;
    const remaining_ns: u64 = deadline - now_ns;
    const ms: u64 = (remaining_ns + (std.time.ns_per_ms - 1)) / std.time.ns_per_ms;
    const max_i32: u64 = @as(u64, @intCast(std.math.maxInt(i32)));
    return @as(i32, @intCast(if (ms > max_i32) max_i32 else ms));
}
